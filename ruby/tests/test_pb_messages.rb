# Generated Ruby message types (<base>_pb.rb) from the native
# protoc-gen-grpc-dc-ruby plugin: kitchen-sink round-trip plus a
# protoc oracle — protoc's own --encode bytes must decode to the
# same message and re-encode semantically identically.

require "fileutils"
require "open3"
require_relative "test_util"

module TestPbMessages
  def self.run
    tmp = "/tmp/grpcdc-ruby-pb"
    gen = File.join(tmp, "gen")
    FileUtils.rm_rf(tmp)
    FileUtils.mkdir_p(gen)
    run!("protoc --plugin=protoc-gen-grpc-dc-ruby=#{root_bin} " \
         "--grpc-dc-ruby_out=#{gen} -I #{testdata} common.proto kitchen.proto")
    FileUtils.rm_f(File.join(gen, "common_grpc_dc.rb"))
    FileUtils.rm_f(File.join(gen, "kitchen_grpc_dc.rb"))
    File.write(File.join(gen, "harness.rb"), HARNESS)

    ruby = TestUtil.ruby_exe
    out1 = capture!("#{ruby} #{gen}/harness.rb roundtrip")
    TestUtil.assert_includes(out1, "roundtrip OK")

    File.write(File.join(tmp, "kitchen.txt"), KITCHEN_TEXT)
    run!("protoc --encode=kitchen.v1.Kitchen -I #{testdata} kitchen.proto " \
         "< #{tmp}/kitchen.txt > #{tmp}/protoc.bin")
    out2 = capture!("#{ruby} #{gen}/harness.rb oracle #{tmp}/protoc.bin")
    TestUtil.assert_includes(out2, "oracle OK")
    puts "TestPbMessages OK"
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

  KITCHEN_TEXT = <<~TEXT
    d: 1.5 f: 2.5 i32: -3 i64: -4 u32: 5 u64: 6 s32: -7 s64: -8
    f32: 9 f64: 10 sf32: -11 sf64: -12 flag: true name: "sink"
    blob: "\\x01\\x02\\x03" color: GREEN
    nested { note: "n" level: 3 }
    item { sku: "abc" quantity: 2 }
    nums: [1, -2, 300] words: ["a", "", "bc"]
    manys { note: "m" level: 1 }
    vals: [0.5, -1.25]
    counts { key: "x" value: 1 } counts { key: "y" value: -2 }
    by_id { key: 7 value { note: "z" level: 9 } }
    text: "chosen" big_negative: -9007199254740993 neg32: -123456
  TEXT

  HARNESS = <<~RUBY
    $LOAD_PATH.unshift(__dir__)
    require "kitchen_pb"
    require "common_pb"

    def fail!(msg)
      warn "FAIL: \#{msg}"
      exit(1)
    end

    def make
      KitchenPb::Kitchen.new(
        d: 1.5, f: 2.5, i32: -3, i64: -4, u32: 5, u64: 6, s32: -7, s64: -8,
        f32: 9, f64: 10, sf32: -11, sf64: -12, flag: true, name: "sink",
        blob: "\\x01\\x02\\x03".b, color: KitchenPb::Color::GREEN,
        nested: KitchenPb::Nested.new(note: "n", level: 3),
        item: CommonPb::Item.new(sku: "abc", quantity: 2),
        nums: [1, -2, 300], words: ["a", "", "bc"],
        manys: [KitchenPb::Nested.new(note: "m", level: 1)],
        vals: [0.5, -1.25], counts: { "x" => 1, "y" => -2 },
        by_id: { 7 => KitchenPb::Nested.new(note: "z", level: 9) },
        text: "chosen", big_negative: -9007199254740993, neg32: -123456)
    end

    def check_same(a, b)
      ok = a.d == b.d && a.f == b.f && a.i32 == b.i32 && a.i64 == b.i64 &&
        a.u32 == b.u32 && a.u64 == b.u64 && a.s32 == b.s32 && a.s64 == b.s64 &&
        a.f32 == b.f32 && a.f64 == b.f64 && a.sf32 == b.sf32 && a.sf64 == b.sf64 &&
        a.flag == b.flag && a.name == b.name && a.blob == b.blob &&
        a.color == b.color &&
        a.nested.note == b.nested.note && a.nested.level == b.nested.level &&
        a.item.sku == b.item.sku && a.item.quantity == b.item.quantity &&
        a.nums == b.nums && a.words == b.words &&
        a.manys.length == 1 && a.manys[0].note == b.manys[0].note &&
        a.vals == b.vals && a.counts == b.counts &&
        a.by_id[7].note == b.by_id[7].note && a.by_id[7].level == b.by_id[7].level &&
        a.text == b.text && a.big_negative == b.big_negative && a.neg32 == b.neg32
      fail!("mismatch") unless ok
    end

    k = make
    if ARGV[0] == "roundtrip"
      back = KitchenPb::Kitchen.new
      back.unmarshal_dc(k.marshal_dc)
      check_same(back, k)
      fail!("empty") unless KitchenPb::Kitchen.new.marshal_dc == "".b
      both = KitchenPb::Kitchen.new(text: "a", code: 7)
      both_back = KitchenPb::Kitchen.new
      both_back.unmarshal_dc(both.marshal_dc)
      fail!("oneof encode clearing") unless both_back.text == "" && both_back.code == 7
      puts "roundtrip OK"
    else
      from = KitchenPb::Kitchen.new
      from.unmarshal_dc(File.binread(ARGV[1]))
      check_same(from, k)
      again = KitchenPb::Kitchen.new
      again.unmarshal_dc(from.marshal_dc)
      check_same(again, from)
      puts "oracle OK"
    end
  RUBY
end
