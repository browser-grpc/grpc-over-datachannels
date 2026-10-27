local util = require("test_util")

--- Generated Lua message types (<base>_messages.lua) from the
--- native protoc-gen-grpc-dc-lua plugin: kitchen-sink round-trip
--- plus a protoc oracle — protoc's own --encode bytes must decode
--- to the same message and re-encode semantically identically.
local function testPbMessages()
  local root = util.root()
  local tmp = "/tmp/grpcdc-lua-pb"
  local gen = tmp .. "/gen"

  local function run(cmd)
    util.check(os.execute(cmd) == true, "command failed: " .. cmd)
  end
  local function writeFile(path, content)
    local f = io.open(path, "wb")
    util.check(f ~= nil, "create " .. path)
    f:write(content)
    f:close()
  end
  local function capture(cmd)
    local f = io.popen(cmd .. " 2>&1", "r")
    util.check(f ~= nil, "popen " .. cmd)
    local out = f:read("a") or ""
    local ok = f:close()
    util.check(ok == true, "capture failed: " .. cmd .. " -> " .. out)
    return out
  end

  run("rm -rf " .. tmp)
  -- Generated Lua requires siblings as examples.<base>_messages,
  -- so the plugin output goes into a gen/examples directory.
  run("mkdir -p " .. gen .. "/examples")
  run(string.format(
    "protoc --plugin=protoc-gen-grpc-dc-lua=%s/bin/protoc-gen-grpc-dc-lua --grpc-dc-lua_out=%s/examples -I %s/webapp/testdata common.proto kitchen.proto",
    root, gen, root))
  run("rm -f " .. gen .. "/examples/common_grpc_dc.lua " .. gen .. "/examples/kitchen_grpc_dc.lua")

  writeFile(gen .. "/harness.lua", [=[
local dir = arg[0]:match("^(.*)/[^/]+$") or "."
package.path = dir .. "/?.lua;" .. package.path
local kitchen = require("examples.kitchen_messages")
local common = require("examples.common_messages")

local function fail(msg)
  io.stderr:write("FAIL: " .. msg .. "\n")
  os.exit(1)
end

local function make()
  local nested = kitchen.Nested.new("n", 3)
  local item = common.Item.new("abc", 2)
  local byId = {}
  byId[7] = kitchen.Nested.new("z", 9)
  return kitchen.Kitchen.new(
    1.5, 2.5, -3, -4, 5, 6, -7, -8, 9, 10, -11, -12,
    true, "sink", "\1\2\3", kitchen.Color.GREEN,
    nested, item,
    { 1, -2, 300 }, { "a", "", "bc" }, { kitchen.Nested.new("m", 1) },
    { 0.5, -1.25 }, { x = 1, y = -2 }, byId,
    "chosen", 0, -9007199254740993, -123456)
end

local function checkSame(a, b)
  local ok = a.d == b.d and a.f == b.f and a.i32 == b.i32 and a.i64 == b.i64
    and a.u32 == b.u32 and a.u64 == b.u64 and a.s32 == b.s32 and a.s64 == b.s64
    and a.f32 == b.f32 and a.f64 == b.f64 and a.sf32 == b.sf32 and a.sf64 == b.sf64
    and a.flag == b.flag and a.name == b.name and a.blob == b.blob
    and a.color == b.color
    and a.nested.note == b.nested.note and a.nested.level == b.nested.level
    and a.item.sku == b.item.sku and a.item.quantity == b.item.quantity
    and #a.nums == #b.nums and #a.words == #b.words
    and #a.manys == 1 and a.manys[1].note == b.manys[1].note
    and #a.vals == #b.vals and a.vals[1] == b.vals[1] and a.vals[2] == b.vals[2]
    and a.text == b.text and a.bigNegative == b.bigNegative and a.neg32 == b.neg32
  for i = 1, #a.nums do ok = ok and a.nums[i] == b.nums[i] end
  for i = 1, #a.words do ok = ok and a.words[i] == b.words[i] end
  local counts = 0
  for k, v in pairs(a.counts) do
    counts = counts + 1
    ok = ok and b.counts[k] == v
  end
  ok = ok and counts == 2
  ok = ok and a.byId[7] ~= nil and b.byId[7] ~= nil
    and a.byId[7].note == b.byId[7].note and a.byId[7].level == b.byId[7].level
  if not ok then fail("mismatch") end
end

local k = make()
if arg[1] == "roundtrip" then
  local back = kitchen.Kitchen.new()
  back:unmarshalDc(k:marshalDc())
  checkSame(back, k)
  if kitchen.Kitchen.new():marshalDc() ~= "" then fail("empty") end
  local both = kitchen.Kitchen.new()
  both.text = "a"
  both.code = 7
  local bothBack = kitchen.Kitchen.new()
  bothBack:unmarshalDc(both:marshalDc())
  if bothBack.text ~= "" or bothBack.code ~= 7 then fail("oneof encode clearing") end
  print("roundtrip OK")
  return
end
local f = io.open(arg[2], "rb")
if f == nil then fail("open oracle bytes") end
local bytes = f:read("a")
f:close()
local from = kitchen.Kitchen.new()
from:unmarshalDc(bytes)
checkSame(from, k)
local again = kitchen.Kitchen.new()
again:unmarshalDc(from:marshalDc())
checkSame(again, from)
print("oracle OK")
]=])

  local lua = os.getenv("LUA") or "lua"
  local out1 = capture(lua .. " " .. gen .. "/harness.lua roundtrip")
  util.check(out1:find("roundtrip OK", 1, true) ~= nil, "roundtrip: " .. out1)

  writeFile(tmp .. "/kitchen.txt", [=[
d: 1.5 f: 2.5 i32: -3 i64: -4 u32: 5 u64: 6 s32: -7 s64: -8
f32: 9 f64: 10 sf32: -11 sf64: -12 flag: true name: "sink"
blob: "\x01\x02\x03" color: GREEN
nested { note: "n" level: 3 }
item { sku: "abc" quantity: 2 }
nums: [1, -2, 300] words: ["a", "", "bc"]
manys { note: "m" level: 1 }
vals: [0.5, -1.25]
counts { key: "x" value: 1 } counts { key: "y" value: -2 }
by_id { key: 7 value { note: "z" level: 9 } }
text: "chosen" big_negative: -9007199254740993 neg32: -123456
]=])
  run(string.format(
    "protoc --encode=kitchen.v1.Kitchen -I %s/webapp/testdata kitchen.proto < %s/kitchen.txt > %s/protoc.bin",
    root, tmp, tmp))
  local out2 = capture(lua .. " " .. gen .. "/harness.lua oracle " .. tmp .. "/protoc.bin")
  util.check(out2:find("oracle OK", 1, true) ~= nil, "oracle: " .. out2)
  print("TestPbMessages OK")
end

return testPbMessages
