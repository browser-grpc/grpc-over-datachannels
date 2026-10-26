# Hand-written TestService implementation for the interop
# oracle (Direction B: official grpc-java / grpc-go clients
# against this server, through the bridge). Mirrors
# js/test/interop_service.js.

require "base64"
require "grpcdc"
require_relative "interop/messages_pb"
require_relative "interop/empty_pb"
require_relative "interop/orca_load_report_pb"

class InteropServiceImpl
  INITIAL_KEY = "x-grpc-test-echo-initial"
  TRAILING_KEY = "x-grpc-test-echo-trailing-bin"

  @oob_mutex = Mutex.new
  @oob_report = nil

  class << self
    def oob_report
      @oob_mutex.synchronize { @oob_report }
    end

    def oob_report=(report)
      @oob_mutex.synchronize { @oob_report = report }
    end
  end

  def echo_metadata(ctx)
    md = ctx.metadata || {}
    ctx.set_headers({ INITIAL_KEY => md[INITIAL_KEY] }) if md[INITIAL_KEY]
    ctx.set_trailers({ TRAILING_KEY => md[TRAILING_KEY] }) if md[TRAILING_KEY]
  end

  def check_status(status)
    return if status.nil? || status.code.zero?

    raise Grpcdc::StatusError.new(status.code, status.message)
  end

  def send_responses(req, stream)
    (req.response_parameters || []).each do |params|
      sleep(params.interval_us / 1_000_000.0) if params.interval_us.positive?
      stream.send(MessagesPb::StreamingOutputCallResponse.new(
        payload: MessagesPb::Payload.new(
          type: req.response_type, body: "\0".b * params.size)))
    end
  end

  def set_orca_trailer(ctx, report)
    load_report = OrcaLoadReportPb::OrcaLoadReport.new(
      cpu_utilization: report.cpu_utilization,
      mem_utilization: report.memory_utilization,
      request_cost: report.request_cost || {},
      utilization: report.utilization || {})
    ctx.set_trailers({
      "endpoint-load-metrics-bin" => Base64.strict_encode64(load_report.marshal_dc),
    })
  end

  def EmptyCall(_ctx, _req)
    EmptyPb::Empty.new
  end

  def UnaryCall(ctx, req)
    echo_metadata(ctx)
    if req.expect_compressed && req.expect_compressed.value &&
       (ctx.metadata || {})["grpc-encoding"] != "gzip"
      raise Grpcdc::StatusError.new(
        Grpcdc::CODE_INVALID_ARGUMENT,
        "expected compressed request, got uncompressed")
    end
    check_status(req.response_status)
    set_orca_trailer(ctx, req.orca_per_query_report) if req.orca_per_query_report
    MessagesPb::SimpleResponse.new(
      payload: MessagesPb::Payload.new(
        type: req.response_type, body: "\0".b * req.response_size))
  end
  # The official case sends two different payloads and expects
  # two different responses: echo the request payload back.
  def CacheableUnaryCall(ctx, req)
    echo_metadata(ctx)
    MessagesPb::SimpleResponse.new(payload: req.payload)
  end

  def StreamingOutputCall(req, stream)
    echo_metadata(stream.context)
    check_status(req.response_status)
    send_responses(req, stream)
  end

  def StreamingInputCall(stream)
    echo_metadata(stream.context)
    total = 0
    begin
      loop do
        req = stream.recv
        if req.expect_compressed && req.expect_compressed.value &&
           (stream.context.metadata || {})["grpc-encoding"] != "gzip"
          raise Grpcdc::StatusError.new(
            Grpcdc::CODE_INVALID_ARGUMENT,
            "expected compressed request, got uncompressed")
        end
        total += req.payload.body.bytesize if req.payload
      end
    rescue EOFError
      nil
    end
    stream.send_and_close(
      MessagesPb::StreamingInputCallResponse.new(aggregated_payload_size: total))
  end

  def FullDuplexCall(stream)
    echo_metadata(stream.context)
    begin
      loop do
        req = stream.recv
        check_status(req.response_status)
        if req.orca_oob_report
          report = req.orca_oob_report
          self.class.oob_report = OrcaLoadReportPb::OrcaLoadReport.new(
            cpu_utilization: report.cpu_utilization,
            mem_utilization: report.memory_utilization,
            request_cost: report.request_cost || {},
            utilization: report.utilization || {})
        end
        send_responses(req, stream)
      end
    rescue EOFError
      nil
    end
  end

  def HalfDuplexCall(stream)
    echo_metadata(stream.context)
    collected = []
    begin
      loop { collected << stream.recv }
    rescue EOFError
      nil
    end
    collected.each do |req|
      check_status(req.response_status)
      send_responses(req, stream)
    end
  end

  def UnimplementedCall(_ctx, _req)
    raise Grpcdc::StatusError.new(Grpcdc::CODE_UNIMPLEMENTED, "not implemented")
  end

  # OpenRcaService (ORCA out-of-band): stream the current OOB
  # report on an interval until the client goes away.
  def StreamCoreMetrics(_req, stream)
    loop do
      stream.send(self.class.oob_report || OrcaLoadReportPb::OrcaLoadReport.new)
      sleep(0.2)
    end
  rescue Grpcdc::StatusError, EOFError, IOError
    nil
  end
end
