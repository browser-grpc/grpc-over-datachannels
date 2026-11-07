# Tracing: nested callee call joins the trace via the bound channel.

require "grpcdc"
require "echo_grpc_dc"
require "echo_pb"
require "echo_service"
require_relative "test_util"

module TestTracing
  Start = Struct.new(:kind, :method, :trace_id, :span_id, :parent_span_id)

  class Recorder
    attr_reader :starts, :end_durations

    def initialize
      @starts = []
      @end_durations = []
    end

    def on_start(kind, method, trace_id, span_id, parent_span_id)
      @starts << Start.new(kind, method, trace_id, span_id, parent_span_id)
    end

    def on_end(kind, method, trace_id, span_id, status, duration_ms)
      @end_durations << duration_ms
    end
  end

  class Front < EchoService
    attr_reader :seen_span

    def initialize(downstream_channel)
      super()
      @downstream_channel = downstream_channel
    end

    def Unary(ctx, req)
      @seen_span = ctx.trace_context && ctx.trace_context["span_id"]
      bound = EchoGrpcDc::EchoClient.new(
        @downstream_channel.with_trace_context(ctx.trace_context))
      bound.Unary(TestTracing.req("nested"))
    end
  end

  def self.req(message, count = 0)
    EchoPb::EchoRequest.new(message: message, count: count)
  end

  def self.run
    rec = Recorder.new
    Grpcdc.set_tracer(rec)
    begin
      a2, b2 = Grpcdc.memory_transport_pair
      back = Grpcdc::Server.new
      EchoGrpcDc.register_echo_server(back, EchoService.new)
      back.serve_transport(b2)
      downstream_channel = Grpcdc::Channel.new(a2)

      front = Front.new(downstream_channel)
      a, b = Grpcdc.memory_transport_pair
      front_server = Grpcdc::Server.new
      EchoGrpcDc.register_echo_server(front_server, front)
      front_server.serve_transport(b)
      client = EchoGrpcDc::EchoClient.new(Grpcdc::Channel.new(a))

      resp = client.Unary(req("hello"))
      TestUtil.assert_eq(resp.message, "echo: nested", "resp")

      starts = rec.starts
      TestUtil.assert_eq(starts.length, 4, "starts")
      TestUtil.assert_eq(starts.map(&:kind), %w[client server client server], "kinds")
      TestUtil.assert_eq(starts.map(&:trace_id).uniq.length, 1, "trace ids")
      TestUtil.assert_eq(starts[1].parent_span_id, starts[0].span_id, "server parent")
      TestUtil.assert_eq(starts[2].parent_span_id, starts[1].span_id, "inner client parent")
      TestUtil.assert_eq(starts[3].parent_span_id, starts[2].span_id, "inner server parent")
      TestUtil.assert_eq(front.seen_span, starts[1].span_id, "ctx span")
      TestUtil.assert_eq(rec.end_durations.length, 4, "ends")
      TestUtil.assert_eq(rec.end_durations.all? { |d| d >= 0 }, true, "durations")
      puts "TestTracing OK"
    ensure
      Grpcdc.set_tracer(nil)
    end
  end
end
