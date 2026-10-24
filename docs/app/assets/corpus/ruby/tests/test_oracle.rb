# Oracle tests: the official grpc-java implementation, bridged over
# TCP<->DataChannel by ../../oracle/bridge.mjs, must agree with the
# Ruby runtime on every case of the generated scenario table
# (oracle_scenarios_generated.rb, generated from the oracle scenarios).
# Skips when the Java oracle or Node bridge are unavailable
# (Dockerfile.ci provides both). Mirrors python/tests/test_oracle.py.

require "open3"
require "grpcdc"
require_relative "test_util"
require_relative "oracle_scenarios_generated"

# Shared helpers for the oracle-shaped test suites.
module OracleRunner
  ROOT = TestUtil.root

  def self.unmsg(token)
    token == "-" ? "" : token
  end

  def self.req(message, count = 0)
    EchoPb::EchoRequest.new(message: message, count: count)
  end

  # Run the generated scenario table against a static EchoClient.
  def self.run_scenarios(client)
    ORACLE_SCENARIOS.each do |c|
      kind = c.fetch("kind")
      messages = c.fetch("messages").map { |m| unmsg(m) }
      line = "#{kind} #{c.fetch('messages').join(' ')}"
      case kind
      when "UNARY"
        message = messages[0]
        begin
          resp = client.Unary(req(message))
        rescue Grpcdc::StatusError => e
          if c["expect_status"]
            TestUtil.assert_eq(e.code, c["expect_status"], line)
            next
          end
          raise
        end
        TestUtil.assert_eq(resp.message, "echo: #{message}", line)
        TestUtil.assert_eq(resp.index, 0, line)
      when "SERVER_STREAM"
        message = messages[0]
        responses = client.ServerStream(req(message, c.fetch("count"))).to_a
        TestUtil.assert_eq(responses.length, c.fetch("count"), line)
        responses.each_with_index do |resp, i|
          TestUtil.assert_eq(resp.message, message, line)
          TestUtil.assert_eq(resp.index, i, line)
        end
      when "CLIENT_STREAM"
        resp = client.ClientStream(messages.map { |m| req(m) })
        TestUtil.assert_eq(resp.message, messages.join("+"), line)
        TestUtil.assert_eq(resp.index, messages.length, line)
      when "BIDI"
        responses = client.Bidi(messages.map { |m| req(m) }).to_a
        TestUtil.assert_eq(responses.length, messages.length, line)
        responses.each_with_index do |resp, i|
          TestUtil.assert_eq(resp.message, messages[i], line)
          TestUtil.assert_eq(resp.index, i, line)
        end
      else
        raise "unknown scenario kind: #{kind}"
      end
    end
  end

  def self.kill(wait_thr)
    Process.kill("KILL", wait_thr.pid)
  rescue Errno::ESRCH
    nil
  end

  # Spawn the Java oracle server; returns [wait_thr, port].
  def self.start_java_server(cp)
    port = TestUtil.free_port
    r_in, _r_out, stderr, wait_thr = Open3.popen3(
      "java", "-cp", cp, "dc.oracle.OracleServer", port.to_s
    )
    r_in.close
    ready = false
    while (line = stderr.gets)
      if line.include?("READY")
        ready = true
        break
      end
    end
    TestUtil.skip("java oracle server did not start") unless ready

    [wait_thr, port]
  end

  def self.start_bridge(*args, expect: "listening")
    stdin, stdout, stderr, wait_thr = Open3.popen3(
      "node", File.join(ROOT, "oracle", "bridge.mjs"), *args
    )
    if expect
      line = stderr.gets
      TestUtil.skip("bridge did not start: #{line.inspect}") unless line&.include?(expect)
    end
    [stdin, stdout, wait_thr]
  end
end

module TestOracle
  def self.run
    require "echo_grpc_dc"
    require "echo_pb"
    require "stdio"

    root = OracleRunner::ROOT
    cp = TestUtil.java_classpath(root)

    # Ruby client -> official server.
    server_wait, port = OracleRunner.start_java_server(cp)
    begin
      stdin, stdout, bridge_wait = OracleRunner.start_bridge(
        "dc-to-http2", "--grpc", "127.0.0.1:#{port}", expect: nil
      )
      begin
        transport = StdioTransport.new(stdin, stdout)
        client = EchoGrpcDc::EchoClient.new(Grpcdc::Channel.new(transport))
        OracleRunner.run_scenarios(client)
      ensure
        OracleRunner.kill(bridge_wait)
      end
    ensure
      OracleRunner.kill(server_wait)
    end

    # Official client -> Ruby server.
    port = TestUtil.free_port
    server_cmd = "#{TestUtil.ruby_exe} #{File.join(root, 'ruby', 'examples', 'echo_server_stdio.rb')}"
    _stdin, _stdout, bridge_wait = OracleRunner.start_bridge(
      "http2-to-dc", "--port", port.to_s, "--target-cmd", server_cmd
    )
    begin
      out, err, status = Open3.capture3(
        "java", "-cp", cp, "dc.oracle.OracleClient", port.to_s,
        File.join(root, "fixtures", "oracle_scenarios.txt")
      )
      TestUtil.assert_eq(status.exitstatus, 0, out + err)
      TestUtil.assert_includes(out, "ORACLE CLIENT: ALL OK")
    ensure
      OracleRunner.kill(bridge_wait)
    end
  end
end
