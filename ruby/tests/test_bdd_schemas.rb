# BDD schema scenarios: golden protoc bytes, generated classes.
# The case table (bdd_schemas_generated.rb, generated from
# the schema scenarios) carries protoc's own --encode output
# over webapp/testdata/{kitchen,features}.proto. Each case
# decodes with the generated classes and re-encodes
# byte-identically. The generated-classes harness mirrors
# test_pb_messages.rb.

require "fileutils"
require "open3"
require_relative "test_util"
require_relative "bdd_schemas_generated"

module TestBddSchemas
  def self.run
    tmp = "/tmp/grpcdc-ruby-schemas"
    gen = File.join(tmp, "gen")
    FileUtils.rm_rf(tmp)
    FileUtils.mkdir_p(gen)
    run!("protoc --plugin=protoc-gen-grpc-dc-ruby=#{root_bin} " \
         "--grpc-dc-ruby_out=#{gen} -I #{testdata} common.proto kitchen.proto features.proto")
    FileUtils.rm_f(File.join(gen, "common_grpc_dc.rb"))
    FileUtils.rm_f(File.join(gen, "kitchen_grpc_dc.rb"))
    FileUtils.rm_f(File.join(gen, "features_grpc_dc.rb"))
    File.write(File.join(gen, "harness.rb"), HARNESS)

    ruby = TestUtil.ruby_exe
    out = capture!("#{ruby} #{gen}/harness.rb")
    TestUtil.assert_includes(out, "schemas OK")
    puts "TestBddSchemas OK"
  end

  def self.root_bin
    File.join(TestUtil.root, "bin", "protoc-gen-grpc-dc-ruby")
  end

  def self.testdata
    File.join(TestUtil.root, "webapp", "testdata")
  end

  def self.run!(cmd)
    return if system(cmd)

    raise "command failed: #{cmd}"
  end

  def self.capture!(cmd)
    out, status = Open3.capture2e(cmd)
    raise "capture failed: #{cmd} -> #{out}" unless status.success?

    out
  end

  CASES_LITERAL = BDD_SCHEMAS.map { |row|
    "    [#{row.map { |v| v.inspect }.join(', ')}],"
  }.join("\n")

  HARNESS = <<~RUBY
    $LOAD_PATH.unshift(__dir__)
    require "kitchen_pb"
    require "features_pb"

    def fail!(msg)
      warn "FAIL: \#{msg}"
      exit(1)
    end

    CASES = [
    #{CASES_LITERAL}
    ]

    CASES.each do |name, message, input, expect|
      got =
        case message
        when "kitchen"
          m = KitchenPb::Kitchen.new
          m.unmarshal_dc([input].pack("H*"))
          m.marshal_dc
        when "outer"
          m = FeaturesPb::Outer.new
          m.unmarshal_dc([input].pack("H*"))
          m.marshal_dc
        else
          fail!("unknown message " + message)
        end
      fail!("re-encode mismatch: " + name) unless got.unpack1("H*") == expect
    end
    puts "schemas OK"
  RUBY
end
