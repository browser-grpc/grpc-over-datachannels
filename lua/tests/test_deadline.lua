-- Deadlines: grpc-timeout propagation + DEADLINE_EXCEEDED in the
-- cooperative pump loop. A delaying transport wrapper holds back
-- inbound messages so a deadline can fire deterministically in
-- the single-threaded model; ctx budget is checked on the server.

local channelModule = require("grpcdc.channel")
local codecModule = require("grpcdc.codec")
local serverModule = require("grpcdc.server")
local memoryModule = require("grpcdc.memory_transport")
local util = require("test_util")
local stubs = require("examples.echo_grpc_dc")
local messages = require("examples.echo_messages")
local impl = require("examples.echo_service_impl")

local function req(message, count)
  return messages.EchoRequest.new(message, count)
end

local function testDeadline()
  util.check(codecModule.parseTimeout(codecModule.encodeTimeout(0.25)) == 0.25,
    "timeout round trip")
  util.check(codecModule.parseTimeout("10x") == nil, "junk timeout")

  local seenCtx = nil
  local slowImpl = {}
  for k, v in pairs(impl) do slowImpl[k] = v end
  slowImpl.unary = function(self, ctx, request)
    seenCtx = ctx
    return impl.unary(self, ctx, request)
  end

  local a, b = memoryModule.memoryTransportPair()
  local server = serverModule.Server.new()
  stubs.registerEchoServer(server, slowImpl)
  server:serveTransport(b)

  -- Hold inbound messages for 0.4s of clock time.
  local releaseAt = os.clock() + 0.4
  local originalRecv = memoryModule.MemoryTransport.recvMessage
  a.recvMessage = function(self)
    if os.clock() < releaseAt then return nil end
    return originalRecv(self)
  end

  local channel = channelModule.Channel.new(a)
  local client = stubs.EchoClient.new(channel)

  local start = os.clock()
  local ok, err = pcall(function() return client:unary(req("hello", 0), nil, 0.05) end)
  util.check(not ok and err.code == 4, "deadline code: " .. tostring(err))
  util.check(os.clock() - start < 0.35, "deadline fires fast")

  util.check(seenCtx ~= nil, "handler ran")
  util.check(seenCtx.metadata["grpc-timeout"] ~= nil, "grpc-timeout metadata")
  util.check(seenCtx.deadline ~= nil, "ctx deadline")
  util.check(seenCtx:timeRemaining() ~= nil, "ctx remaining")

  -- After the hold expires, a generous deadline succeeds.
  while os.clock() < releaseAt do
    -- busy-wait for the hold to lapse (single-threaded test)
  end
  local joined = client:clientStream({ req("a", 0), req("b", 0) }, nil, 5.0)
  util.check(joined.message == "a+b", "generous timeout: " .. joined.message)

  -- Coroutine client carries the same behavior.
  local holdUntil = os.clock() + 0.4
  a.recvMessage = function(self)
    if os.clock() < holdUntil then return nil end
    return originalRecv(self)
  end
  local coro = stubs.EchoClientCoro.new(channel)
  local ok2, err2 = pcall(function() return coro:unary(req("hello", 0), nil, 0.05) end)
  util.check(not ok2 and err2.code == 4, "coro deadline code: " .. tostring(err2))
end

return testDeadline
