# Fiber surface: FiberChannel + generated EchoClientFiber over loopback.
#
# Covers all four shapes, fiber-producer streams pulled one message
# at a time (next_msg), error status, and cancellation not poisoning
# the channel.

require "grpcdc"
require_relative "test_util"

module TestFiber
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
    client = EchoGrpcDc::EchoClientFiber.new(Grpcdc::FiberChannel.new(a))

    resp = client.Unary(req("hello"))
    TestUtil.assert_eq(resp.message, "echo: hello", "fiber unary message")
    TestUtil.assert_eq(resp.index, 0, "fiber unary index")

    stream = client.ServerStream(req("tick", 3))
    TestUtil.assert_eq(stream.next_msg.index, 0, "fiber next 0")
    TestUtil.assert_eq(stream.next_msg.index, 1, "fiber next 1")
    TestUtil.assert_eq(stream.next_msg.index, 2, "fiber next 2")
    begin
      stream.next_msg
      raise "expected StopIteration"
    rescue StopIteration
      nil # expected
    end

    responses = client.ServerStream(req("tick", 2)).to_a
    TestUtil.assert_eq(responses.map(&:index), [0, 1], "fiber each index")

    resp = client.ClientStream([req("a"), req("b"), req("c")])
    TestUtil.assert_eq(resp.message, "a+b+c", "fiber client-stream")

    responses = client.Bidi([req("x"), req("y")]).to_a
    TestUtil.assert_eq(responses.map(&:message), %w[x y], "fiber bidi")

    begin
      client.Unary(req("fail"))
      raise "expected StatusError"
    rescue Grpcdc::StatusError => e
      TestUtil.assert_eq(e.code, 3, "fiber error status")
    end

    # Wrap a plain sync Channel instead of a FiberChannel.
    a2, b2 = Grpcdc.memory_transport_pair
    server2 = Grpcdc::Server.new
    EchoGrpcDc.register_echo_server(server2, EchoService.new)
    server2.serve_transport(b2)
    wrapped = EchoGrpcDc::EchoClientFiber.new(Grpcdc::Channel.new(a2))
    TestUtil.assert_eq(wrapped.Unary(req("wrapped")).message, "echo: wrapped",
                       "fiber wrapped channel")

    # Cancellation: a long stream is aborted; the fiber sees the
    # cancellation status and the channel stays usable.
    stream = client.ServerStream(req("tick", 100_000))
    TestUtil.assert_eq(stream.next_msg.index, 0, "cancel first")
    stream.cancel
    begin
      loop { stream.next_msg }
      raise "expected cancellation"
    rescue Grpcdc::StatusError => e
      TestUtil.assert_eq(e.code, 1, "cancel status") # CANCELLED
    end
    resp = client.Unary(req("after"))
    TestUtil.assert_eq(resp.message, "echo: after", "fiber after cancel")
  end
end
