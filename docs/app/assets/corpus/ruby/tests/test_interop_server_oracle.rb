# Interop oracle, Direction B: the OFFICIAL interop clients
# (grpc-java TestServiceClient, grpc-go interop-client) run the
# canonical cases against the generated Ruby TestService server
# (examples/interop_server_stdio.rb), reached over HTTP/2
# through oracle/bridge.mjs http2-to-dc. Skips when an oracle
# binary or Node is unavailable. Mirrors
# java/tests/TestInteropServerOracle.java. The Java client is
# graded on its "Test completed." marker; the Go client never
# prints failures except through its FATAL line, so absence of
# FATAL is success there.

require "tmpdir"
require_relative "test_util"

module TestInteropServerOracle
  CASES = %w[
    empty_unary
    large_unary
    client_streaming
    server_streaming
    ping_pong
    empty_stream
    custom_metadata
    status_code_and_message
    special_status_message
    unimplemented_method
    unimplemented_service
    cancel_after_begin
    cancel_after_first_response
    timeout_on_sleeping_server
  ].freeze

  JAVA_ONLY = %w[
    cacheable_unary
    client_compressed_unary
    client_compressed_streaming
    server_compressed_unary
    server_compressed_streaming
  ].freeze

  GO_ONLY = %w[orca_per_rpc orca_oob].freeze

  def self.wait_pid(pid, timeout_sec)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_sec
    loop do
      return true if Process.waitpid(pid, Process::WNOHANG)

      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep(0.05)
    end
  end

  def self.kill(pid)
    Process.kill("KILL", pid)
  rescue Errno::ESRCH
    nil
  end

  def self.wait_ready(path, needle, timeout_sec)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_sec
    while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      return true if File.exist?(path) && File.read(path).include?(needle)

      sleep(0.05)
    end
    false
  end

  def self.run_client(dir, tag, cmd, marker)
    pid = spawn(cmd, out: File.join(dir, "#{tag}.out"), err: File.join(dir, "#{tag}.err"))
    TestUtil.check(wait_pid(pid, 120), "client did not exit: #{tag}")
    output = File.read(File.join(dir, "#{tag}.out")) + File.read(File.join(dir, "#{tag}.err"))
    if marker
      TestUtil.check(output.include?(marker), "client output for #{tag}:\n#{output}")
    else
      TestUtil.check(!output.include?("FATAL"), "client output for #{tag}:\n#{output}")
    end
  end

  def self.run
    root = TestUtil.root
    cp = TestUtil.java_classpath(root)
    Dir.mktmpdir do |dir|
      server_bin = "#{TestUtil.ruby_exe} #{File.join(root, 'ruby/examples/interop_server_stdio.rb')}"
      port = TestUtil.free_port
      bridge = spawn(
        "node #{File.join(root, 'oracle/bridge.mjs')} http2-to-dc " \
        "--port #{port} --target-cmd '#{server_bin}'",
        out: File.join(dir, "bridge.out"), err: File.join(dir, "bridge.err"))
      unless wait_ready(File.join(dir, "bridge.err"), "listening", 60)
        kill(bridge)
        TestUtil.skip("bridge did not start")
      end
      begin
        (CASES + JAVA_ONLY).each do |test_case|
          run_client(dir, "java_#{test_case}",
            "java -cp #{cp} io.grpc.testing.integration.TestServiceClient " \
            "--server_host=127.0.0.1 --server_port=#{port} " \
            "--test_case=#{test_case} --use_tls=false",
            "Test completed.")
          puts "interop B case ok: #{test_case} (java client)"
        end
        go_client = File.join(root, "oracle", "go-interop", "interop-client")
        if File.exist?(go_client)
          (CASES + GO_ONLY).each do |test_case|
            cmd = "#{go_client} -server_host 127.0.0.1 -server_port #{port} -test_case #{test_case}"
            if test_case.start_with?("orca")
              cmd += " -service_config_json '{ \"loadBalancingConfig\": [{ \"test_backend_metrics_load_balancer\": {} }]}'"
            end
            run_client(dir, "go_#{test_case}", cmd, nil)
            puts "interop B case ok: #{test_case} (go client)"
          end
        else
          puts "TestInteropServerOracle GO SKIP (go client not built)"
        end
      ensure
        kill(bridge)
      end
    end
    puts "TestInteropServerOracle OK"
  end
end
