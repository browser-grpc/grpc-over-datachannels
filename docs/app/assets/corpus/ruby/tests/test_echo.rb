# Loopback end-to-end: all four shapes, error status, metadata.

require "grpcdc"
require_relative "test_util"

module TestEcho
  def self.req(message, count = 0)
    EchoPb::EchoRequest.new(message: message, count: count)
  end

  def self.run
    require "echo_grpc_dc"
    require "echo_pb"
    require "echo_service"

    a, b = Grpcdc.memory_transport_pair
    server = Grpcdc::Server.new
    EchoGrpcDc.register_echo_server(server, EchoService.new)
    server.serve_transport(b)
    client = EchoGrpcDc::EchoClient.new(Grpcdc::Channel.new(a))

    resp = client.Unary(req("hello"))
    TestUtil.assert_eq(resp.message, "echo: hello", "unary message")
    TestUtil.assert_eq(resp.index, 0, "unary index")

    responses = client.ServerStream(req("tick", 3)).to_a
    TestUtil.assert_eq(responses.map(&:index), [0, 1, 2], "server-stream index")
    TestUtil.check(responses.all? { |r| r.message == "tick" }, "server-stream message")

    resp = client.ClientStream([req("a"), req("b"), req("c")])
    TestUtil.assert_eq(resp.message, "a+b+c", "client-stream message")
    TestUtil.assert_eq(resp.index, 3, "client-stream index")

    responses = client.Bidi([req("x"), req("y")]).to_a
    TestUtil.assert_eq(responses.map(&:message), %w[x y], "bidi message")
    TestUtil.assert_eq(responses.map(&:index), [0, 1], "bidi index")

    begin
      client.Unary(req("fail"))
      raise "expected StatusError"
    rescue Grpcdc::StatusError => e
      TestUtil.assert_eq(e.code, 3, "error status") # INVALID-ARGUMENT
    end

    resp = client.Unary(req("hello"), { "x-echo" => "meta" })
    TestUtil.assert_eq(resp.message, "echo: hello [meta]", "metadata")

    # Breaking a server stream cancels it server-side: breaking
    # out of `each` RSTs the call (RecvStream ensure/close), and
    # the handler's next send fails CANCELLED instead of
    # streaming into the void. Mirrors js/test/echo.test.js
    # "breaking a server stream cancels it server-side".
    produced = [0]
    counting = Class.new(EchoService) do
      define_method(:ServerStream) do |request, stream|
        request.count.times do |i|
          produced[0] += 1
          stream.send(EchoPb::EchoResponse.new(message: request.message, index: i))
          sleep(0.01)
        end
      end
    end
    a2, b2 = Grpcdc.memory_transport_pair
    server2 = Grpcdc::Server.new
    EchoGrpcDc.register_echo_server(server2, counting.new)
    server2.serve_transport(b2)
    client2 = EchoGrpcDc::EchoClient.new(Grpcdc::Channel.new(a2))

    seen = 0
    client2.ServerStream(req("tick", 1000)).each do |_resp|
      seen += 1
      break if seen == 2
    end
    TestUtil.assert_eq(seen, 2, "stream break seen")
    sleep(0.15)
    settled = produced[0]
    sleep(0.15)
    TestUtil.assert_eq(produced[0], settled, "stream break settled")
    TestUtil.check(settled < 100, "server kept producing (#{settled})")

    # Abandoning a server stream cancels it server-side: reading
    # one response from the Enumerator and then dropping it (no
    # break, no explicit cancel) RSTs the call via the stream
    # finalizer once the enumerator is collected, and the
    # handler's next send fails CANCELLED instead of streaming
    # into the void. Mirrors the stream-break BDD scenario.
    produced_abandon = [0]
    counting_abandon = Class.new(EchoService) do
      define_method(:ServerStream) do |request, stream|
        request.count.times do |i|
          produced_abandon[0] += 1
          stream.send(EchoPb::EchoResponse.new(message: request.message, index: i))
          sleep(0.01)
        end
      end
    end
    a3, b3 = Grpcdc.memory_transport_pair
    server3 = Grpcdc::Server.new
    EchoGrpcDc.register_echo_server(server3, counting_abandon.new)
    server3.serve_transport(b3)
    client3 = EchoGrpcDc::EchoClient.new(Grpcdc::Channel.new(a3))

    enum = client3.ServerStream(req("tick", 1000)).each
    first = enum.next
    TestUtil.assert_eq(first.index, 0, "stream abandon first index")
    enum = nil
    GC.start
    sleep(0.15)
    settled_abandon = produced_abandon[0]
    sleep(0.15)
    TestUtil.assert_eq(produced_abandon[0], settled_abandon, "stream abandon settled")
    TestUtil.check(settled_abandon < 50, "server kept producing (#{settled_abandon})")
  end
end
