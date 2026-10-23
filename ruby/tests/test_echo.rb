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
  end
end
