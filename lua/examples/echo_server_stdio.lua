local scriptDir = arg[0]:match("^(.*)/lua/examples/[^/]+$") or "."
package.path = scriptDir .. "/lua/?.lua;" .. package.path

local serverModule = require("grpcdc.server")
local stdioModule = require("examples.stdio_transport")
local stubs = require("examples.echo_grpc_dc")
local impl = require("examples.echo_service_impl")

--- Interop harness: the Lua echo server over stdio. Other languages'
--- tests spawn this and drive it with their clients, proving the
--- runtimes interoperate on the same frames. Serves until stdin EOF.
local transport = stdioModule.StdioTransport.new(io.stdin, io.stdout)
local server = serverModule.Server.new()
stubs.registerEchoServer(server, impl)
local endpoint = server:serveTransport(transport)
while not transport.eof do
  endpoint:pump()
end
