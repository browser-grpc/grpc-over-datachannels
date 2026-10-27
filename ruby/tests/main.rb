# Test runner: ruby ruby/tests/main.rb <TestCodec|TestEcho|TestInterop|TestOracle|TestDynamic|TestBdd|TestFiber|TestDeadline|TestPbMessages|TestBddSchemas>

root = File.expand_path("..", __dir__)
$LOAD_PATH.unshift(root)
$LOAD_PATH.unshift(File.join(root, "examples"))
$LOAD_PATH.unshift(__dir__)

require_relative "test_util"

name = ARGV[0]
if name.nil?
  warn "usage: main.rb <TestCodec|TestEcho|TestInterop|TestOracle|TestDynamic|TestBdd|TestFiber|TestDeadline|TestPbMessages>"
  exit(2)
end

begin
  case name
  when "TestCodec"
    require_relative "test_codec"
    TestCodec.run
  when "TestEcho"
    require_relative "test_echo"
    TestEcho.run
  when "TestInterop"
    require_relative "test_interop"
    TestInterop.run
  when "TestInteropOracle"
    require_relative "test_interop_oracle"
    TestInteropOracle.run
  when "TestInteropServerOracle"
    require_relative "test_interop_server_oracle"
    TestInteropServerOracle.run
  when "TestOracle"
    require_relative "test_oracle"
    TestOracle.run
  when "TestDynamic"
    require_relative "test_dynamic"
    TestDynamic.run
  when "TestBdd"
    require_relative "test_bdd"
    TestBdd.run
  when "TestFiber"
    require_relative "test_fiber"
    TestFiber.run
  when "TestDeadline"
    require_relative "test_deadline"
    TestDeadline.run
  when "TestPbMessages"
    require_relative "test_pb_messages"
    TestPbMessages.run
  when "TestBddSchemas"
    require_relative "test_bdd_schemas"
    TestBddSchemas.run
  when "TestEventBus"
    require_relative "test_eventbus"
    TestEventBus.run
  when "TestSidecar"
    require_relative "test_sidecar"
    TestSidecar.run
  else
    warn "unknown test: #{name}"
    exit(2)
  end
rescue SkipTest => e
  warn "SKIP #{name}: #{e.message}"
  exit(0)
rescue StandardError => e
  warn "FAIL #{name}: #{e.class}: #{e.message}"
  warn e.backtrace.first(12).join("\n")
  exit(1)
end
