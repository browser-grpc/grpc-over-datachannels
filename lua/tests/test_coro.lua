-- Coroutine surface: CoroutineChannel + generated EchoClientCoro
-- over loopback. Four shapes, coroutine-producer streams via
-- next()/iter(), error status, cancellation.

local channelModule = require("grpcdc.channel")
local serverModule = require("grpcdc.server")
local memoryModule = require("grpcdc.memory_transport")
local util = require("test_util")
local stubs = require("examples.echo_grpc_dc")
local messages = require("examples.echo_messages")
local impl = require("examples.echo_service_impl")

local function req(message, count)
  return messages.EchoRequest.new(message, count)
end

local function setupClient(makeChannel)
  local a, b = memoryModule.memoryTransportPair()
  local server = serverModule.Server.new()
  stubs.registerEchoServer(server, impl)
  server:serveTransport(b)
  return stubs.EchoClientCoro.new(makeChannel(a))
end

local function testCoro()
  local client = setupClient(function(t)
    return channelModule.CoroutineChannel.new(t)
  end)

  local resp = client:unary(req("hello", 0))
  util.check(resp.message == "echo: hello" and resp.index == 0,
    "coro unary: " .. resp.message)

  local stream = client:serverStream(req("tick", 3))
  util.check(stream:next().index == 0, "coro next 0")
  util.check(stream:next().index == 1, "coro next 1")
  util.check(stream:next().index == 2, "coro next 2")
  util.check(stream:next() == nil, "coro next end")
  util.check(stream:next() == nil, "coro next after end")

  local seen = {}
  for r in client:serverStream(req("tick", 2)):iter() do
    seen[#seen + 1] = r.index
  end
  util.check(#seen == 2 and seen[1] == 0 and seen[2] == 1, "coro iter")

  resp = client:clientStream({ req("a", 0), req("b", 0), req("c", 0) })
  util.check(resp.message == "a+b+c", "coro client-stream: " .. resp.message)

  local echoed = {}
  for r in client:bidi({ req("x", 0), req("y", 0) }):iter() do
    echoed[#echoed + 1] = r.message
  end
  util.check(#echoed == 2 and echoed[1] == "x" and echoed[2] == "y", "coro bidi")

  local ok, err = pcall(function() return client:unary(req("fail", 0)) end)
  util.check(not ok and err.code == 3, "coro error status")

  -- Wrapping a plain sync Channel works too.
  local wrapped = setupClient(function(t)
    return channelModule.Channel.new(t)
  end)
  util.check(wrapped:unary(req("wrapped", 0)).message == "echo: wrapped",
    "coro wrapped channel")

  -- Cancellation: abort a long stream; next() raises CANCELLED and
  -- the channel stays usable.
  local long = client:serverStream(req("tick", 100000))
  util.check(long:next().index == 0, "coro cancel first")
  long:cancel()
  local okc, errc = pcall(function()
    while true do long:next() end
  end)
  util.check(not okc and errc.code == 1, "coro cancel status")
  util.check(client:unary(req("after", 0)).message == "echo: after",
    "coro after cancel")
end

return testCoro
