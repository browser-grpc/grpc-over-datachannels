# Deadlines: grpc-timeout propagation + DEADLINE_EXCEEDED enforcement.

require "grpcdc"
require "echo_grpc_dc"
require "echo_pb"
require "echo_service"
require_relative "test_util"

module TestDeadline
  class SlowEcho < EchoService
    attr_reader :seen_ctx

    def Unary(ctx, req)
      @seen_ctx = ctx
      sleep(0.4)
      super
    end

    def ServerStream(req, stream)
      req.count.times do |i|
        sleep(0.3) if i.positive?
        stream.send(EchoPb::EchoResponse.new(message: req.message, index: i))
      end
    end
  end

  def self.req(message, count = 0)
    EchoPb::EchoRequest.new(message: message, count: count)
  end

  def self.run

    TestUtil.assert_eq(Grpcdc::Codec.parse_timeout(Grpcdc::Codec.encode_timeout(0.25)), 0.25,
                       "timeout round trip")
    TestUtil.assert_eq(Grpcdc::Codec.parse_timeout("10x"), nil, "junk timeout")

    a, b = Grpcdc.memory_transport_pair
    server = Grpcdc::Server.new
    slow = SlowEcho.new
    EchoGrpcDc.register_echo_server(server, slow)
    server.serve_transport(b)
    client = EchoGrpcDc::EchoClient.new(Grpcdc::Channel.new(a))

    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    begin
      client.Unary(req("hello"), nil, timeout: 0.05)
      raise "expected deadline"
    rescue Grpcdc::StatusError => e
      TestUtil.assert_eq(e.code, 4, "deadline code")
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    TestUtil.check(elapsed < 0.35, "deadline fast (#{elapsed})")

    wait_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2.0
    sleep(0.01) while slow.seen_ctx.nil? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < wait_deadline
    TestUtil.check(!slow.seen_ctx.nil?, "handler ran")
    TestUtil.check(slow.seen_ctx.metadata.key?("grpc-timeout"), "grpc-timeout metadata")
    TestUtil.check(!slow.seen_ctx.deadline.nil?, "ctx deadline")
    TestUtil.check(!slow.seen_ctx.time_remaining.nil?, "ctx remaining")

    sleep(0.45) # let the unary slow handler finish before streaming
    stream = client.ServerStream(req("tick", 5), nil, timeout: 0.25)
    TestUtil.assert_eq(stream.recv.index, 0, "stream first")
    begin
      stream.recv
      raise "expected stream deadline"
    rescue Grpcdc::StatusError => e
      TestUtil.assert_eq(e.code, 4, "stream code")
    end

    resp = client.ClientStream([req("a"), req("b")], nil, timeout: 5.0)
    TestUtil.assert_eq(resp.message, "a+b", "generous timeout")

    # Fiber client carries the same deadline behavior.
    fiber_client = EchoGrpcDc::EchoClientFiber.new(Grpcdc::FiberChannel.new(a))
    begin
      fiber_client.Unary(req("hello"), nil, timeout: 0.05)
      raise "expected fiber deadline"
    rescue Grpcdc::StatusError => e
      TestUtil.assert_eq(e.code, 4, "fiber code")
    end
  end
end
