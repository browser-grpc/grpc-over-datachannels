# Dynamic (descriptor-driven) runtime: schemas consumed as data at
# runtime, no generated stubs. Loopback plus the official grpc-java
# oracle in both directions (oracle == runtime test bed).
# Mirrors python/tests/test_dynamic.py.

require "open3"
require "grpcdc"
require_relative "test_util"
require_relative "oracle_scenarios_generated"
require_relative "test_oracle"

module TestDynamic
  ROOT = TestUtil.root
  SERVICE = "echo.Echo"

  def self.load_model
    path = File.join(ROOT, "fixtures", "echo_descriptor_set.bin")
    TestUtil.skip("descriptor fixture missing (make generate)") unless File.exist?(path)

    Grpcdc.parse_descriptor_set(File.binread(path))
  end

  def self.request(model, message, count = 0)
    Grpcdc::GenericMessage.new(model.messages.fetch(".echo.EchoRequest"))
                          .set(1, message).set(2, count)
  end

  def self.run_scenarios(client, model)
    ORACLE_SCENARIOS.each do |c|
      kind = c.fetch("kind")
      messages = c.fetch("messages").map { |m| OracleRunner.unmsg(m) }
      line = "#{kind} #{c.fetch('messages').join(' ')}"
      case kind
      when "UNARY"
        begin
          resp = client.unary(SERVICE, "Unary", request(model, messages[0]))
        rescue Grpcdc::StatusError => e
          if c["expect_status"]
            TestUtil.assert_eq(e.code, c["expect_status"], line)
            next
          end
          raise
        end
        TestUtil.assert_eq(resp.get_string(1), "echo: #{messages[0]}", line)
        TestUtil.assert_eq(resp.get_int(2), 0, line)
      when "SERVER_STREAM"
        responses = client.server_stream(
          SERVICE, "ServerStream", request(model, messages[0], c.fetch("count"))
        ).to_a
        TestUtil.assert_eq(responses.length, c.fetch("count"), line)
        responses.each_with_index do |resp, i|
          TestUtil.assert_eq(resp.get_string(1), messages[0], line)
          TestUtil.assert_eq(resp.get_int(2), i, line)
        end
      when "CLIENT_STREAM"
        resp = client.client_stream(
          SERVICE, "ClientStream", messages.map { |m| request(model, m) }
        )
        TestUtil.assert_eq(resp.get_string(1), messages.join("+"), line)
        TestUtil.assert_eq(resp.get_int(2), messages.length, line)
      when "BIDI"
        responses = client.bidi(
          SERVICE, "Bidi", messages.map { |m| request(model, m) }
        ).to_a
        TestUtil.assert_eq(responses.length, messages.length, line)
        responses.each_with_index do |resp, i|
          TestUtil.assert_eq(resp.get_string(1), messages[i], line)
          TestUtil.assert_eq(resp.get_int(2), i, line)
        end
      end
    end
  end

  def self.run
    require "dynamic_echo"
    require "stdio"

    model = load_model

    # Loopback: dynamic client + dynamic server, all shapes.
    a, b = Grpcdc.memory_transport_pair
    server = Grpcdc::Server.new
    Grpcdc.register_dynamic_service(server, model, SERVICE, DynamicEchoService.new)
    server.serve_transport(b)
    client = Grpcdc::DynamicClient.new(Grpcdc::Channel.new(a), model)
    run_scenarios(client, model)

    # Generic encode/decode round trip.
    model_type = model.messages.fetch(".echo.EchoRequest")
    req = request(model, "hi", 2)
    decoded = Grpcdc.decode_generic(model_type, Grpcdc.encode_generic(model_type, req, model), model)
    TestUtil.assert_eq(decoded.get_string(1), "hi", "round trip message")
    TestUtil.assert_eq(decoded.get_int(2), 2, "round trip count")

    # Unknown fields 99 (varint 42) and 100 (string "x") are
    # retained across a decode -> encode round trip.
    payload = ["0a0268691002"].pack("H*") +
              [0x98, 0x06, 0x2A].pack("C*") + [0xA2, 0x06, 0x01].pack("C*") + "x".b
    decoded = Grpcdc.decode_generic(model_type, payload, model)
    TestUtil.assert_eq(decoded.unknown.length, 2, "unknown retained")
    TestUtil.assert_eq(Grpcdc.encode_generic(model_type, decoded, model), payload, "unknown re-emitted")

    # Oracle, both directions.
    cp = TestUtil.java_classpath(ROOT)

    server_wait, port = OracleRunner.start_java_server(cp)
    begin
      stdin, stdout, bridge_wait = OracleRunner.start_bridge(
        "dc-to-http2", "--grpc", "127.0.0.1:#{port}", expect: nil
      )
      begin
        transport = StdioTransport.new(stdin, stdout)
        dyn_client = Grpcdc::DynamicClient.new(Grpcdc::Channel.new(transport), model)
        run_scenarios(dyn_client, model)
      ensure
        OracleRunner.kill(bridge_wait)
      end
    ensure
      OracleRunner.kill(server_wait)
    end

    port = TestUtil.free_port
    server_cmd = "#{TestUtil.ruby_exe} #{File.join(ROOT, 'ruby', 'examples', 'dynamic_echo_server_stdio.rb')}"
    _stdin, _stdout, bridge_wait = OracleRunner.start_bridge(
      "http2-to-dc", "--port", port.to_s, "--target-cmd", server_cmd
    )
    begin
      out, err, status = Open3.capture3(
        "java", "-cp", cp, "dc.oracle.OracleClient", port.to_s,
        File.join(ROOT, "fixtures", "oracle_scenarios.txt")
      )
      TestUtil.assert_eq(status.exitstatus, 0, out + err)
      TestUtil.assert_includes(out, "ORACLE CLIENT: ALL OK")
    ensure
      OracleRunner.kill(bridge_wait)
    end
  end
end
