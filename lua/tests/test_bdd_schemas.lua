local schemas = require("bdd_schemas")
local util = require("test_util")

--- BDD schema scenarios: golden protoc bytes, generated classes.
--- The case table (bdd_schemas.lua) is generated from
--- the schema scenarios: protoc's own --encode output over
--- webapp/testdata/{kitchen,features}.proto. Each case decodes
--- with the generated classes and re-encodes byte-identically.
--- The generated-classes harness mirrors test_pb_messages.lua.
local function testBddSchemas()
  local root = util.root()
  local tmp = "/tmp/grpcdc-lua-schemas"
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
    "protoc --plugin=protoc-gen-grpc-dc-lua=%s/bin/protoc-gen-grpc-dc-lua --grpc-dc-lua_out=%s/examples -I %s/webapp/testdata common.proto kitchen.proto features.proto",
    root, gen, root))
  run("rm -f " .. gen .. "/examples/common_grpc_dc.lua " .. gen .. "/examples/kitchen_grpc_dc.lua " .. gen .. "/examples/features_grpc_dc.lua")

  local rows = {}
  for i, c in ipairs(schemas) do
    rows[i] = string.format("  { name = %q, message = %q, input = %q, expect = %q },",
      c.name, c.message, c.input, c.expect)
  end

  writeFile(gen .. "/harness.lua", [=[
local dir = arg[0]:match("^(.*)/[^/]+$") or "."
package.path = dir .. "/?.lua;" .. package.path
local kitchen = require("examples.kitchen_messages")
local features = require("examples.features_messages")

local cases = {
]=] .. table.concat(rows, "\n") .. [=[
}

local function unhex(s)
  return (s:gsub("%x%x", function(cc) return string.char(tonumber(cc, 16)) end))
end
local function hex(s)
  return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

for _, c in ipairs(cases) do
  local got
  if c.message == "kitchen" then
    local m = kitchen.Kitchen.new()
    m:unmarshalDc(unhex(c.input))
    got = m:marshalDc()
  elseif c.message == "outer" then
    local m = features.Outer.new()
    m:unmarshalDc(unhex(c.input))
    got = m:marshalDc()
  else
    io.stderr:write("FAIL: unknown message " .. c.message .. "\n")
    os.exit(1)
  end
  if hex(got) ~= c.expect then
    io.stderr:write("FAIL: re-encode mismatch: " .. c.name .. "\n")
    os.exit(1)
  end
end
print("schemas OK")
]=])

  local lua = os.getenv("LUA") or "lua"
  local out = capture(lua .. " " .. gen .. "/harness.lua")
  util.check(out:find("schemas OK", 1, true) ~= nil, "schemas harness: " .. out)
  print("TestBddSchemas OK")
end

return testBddSchemas
