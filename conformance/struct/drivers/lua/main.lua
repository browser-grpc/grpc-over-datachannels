-- Struct corpus driver (lua): generated struct codec vs Go golden.
local messages = require("msgs_messages")
local Outer, Inner, Hue = messages.Outer, messages.Inner, messages.Hue

local goldenHex = arg[1]
local golden = (goldenHex:gsub("%s", "")):gsub("..", function(cc)
  return string.char(tonumber(cc, 16))
end)
local function hexOf(b)
  return (b:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

local function inner(v, n)
  return Inner.new(v, n or 0)
end

local m = Outer.new(
  inner("x", -3),
  Hue.RED,
  { 1, -2, 300 },
  { b = inner("second"), a = inner("first", 9) },
  "picked",
  nil,
  string.char(1, 2, 3),
  { "n1", "n2" },
  { inner("i1"), inner("i2"), inner("i3") },
  { [7] = "seven", [2] = "two" },
  3.5,
  0.25,
  true,
  123456789,
  -77
)

local got = m:marshalStruct()
if hexOf(got) ~= goldenHex then
  print("MARSHAL_MISMATCH\n got " .. hexOf(got) .. "\nwant " .. goldenHex)
  os.exit(1)
end
local back = Outer.new()
back:unmarshalStruct(golden)
if hexOf(back:marshalStruct()) ~= goldenHex then
  print("ROUNDTRIP_MISMATCH")
  os.exit(1)
end
print("DECODE_OK")
