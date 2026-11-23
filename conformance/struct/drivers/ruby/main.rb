# Struct corpus driver (ruby): generated struct codec vs Go golden.
require "grpcdc"
require "msgs_pb"

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
puts "DECODE_OK"
