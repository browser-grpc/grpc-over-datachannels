local scriptDir = arg[0]:match("^(.*)/lua/examples/[^/]+$") or "."
package.path = scriptDir .. "/lua/?.lua;" .. package.path

local serverModule = require("grpcdc.server")
local dynamic = require("grpcdc.dynamic")
local stdioModule = require("examples.stdio_transport")
local impl = require("examples.dynamic_echo_service")

--- Interop harness: the dynamic (descriptor-driven) Lua echo server
--- over stdio. Loads fixtures/echo_descriptor_set.bin at runtime —
--- no generated stubs involved. Used by the oracle tests.
local function locateFixtures()
  local dir = scriptDir
  for _ = 1, 8 do
    local direct = dir .. "/fixtures/echo_descriptor_set.bin"
    local f = io.open(direct, "rb")
    if f then
      f:close()
      return direct
    end
    local nested = dir .. "/grpc-over-datachannels/fixtures/echo_descriptor_set.bin"
    f = io.open(nested, "rb")
    if f then
      f:close()
      return nested
    end
    local parent = dir:match("^(.*)/[^/]+$")
    if parent == nil or parent == dir then break end
    dir = parent
  end
  return nil
end

local fixture = locateFixtures()
if fixture == nil then
  io.stderr:write("fixtures/echo_descriptor_set.bin not found\n")
  os.exit(1)
end
local fh = assert(io.open(fixture, "rb"))
local data = fh:read("a")
fh:close()

local model = dynamic.parseDescriptorSet(data)
local transport = stdioModule.StdioTransport.new(io.stdin, io.stdout)
local server = serverModule.Server.new()
dynamic.registerDynamicService(server, model, "echo.Echo", impl)
local endpoint = server:serveTransport(transport)
while not transport.eof do
  endpoint:pump()
end
