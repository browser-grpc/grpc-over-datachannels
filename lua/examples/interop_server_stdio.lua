local scriptDir = arg[0]:match("^(.*)/lua/examples/[^/]+$") or "."
package.path = scriptDir .. "/lua/?.lua;" .. package.path

local serverModule = require("grpcdc.server")
local stdioModule = require("examples.stdio_transport")
local testStubs = require("examples.test_grpc_dc")
local orcaStubs = require("examples.orca_grpc_dc")
local impl = require("examples.interop_service_impl")

--- Interop harness: the generated Lua TestService server over
--- stdio. Direction-B oracle tests spawn this and drive it with
--- the official grpc-java / grpc-go interop clients through the
--- bridge (oracle/bridge.mjs http2-to-dc).
local transport = stdioModule.StdioTransport.new(io.stdin, io.stdout)
local server = serverModule.Server.new()
testStubs.registerTestServiceServer(server, impl)
orcaStubs.registerOpenRcaServiceServer(server, impl)
local endpoint = server:serveTransport(transport)
impl.pumpFn = function() endpoint:pump() end
while not transport.eof do
  endpoint:pump()
end
