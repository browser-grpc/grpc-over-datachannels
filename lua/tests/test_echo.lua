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

local testStreamBreak

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

  testStreamBreak()

  print("TestEcho OK")
end

--- Breaking a server-streaming iteration cancels the call
--- server-side: breaking the generic-for loop closes the closable
--- iterator (RST CANCELLED), and the server handler's next send
--- fails CANCELLED instead of streaming into the void. Mirrors
--- js/test/echo.test.js "breaking a server stream cancels it
--- server-side". The single-threaded runtime runs the counting
--- handler on a coroutine-driven server endpoint: the producer
--- yields after each message and pumps the endpoint between
--- sends, which is what "slow" means cooperatively.
testStreamBreak = function()
  local produced = 0
  local serverEp = nil
  local slowImpl = {}
  for k, v in pairs(impl) do slowImpl[k] = v end
  slowImpl.serverStream = function(self, ctx, request, stream)
    for i = 0, request.count - 1 do
      produced = produced + 1
      stream:send(messages.EchoResponse.new(request.message, i))
      coroutine.yield()
      serverEp:pump()
    end
  end

  local a, b = memoryModule.memoryTransportPair()
  local server = serverModule.Server.new()
  stubs.registerEchoServer(server, slowImpl)
  serverEp = server:serveTransport(b)
  local driveServer = coroutine.wrap(function()
    while true do
      serverEp:pump()
      coroutine.yield()
    end
  end)
  a.peerPump = function(self)
    driveServer()
    return true
  end

  local coro = stubs.EchoClientCoro.new(channelModule.Channel.new(a))
  local seen = 0
  for resp in coro:serverStream(req("tick", 1000)):iter() do
    seen = seen + 1
    if seen == 2 then break end
  end
  util.check(seen == 2, "stream break seen")
  for _ = 1, 4 do driveServer() end
  local settled = produced
  for _ = 1, 4 do driveServer() end
  util.check(produced == settled, "stream break settled")
  util.check(settled < 100, "server kept producing (" .. settled .. ")")
end

return testEcho
