# Interop: Ruby runtime against the Go stdio harnesses (cross-
# language wire compatibility). Skips when Go is unavailable.
# Mirrors python/tests/test_interop.py.

require "fileutils"
require "open3"
require "tmpdir"
require "grpcdc"
require_relative "test_util"

module TestInterop
  ROOT = TestUtil.root
  GO_DIR = File.join(ROOT, "go")
  RUBY_DIR = File.join(ROOT, "ruby")

  def self.build_go(out, pkg)
    TestUtil.skip("go not available") unless TestUtil.which("go")

    _stdout, stderr, status = Open3.capture3("go", "build", "-o", out, pkg, chdir: GO_DIR)
    TestUtil.skip("go build #{pkg}: #{stderr}") unless status.success?
  end

  def self.req(message, count = 0)
    EchoPb::EchoRequest.new(message: message, count: count)
  end

  def self.run
    require "echo_grpc_dc"
    require "echo_pb"
    require "stdio"

    ruby_client_calls_go_server
    go_client_calls_ruby_server
  end

  def self.ruby_client_calls_go_server
    Dir.mktmpdir do |tmp|
      server_bin = File.join(tmp, "echo_server_stdio")
      build_go(server_bin, "./examples/echo_server_stdio")
      stdin, stdout, _stderr, wait_thr = Open3.popen3(server_bin)
      begin
        transport = StdioTransport.new(stdin, stdout)
        client = EchoGrpcDc::EchoClient.new(Grpcdc::Channel.new(transport))

        unary = client.Unary(req("hello"))
        TestUtil.assert_eq(unary.message, "echo: hello", "interop unary")

        ticks = client.ServerStream(req("tick", 3)).to_a
        TestUtil.assert_eq(ticks.map(&:index), [0, 1, 2], "interop server_stream")

        joined = client.ClientStream(%w[a b c].map { |m| req(m) })
        TestUtil.assert_eq(joined.message, "a+b+c", "interop client_stream")

        echoed = client.Bidi(%w[x y].map { |m| req(m) }).to_a
        TestUtil.assert_eq(echoed.map(&:message), %w[x y], "interop bidi")

        begin
          client.Unary(req("fail"))
          raise "expected StatusError"
        rescue Grpcdc::StatusError => e
          TestUtil.assert_eq(e.code, 3, "interop error status")
        end
      ensure
        begin
          Process.kill("KILL", wait_thr.pid)
        rescue Errno::ESRCH
          nil
        end
      end
    end
  end

  def self.go_client_calls_ruby_server
    Dir.mktmpdir do |tmp|
      client_bin = File.join(tmp, "echo_client_stdio")
      build_go(client_bin, "./examples/echo_client_stdio")
      s_in, s_out, _s_err, s_wait = Open3.popen3(
        TestUtil.ruby_exe, File.join(RUBY_DIR, "examples", "echo_server_stdio.rb")
      )
      c_in, c_out, c_err, c_wait = Open3.popen3(client_bin)
      begin
        pumps = [
          Thread.new { pump(c_out, s_in) },
          Thread.new { pump(s_out, c_in) }
        ]
        unless c_wait.join(60)
          raise "go client harness timed out"
        end
        # stdout is owned by the pump thread; stderr is ours alone.
        text = c_err.read
        TestUtil.assert_includes(text, "unary=echo: hello")
        TestUtil.assert_includes(text, "server_stream=tick#0,tick#1,tick#2")
        TestUtil.assert_includes(text, "client_stream=a+b+c")
        TestUtil.assert_includes(text, "bidi=x,y")
        pumps.each { |t| t.kill }
      ensure
        [s_wait, c_wait].each do |w|
          begin
            Process.kill("KILL", w.pid)
          rescue Errno::ESRCH
            nil
          end
        end
      end
    end
  end

  def self.pump(src, dst)
    IO.copy_stream(src, dst)
  rescue IOError, Errno::EPIPE
    nil
  ensure
    begin
      dst.close
    rescue IOError
      nil
    end
  end
end
