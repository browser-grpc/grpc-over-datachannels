# Micro test harness (no gem dependencies): assertions raise,
# SkipTest skips the current suite with exit 0. Mirrors
# lua/tests/test_util.lua.

require "socket"

class SkipTest < StandardError; end

module TestUtil
  module_function

  def check(cond, what)
    raise "check failed: #{what}" unless cond
  end

  def assert_eq(got, want, what = nil)
    return if got == want

    raise "assert_eq failed#{what ? " (#{what})" : ""}: got #{got.inspect}, want #{want.inspect}"
  end

  def assert_includes(haystack, needle, what = nil)
    return if haystack.include?(needle)

    raise "assert_includes failed#{what ? " (#{what})" : ""}: #{needle.inspect} not in #{haystack.inspect}"
  end

  def skip(reason)
    raise SkipTest, reason
  end

  # Repository root (two levels above ruby/tests).
  def root
    env = ENV["GRPC_DC_ROOT"]
    return env if env && !env.empty?

    File.expand_path("../..", __dir__)
  end

  def ruby_exe
    ENV.fetch("RUBY", "ruby")
  end

  def free_port
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    port
  end

  # Classpath for the Java oracle, or SkipTest when not built.
  def java_classpath(root_path)
    target = File.join(root_path, "oracle", "java", "target")
    cp_file = File.join(target, "cp.txt")
    unless File.exist?(cp_file) && File.directory?(File.join(target, "classes"))
      skip("java oracle not built (cd oracle/java && mvn package)")
    end

    File.join(target, "classes") + ":" + File.read(cp_file).strip
  end

  def which(cmd)
    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |dir|
      File.executable?(File.join(dir, cmd))
    end
  end
end
