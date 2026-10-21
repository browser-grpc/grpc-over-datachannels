-- Lua Echo server for TestSidecar: accepts one host-socket
-- connection (the listen sidecar connects here once a Direct
-- dialer arrives), serves Echo over SidecarTransport, and pumps
-- the endpoint until the transport closes.
local scriptDir = arg[0]:match("^(.*)/lua/tests/[^/]+$") or "."
package.path = scriptDir .. "/lua/?.lua;" .. scriptDir .. "/lua/tests/?.lua;" .. package.path

local serverModule = require("grpcdc.server")
local sidecarModule = require("grpcdc.sidecar_transport")
local stubs = require("examples.echo_grpc_dc")
local impl = require("examples.echo_service_impl")
local hostSocket = require("host_socket")

local port = tonumber(arg[1])
local socket = hostSocket.accept(port)
if not socket then
  io.stderr:write("host accept failed\n")
  os.exit(1)
end
print("READY")
io.stdout:flush()

local server = serverModule.Server.new()
stubs.registerEchoServer(server, impl)
local endpoint = server:serveTransport(sidecarModule.SidecarTransport.new(socket))
while true do
  if not endpoint:pump() then
    break -- transport at EOF
  end
end
