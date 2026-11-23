# Struct-codec negotiation: struct<->struct roundtrip all four
# shapes, struct client to protobuf server fails UNIMPLEMENTED,
# plain client to struct server succeeds.

require "grpcdc"
require_relative "test_util"

module TestStructCodec
  def self.req(message, count = 0)
    EchoPb::EchoRequest.new(message: message, count: count)
  end

  def self.setup(client_struct, server_struct)
    a, b = Grpcdc.memory_transport_pair
    server = Grpcdc::Server.new
    server.set_struct_codec(server_struct)
    EchoGrpcDc.register_echo_server(server, EchoService.new)
    server.serve_transport(b)
    channel = Grpcdc::Channel.new(a)
    channel.set_struct_codec(client_struct)
    EchoGrpcDc::EchoClient.new(channel)
  end

  def self.run
    require "echo_grpc_dc"
    require "echo_pb"
    require "echo_service"

    client = setup(true, true)

    resp = client.Unary(req("hello"))
    TestUtil.assert_eq(resp.message, "echo: hello", "struct unary")

    responses = client.ServerStream(req("tick", 3)).to_a
    TestUtil.assert_eq(responses.map(&:index), [0, 1, 2], "struct server-stream")

    resp = client.ClientStream([req("a"), req("b")])
    TestUtil.assert_eq(resp.message, "a+b", "struct client-stream")

    responses = client.Bidi([req("x"), req("y")]).to_a
    TestUtil.assert_eq(responses.map(&:message), %w[x y], "struct bidi")

    bytes = req("hello").marshal_struct
    TestUtil.check(bytes.start_with?("DCS1"), "struct magic")
    back = EchoPb::EchoRequest.new.unmarshal_struct(bytes)
    TestUtil.assert_eq(back.message, "hello", "struct roundtrip")

    mismatch = setup(true, false)
    begin
      mismatch.Unary(req("hello"))
      raise "expected StatusError"
    rescue Grpcdc::StatusError => e
      TestUtil.assert_eq(e.code, Grpcdc::CODE_UNIMPLEMENTED, "mismatch status")
    end

    plain = setup(false, true)
    resp = plain.Unary(req("hello"))
    TestUtil.assert_eq(resp.message, "echo: hello", "plain vs struct server")

    puts "TestStructCodec OK"
  end
end
