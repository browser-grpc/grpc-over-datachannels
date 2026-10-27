local scriptDir = arg[0]:match("^(.*)/lua/tests/[^/]+$") or "."
package.path = scriptDir .. "/lua/?.lua;" .. scriptDir .. "/lua/tests/?.lua;" .. package.path

-- Test runner: lua lua/tests/main.lua <TestCodec|TestEcho|TestInterop|TestOracle|TestDynamic|TestBdd|TestCoro|TestDeadline|TestPbMessages>
local name = arg[1]
if name == nil then
  io.stderr:write("usage: main.lua <TestCodec|TestEcho|TestInterop|TestOracle|TestDynamic|TestBdd|TestCoro|TestDeadline|TestPbMessages>\n")
  os.exit(2)
end

local ok, err = pcall(function()
  if name == "TestCodec" then
    require("test_codec")()
  elseif name == "TestEcho" then
    require("test_echo")()
  elseif name == "TestBdd" then
    require("test_bdd")()
  elseif name == "TestEventBus" then
    require("test_eventbus")()
  elseif name == "TestInterop" then
    require("test_interop")()
  elseif name == "TestInteropOracle" then
    require("test_interop_oracle")()
  elseif name == "TestInteropServerOracle" then
    require("test_interop_server_oracle")()
  elseif name == "TestOracle" then
    require("test_oracle")()
  elseif name == "TestDynamic" then
    require("test_dynamic")()
  elseif name == "TestCoro" then
    require("test_coro")()
  elseif name == "TestDeadline" then
    require("test_deadline")()
  elseif name == "TestPbMessages" then
    require("test_pb_messages")()
  elseif name == "TestSidecar" then
    require("test_sidecar")()
  elseif name == "TestBddSchemas" then
    require("test_bdd_schemas")()
  else
    io.stderr:write("unknown test: " .. name .. "\n")
    os.exit(2)
  end
end)
if not ok then
  io.stderr:write(tostring(err) .. "\n")
  os.exit(1)
end
