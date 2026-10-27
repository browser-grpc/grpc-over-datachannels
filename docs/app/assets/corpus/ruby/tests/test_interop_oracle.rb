# Interop client grading: the generated Ruby TestService client
# runs the canonical grpc interop cases (generated table:
# interop_cases_generated.rb) against the official grpc-go
# TestServiceServer, through the bridge (dc-to-http2, stdio =
# DataChannel). Skips when the Go server binary is not built
# (Dockerfile.ci builds it).

require "base64"
require "open3"
require "socket"
require "grpcdc"
require_relative "test_util"
require_relative "interop_cases_generated"

module TestInteropOracle
  INITIAL_KEY = "x-grpc-test-echo-initial"
  INITIAL_VAL = "test_initial_metadata_value"
  TRAILER_KEY = "x-grpc-test-echo-trailing-bin"
  # -bin values are base64 on the grpc-dc wire: "q83v" is base64
  # for the bytes AB CD EF the official case sends.
  TRAILER_VAL = "q83v"

  def self.payload(size)
    MessagesPb::Payload.new(
      type: MessagesPb::PayloadType::COMPRESSABLE, body: "\0".b * size)
  end

  def self.out_req(resp_sizes, status = nil)
    req = MessagesPb::StreamingOutputCallRequest.new
    req.response_parameters = resp_sizes.map do |s|
      MessagesPb::ResponseParameters.new(size: s)
    end
    req.response_status = status
    req
  end

  def self.expect_status(what, code, message)
    yield
    TestUtil.check(false, "#{what}: expected status error")
  rescue Grpcdc::StatusError => e
    TestUtil.assert_eq(e.code, code, what)
    TestUtil.assert_eq(e.message, message, what) unless message.nil?
  end

  def self.recv_all(stream)
    sizes = []
    begin
      loop { sizes << stream.recv.payload.body.bytesize }
    rescue EOFError
      nil
    end
    sizes
  end

  def self.run_cases(channel, client, unimpl)
    INTEROP_CASES.each do |c|
      what = "interop #{c['name']}"
      case c["kind"]
      when "EMPTY"
        client.EmptyCall(EmptyPb::Empty.new)
      when "LARGE_UNARY"
        req = MessagesPb::SimpleRequest.new(
          response_type: MessagesPb::PayloadType::COMPRESSABLE,
          response_size: c["resp_sizes"][0],
          payload: payload(c["req_sizes"][0]))
        resp = client.UnaryCall(req)
        TestUtil.assert_eq(resp.payload.body.bytesize, c["resp_sizes"][0], what)
      when "CLIENT_STREAMING"
        reqs = c["req_sizes"].map do |s|
          MessagesPb::StreamingInputCallRequest.new(payload: payload(s))
        end
        resp = client.StreamingInputCall(reqs)
        TestUtil.assert_eq(resp.aggregated_payload_size, c["req_sizes"].sum, what)
      when "SERVER_STREAMING"
        stream = client.StreamingOutputCall(out_req(c["resp_sizes"]))
        TestUtil.assert_eq(recv_all(stream), c["resp_sizes"], what)
        stream.close
      when "PING_PONG"
        reqs = c["req_sizes"].each_with_index.map do |s, i|
          r = out_req([c["resp_sizes"][i]])
          r.payload = payload(s)
          r
        end
        stream = client.FullDuplexCall(reqs)
        TestUtil.assert_eq(recv_all(stream), c["resp_sizes"], what)
        stream.close
      when "EMPTY_STREAM"
        stream = client.FullDuplexCall([])
        begin
          stream.recv
          TestUtil.check(false, "#{what}: expected EOF")
        rescue EOFError
          nil
        end
        stream.close
      when "CUSTOM_METADATA"
        md = { INITIAL_KEY => INITIAL_VAL, TRAILER_KEY => TRAILER_VAL }
        stream = client.FullDuplexCall([out_req([314159])], md)
        resp = stream.recv
        TestUtil.assert_eq(resp.payload.body.bytesize, 314159, what)
        headers = stream.headers
        TestUtil.assert_eq(headers && headers[INITIAL_KEY], INITIAL_VAL, what)
        begin
          stream.recv
          TestUtil.check(false, "#{what}: expected EOF")
        rescue EOFError
          nil
        end
        trailers = stream.trailers
        TestUtil.assert_eq(trailers && trailers[TRAILER_KEY], TRAILER_VAL, what)
        stream.close
      when "STATUS_UNARY"
        req = MessagesPb::SimpleRequest.new(
          response_status: MessagesPb::EchoStatus.new(
            code: c["status_code"], message: c["status_message"]))
        expect_status(what, c["status_code"], c["status_message"]) do
          client.UnaryCall(req)
        end
      when "STATUS_DUPLEX"
        req = out_req([], MessagesPb::EchoStatus.new(
          code: c["status_code"], message: c["status_message"]))
        stream = client.FullDuplexCall([req])
        expect_status(what, c["status_code"], c["status_message"]) do
          stream.recv
        end
        stream.close
      when "SPECIAL_STATUS"
        req = MessagesPb::SimpleRequest.new(
          response_status: MessagesPb::EchoStatus.new(
            code: c["status_code"], message: c["status_message"]))
        expect_status(what, c["status_code"], c["status_message"]) do
          client.UnaryCall(req)
        end
      when "CANCEL_AFTER_BEGIN"
        # Begin a client-streaming call and cancel it before
        # sending any request: the pending recv must report
        # CANCELLED.
        stream = channel.open_stream("/grpc.testing.TestService/StreamingInputCall", nil)
        stream.cancel
        expect_status(what, c["status_code"], nil) do
          stream.recv(MessagesPb::StreamingInputCallResponse.new)
        end
      when "CANCEL_AFTER_FIRST"
        # Duplex call (no half-close): the server answers the one
        # request, then waits for more input, so the cancel
        # deterministically lands mid-call (same shape as the
        # Python/JS suites).
        stream = channel.open_stream("/grpc.testing.TestService/FullDuplexCall", nil)
        channel.send_message(stream, out_req([c["resp_sizes"][0]]))
        resp = MessagesPb::StreamingOutputCallResponse.new
        stream.recv(resp)
        TestUtil.assert_eq(resp.payload.body.bytesize, c["resp_sizes"][0], what)
        stream.cancel
        expect_status(what, c["status_code"], nil) do
          stream.recv(MessagesPb::StreamingOutputCallResponse.new)
        end
      when "TIMEOUT_SLEEPING"
        req = MessagesPb::StreamingOutputCallRequest.new
        req.response_parameters = c["resp_sizes"].map do |s|
          MessagesPb::ResponseParameters.new(size: s, interval_us: 1000000)
        end
        req.payload = payload(0)
        expect_status(what, c["status_code"], nil) do
          stream = client.StreamingOutputCall(req, nil, timeout: 0.1)
          loop { stream.recv }
        end
      when "UNIMPLEMENTED_METHOD"
        expect_status(what, c["status_code"], nil) do
          client.UnimplementedCall(EmptyPb::Empty.new)
        end
      when "UNIMPLEMENTED_SERVICE"
        expect_status(what, c["status_code"], nil) do
          unimpl.UnimplementedCall(EmptyPb::Empty.new)
        end
      else
        TestUtil.check(false, "#{what}: unknown kind #{c['kind']}")
      end
      puts "interop case ok: #{c['name']}"
    end
  end

  # Compression rows (upstream client_compressed_unary,
  # client_compressed_streaming, server_compressed_unary,
  # server_compressed_streaming): the DataChannel wire is
  # compression-free; the client declares grpc-encoding: gzip
  # and the bridge gzips request messages on the HTTP/2 hop,
  # decompressing responses the same way.
  def self.run_compression_cases(client)
    gzip = { "grpc-encoding" => "gzip" }
    req = MessagesPb::SimpleRequest.new(
      response_size: 31415, payload: payload(271828),
      expect_compressed: MessagesPb::BoolValue.new(value: true))
    resp = client.UnaryCall(req, gzip)
    TestUtil.assert_eq(resp.payload.body.bytesize, 31415, "client_compressed_unary")
    puts "interop case ok: client_compressed_unary"

    sizes = [27182, 8, 1828, 45904]
    reqs = sizes.map do |s|
      MessagesPb::StreamingInputCallRequest.new(
        payload: payload(s),
        expect_compressed: MessagesPb::BoolValue.new(value: true))
    end
    resp = client.StreamingInputCall(reqs, gzip)
    TestUtil.assert_eq(resp.aggregated_payload_size, sizes.sum, "client_compressed_streaming")
    puts "interop case ok: client_compressed_streaming"

    req = MessagesPb::SimpleRequest.new(
      response_size: 31415, payload: payload(271828),
      response_compressed: MessagesPb::BoolValue.new(value: true))
    resp = client.UnaryCall(req)
    TestUtil.assert_eq(resp.payload.body.bytesize, 31415, "server_compressed_unary")
    puts "interop case ok: server_compressed_unary"

    sizes = [31415, 9, 2653, 58979]
    req = MessagesPb::StreamingOutputCallRequest.new
    req.response_parameters = sizes.map do |s|
      MessagesPb::ResponseParameters.new(size: s, compressed: MessagesPb::BoolValue.new(value: true))
    end
    req.payload = payload(0)
    stream = client.StreamingOutputCall(req)
    TestUtil.assert_eq(recv_all(stream), sizes, "server_compressed_streaming")
    stream.close
    puts "interop case ok: server_compressed_streaming"
  end

  # ORCA rows (upstream orca_per_rpc / orca_oob): per-RPC the
  # report returns as the serialized OrcaLoadReport in the
  # endpoint-load-metrics-bin trailer (base64 -bin value); OOB
  # the value fed through FullDuplexCall comes back on the
  # OpenRcaService StreamCoreMetrics stream.
  def self.run_orca_cases(channel, client)
    req = MessagesPb::SimpleRequest.new(
      orca_per_query_report: MessagesPb::TestOrcaReport.new(
        cpu_utilization: 0.8210, memory_utilization: 0.5847,
        request_cost: { "cost" => 3456.32 }, utilization: { "util" => 0.30499 }))
    stream = channel.server_stream("/grpc.testing.TestService/UnaryCall", req)
    stream.recv(MessagesPb::SimpleResponse.new)
    begin
      stream.recv(MessagesPb::SimpleResponse.new)
      TestUtil.check(false, "orca_per_rpc: expected EOF")
    rescue EOFError
      nil # end of stream: trailers now readable
    end
    encoded = stream.trailers && stream.trailers["endpoint-load-metrics-bin"]
    TestUtil.check(!encoded.nil?, "orca_per_rpc: no endpoint-load-metrics-bin trailer")
    report = OrcaLoadReportPb::OrcaLoadReport.new
    report.unmarshal_dc(Base64.decode64(encoded))
    TestUtil.check(
      report.cpu_utilization == 0.8210 && report.mem_utilization == 0.5847 &&
        report.request_cost["cost"] == 3456.32 && report.utilization["util"] == 0.30499,
      "orca_per_rpc: report mismatch")
    stream.close
    puts "interop case ok: orca_per_rpc"

    feed_req = MessagesPb::StreamingOutputCallRequest.new(
      orca_oob_report: MessagesPb::TestOrcaReport.new(
        cpu_utilization: 0.9, memory_utilization: 0.85, utilization: { "util" => 0.5 }))
    feed = client.FullDuplexCall([feed_req])
    begin
      loop { feed.recv }
    rescue EOFError
      nil # feed call completed
    end
    feed.close
    orca = OrcaGrpcDc::OpenRcaServiceClient.new(channel)
    metrics = orca.StreamCoreMetrics(OrcaPb::OrcaLoadReportRequest.new, nil, timeout: 30)
    matched = false
    30.times do
      got = metrics.recv
      if got.cpu_utilization == 0.9 && got.mem_utilization == 0.85 &&
         got.utilization["util"] == 0.5
        matched = true
        break
      end
    end
    TestUtil.check(matched, "orca_oob: no matching OOB report")
    metrics.close
    puts "interop case ok: orca_oob"
  end

  def self.run
    require "interop/test_grpc_dc"
    require "interop/orca_grpc_dc"
    require "stdio"

    root = TestUtil.root
    server_bin = File.join(root, "oracle", "go-interop", "interop-server")
    TestUtil.skip("go interop server not built") unless File.exist?(server_bin)
    port = TestUtil.free_port
    _in, _out, server_err, server_wait = Open3.popen3(server_bin, "-port", port.to_s)
    Thread.new { server_err.read rescue nil }
    ready = false
    300.times do
      begin
        TCPSocket.new("127.0.0.1", port).close
        ready = true
        break
      rescue IOError, SystemCallError
        sleep 0.1
      end
    end
    unless ready
      OracleCleanup.kill(server_wait)
      TestUtil.skip("interop server did not start")
    end
    stdin, stdout, _stderr, bridge_wait = Open3.popen3(
      "node", File.join(root, "oracle", "bridge.mjs"),
      "dc-to-http2", "--grpc", "127.0.0.1:#{port}")
    begin
      transport = StdioTransport.new(stdin, stdout)
      channel = Grpcdc::Channel.new(transport)
      client = TestGrpcDc::TestServiceClient.new(channel)
      unimpl = TestGrpcDc::UnimplementedServiceClient.new(channel)
      run_cases(channel, client, unimpl)
      run_compression_cases(client)
      run_orca_cases(channel, client)
    ensure
      OracleCleanup.kill(bridge_wait)
      OracleCleanup.kill(server_wait)
    end
    puts "TestInteropOracle OK"
  end

  module OracleCleanup
    def self.kill(wait_thr)
      Process.kill("KILL", wait_thr.pid)
    rescue Errno::ESRCH, NoMethodError
      nil
    end
  end
end
