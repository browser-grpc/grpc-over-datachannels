local channelModule = require("grpcdc.channel")
local serverModule = require("grpcdc.server")
local statusModule = require("grpcdc.status")
local memoryModule = require("grpcdc.memory_transport")
local stubs = require("examples.echo_grpc_dc")
local impl = require("examples.echo_service_impl")
local messages = require("examples.echo_messages")
local util = require("test_util")

local EchoRequest = messages.EchoRequest
local EndOfStream = statusModule.EndOfStream

local function req(message, count)
  return EchoRequest.new(message, count)
end

--- Loopback end-to-end: all four shapes, error status, metadata.
--- The single-threaded runtime pumps the peer endpoint from inside
--- client calls (memory transport peerPump), so no threads are
--- needed for a full client+server exchange in one process.
local function testEcho()
  local a, b = memoryModule.memoryTransportPair()
  local server = serverModule.Server.new()
  stubs.registerEchoServer(server, impl)
  server:serveTransport(b)
  local client = stubs.EchoClient.new(channelModule.Channel.new(a))

  local unary = client:unary(req("hello", 0))
  util.check(unary.message == "echo: hello" and unary.index == 0, "unary: " .. unary.message)

  local stream = client:serverStream(req("tick", 3))
  local indexes = {}
  while true do
    local ok, resp = pcall(function() return stream:recv() end)
    if not ok then
      if resp == EndOfStream then break end
      error(resp, 0)
    end
    util.check(resp.message == "tick", "stream message: " .. resp.message)
    indexes[#indexes + 1] = resp.index
  end
  util.check(#indexes == 3 and indexes[1] == 0 and indexes[2] == 1 and indexes[3] == 2,
    "stream indexes")

  local joined = client:clientStream({ req("a", 0), req("b", 0), req("c", 0) })
  util.check(joined.message == "a+b+c" and joined.index == 3, "client stream: " .. joined.message)

  local bidi = client:bidi({ req("x", 0), req("y", 0) })
  local echoed = {}
  while true do
    local ok, resp = pcall(function() return bidi:recv() end)
    if not ok then
      if resp == EndOfStream then break end
      error(resp, 0)
    end
    echoed[#echoed + 1] = resp.message
  end
  util.check(#echoed == 2 and echoed[1] == "x" and echoed[2] == "y", "bidi")

  local ok, err = pcall(function() return client:unary(req("fail", 0)) end)
  util.check(not ok, "fail call should raise")
  util.check(type(err) == "table" and err.code == 3, "fail status: " .. tostring(err))

  local withMd = client:unary(req("hello", 0), { ["x-echo"] = "meta" })
  util.check(withMd.message == "echo: hello [meta]", "metadata: " .. withMd.message)

  print("TestEcho OK")
end

return testEcho
