# Struct corpus driver (ruby): generated struct codec vs Go golden.
require "grpcdc"
require "msgs_pb"
require "msgs2_pb"

golden_hex = ARGV[0]
golden = [golden_hex].pack("H*")

def inner(v, n = 0)
  MsgsPb::Inner.new(v: v, n: n)
end

m = MsgsPb::Outer.new(
  inner: inner("x", -3),
  hue: MsgsPb::Hue::RED,
  nums: [1, -2, 300],
  by_name: { "b" => inner("second"), "a" => inner("first", 9) },
  s: "picked",
  blob: [1, 2, 3].pack("C*"),
  names: %w[n1 n2],
  inners: [inner("i1"), inner("i2"), inner("i3")],
  by_id: { 7 => "seven", 2 => "two" },
  score: 3.5,
  ratio: 0.25,
  flag: true,
  stamp: 123_456_789,
  delta: -77
)

got = m.marshal_struct
if got.unpack1("H*") != golden_hex
  puts "MARSHAL_MISMATCH\n got #{got.unpack1("H*")}\nwant #{golden_hex}"
  exit 1
end
back = MsgsPb::Outer.new
back.unmarshal_struct(golden)
if back.marshal_struct.unpack1("H*") != golden_hex
  puts "ROUNDTRIP_MISMATCH"
  exit 1
end

# Proto2 shape (msgs2.proto): explicit defaults, unpacked
# repeated, extension field merged as ext_note. Decode into a
# zero-value message: applying proto2 defaults at decode would
# manufacture presence (enabled=true) the struct bytes do not
# carry.
golden2_hex = ARGV[1]
golden2 = [golden2_hex].pack("H*")
p2 = Msgs2Pb::P2.new(
  name: "req",
  count: 42,
  greeting: "hi",
  enabled: false,
  ratio: 2.5,
  nums: [5, -6],
  ext_note: "note!"
)
got2 = p2.marshal_struct
if got2.unpack1("H*") != golden2_hex
  puts "P2_MARSHAL_MISMATCH\n got #{got2.unpack1("H*")}\nwant #{golden2_hex}"
  exit 1
end
back2 = Msgs2Pb::P2.new(name: "", count: 0, greeting: "", enabled: false, ratio: 0.0, nums: [], ext_note: "")
back2.unmarshal_struct(golden2)
if back2.marshal_struct.unpack1("H*") != golden2_hex
  puts "P2_ROUNDTRIP_MISMATCH"
  exit 1
end
puts "DECODE_OK"
