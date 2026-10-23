# BDD: interprets the generated behavior scenarios.
#
# bdd_scenarios_generated.rb is stamped from racket/bdd-spec.rkt;
# the prose lives in BDD.md. The scenarios run against a loopback
# client+server — they are the executable examples, so documentation
# cannot drift from behavior.

require "grpcdc"
require_relative "test_util"
require_relative "bdd_scenarios_generated"

module TestBdd
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
    @channel = Grpcdc::Channel.new(a)
    @client = EchoGrpcDc::EchoClient.new(@channel)

    BDD_SCENARIOS.each do |row|
      name, kind, messages, count, path, metadata, expect_message, expect_num, expect_status = row
      begin
        run_scenario(kind, messages, count, path, metadata, expect_message, expect_num, expect_status)
      rescue StandardError => e
        raise "scenario #{name}: #{e.class}: #{e.message}"
      end
    end
  end

  def self.run_scenario(kind, messages, count, path, metadata, expect_message, expect_num, expect_status)
    case kind
    when "unary"
      md = metadata && !metadata.empty? ? { "x-echo" => metadata } : nil
      if expect_status >= 0
        begin
          @client.Unary(req(messages[0]), md)
          raise "expected StatusError"
        rescue Grpcdc::StatusError => e
          TestUtil.assert_eq(e.code, expect_status, "unary status")
        end
      else
        resp = @client.Unary(req(messages[0]), md)
        TestUtil.assert_eq(resp.message, expect_message, "unary message")
        TestUtil.assert_eq(resp.index, expect_num, "unary index")
      end
    when "server-stream"
      responses = @client.ServerStream(req(messages[0], count)).to_a
      TestUtil.assert_eq(responses.length, expect_num, "server-stream count")
      responses.each_with_index do |resp, i|
        TestUtil.assert_eq(resp.message, expect_message, "server-stream message")
        TestUtil.assert_eq(resp.index, i, "server-stream index")
      end
    when "client-stream"
      resp = @client.ClientStream(messages.map { |m| req(m) })
      TestUtil.assert_eq(resp.message, expect_message, "client-stream message")
      TestUtil.assert_eq(resp.index, expect_num, "client-stream index")
    when "bidi"
      responses = @client.Bidi(messages.map { |m| req(m) }).to_a
      TestUtil.assert_eq(responses.length, expect_num, "bidi count")
      responses.each_with_index do |resp, i|
        TestUtil.assert_eq(resp.message, messages[i], "bidi message")
        TestUtil.assert_eq(resp.index, i, "bidi index")
      end
    when "server-stream-fail"
      begin
        @client.ServerStream(req(messages[0], count)).to_a
        raise "expected StatusError"
      rescue Grpcdc::StatusError => e
        TestUtil.assert_eq(e.code, expect_status, "server-stream-fail status")
      end
    when "bidi-fail"
      begin
        @client.Bidi(messages.map { |m| req(m) }).to_a
        raise "expected StatusError"
      rescue Grpcdc::StatusError => e
        TestUtil.assert_eq(e.code, expect_status, "bidi-fail status")
      end
    when "deadline"
      begin
        delayed = EchoPb::EchoRequest.new(message: messages[0], count: 0, delay_ms: count)
        @client.Unary(delayed, nil, timeout: 0.1)
        raise "expected StatusError"
      rescue Grpcdc::StatusError => e
        TestUtil.assert_eq(e.code, expect_status, "deadline status")
      end
    when "cancel"
      stream = @channel.server_stream("/echo.Echo/ServerStream", req(messages[0], count))
      first = EchoPb::EchoResponse.new
      stream.recv(first)
      TestUtil.assert_eq(first.message, messages[0], "cancel first")
      stream.cancel
      terminated = false
      begin
        (count + 2).times do
          stream.recv(EchoPb::EchoResponse.new)
        end
      rescue StandardError
        terminated = true
      end
      TestUtil.assert_eq(terminated, true, "cancel terminated")
    when "raw-unary"
      begin
        @channel.unary(path, req(messages[0]), EchoPb::EchoResponse.new)
        raise "expected StatusError"
      rescue Grpcdc::StatusError => e
        TestUtil.assert_eq(e.code, expect_status, "raw-unary status")
      end
    else
      raise "unknown bdd kind: #{kind}"
    end
  end
end
