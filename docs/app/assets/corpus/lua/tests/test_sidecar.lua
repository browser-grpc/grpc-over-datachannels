-- gRPC over WebRTC-Direct via the Rust sidecar, Lua to Lua:
-- two direct_sidecar processes own the WebRTC stack; the Lua
-- server and client only speak length-prefixed TCP to their
-- local sidecar through grpcdc.sidecar_transport, with the TCP
-- socket itself provided by the host (host_socket.lua) because
-- pure Lua has no stdlib sockets.
local channelModule = require("grpcdc.channel")
local statusModule = require("grpcdc.status")
local sidecarModule = require("grpcdc.sidecar_transport")
local stubs = require("examples.echo_grpc_dc")
local messages = require("examples.echo_messages")
local hostSocket = require("host_socket")
local util = require("test_util")

local EchoRequest = messages.EchoRequest
local EndOfStream = statusModule.EndOfStream

local function req(message, count)
  return EchoRequest.new(message, count)
end

local function sidecarBin(root)
  local bin = root .. "/webrtc/rust/target/debug/examples/direct_sidecar"
  if not util.fileExists(bin) then
    util.check(os.execute("cd " .. root .. "/webrtc/rust && cargo build --example direct_sidecar") == true,
      "cargo build direct_sidecar")
  end
  return bin
end

local function testSidecar()
  local root = util.root()
  local bin = sidecarBin(root)
  local luaBin = os.getenv("LUA") or "lua"

  -- Lua server subprocess (accepts the listen sidecar's TCP
  -- connection on langPort and serves Echo).
  local langPort = util.freePort()
  local serverDir = util.tmpdir()
  local serverPid = util.spawnToFiles(
    luaBin .. " lua/tests/sidecar_server.lua " .. langPort,
    serverDir .. "/out.txt", serverDir .. "/err.txt")

  -- Listen sidecar: prints its multiaddr once bound.
  local listenDir = util.tmpdir()
  local listenPid = util.spawnToFiles(
    bin .. " listen --udp 127.0.0.1:0 --tcp 127.0.0.1:" .. langPort,
    listenDir .. "/out.txt", listenDir .. "/err.txt")
  util.check(util.waitReady(listenDir .. "/out.txt", "MULTIADDR", 30), "listen sidecar multiaddr")
  local multiaddr = util.readFile(listenDir .. "/out.txt"):match("(/ip[^\n]+)")
  util.check(multiaddr ~= nil, "multiaddr parse")

  -- Dial sidecar: the language client connects to its TCP port,
  -- which triggers the Direct dial.
  local clientPort = util.freePort()
  local dialDir = util.tmpdir()
  local dialPid = util.spawnToFiles(
    bin .. " dial --multiaddr " .. multiaddr .. " --tcp 127.0.0.1:" .. clientPort,
    dialDir .. "/out.txt", dialDir .. "/err.txt")
  util.check(util.waitReady(dialDir .. "/out.txt", "TCP", 30), "dial sidecar tcp")

  local transport = sidecarModule.SidecarTransport.connect(
    function(h, p) return hostSocket.connect(h, p) end, "127.0.0.1", clientPort)
  local client = stubs.EchoClient.new(channelModule.Channel.new(transport))

  local unary = client:unary(req("hello", 0))
  util.check(unary.message == "echo: hello", "sidecar unary: " .. tostring(unary.message))

  local stream = client:serverStream(req("tick", 3))
  local indexes = {}
  while true do
    local ok, resp = pcall(function() return stream:recv() end)
    if not ok then
      if resp == EndOfStream then break end
      error(resp, 0)
    end
    indexes[#indexes + 1] = resp.index
  end
  util.check(#indexes == 3 and indexes[1] == 0 and indexes[2] == 1 and indexes[3] == 2,
    "sidecar stream indexes")

  util.kill(dialPid)
  util.kill(listenPid)
  util.kill(serverPid)
  print("TestSidecar OK")
end

return testSidecar
