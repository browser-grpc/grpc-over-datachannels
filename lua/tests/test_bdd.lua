local channelModule = require("grpcdc.channel")
local serverModule = require("grpcdc.server")
local statusModule = require("grpcdc.status")
local memoryModule = require("grpcdc.memory_transport")
local stubs = require("examples.echo_grpc_dc")
local impl = require("examples.echo_service_impl")
local messages = require("examples.echo_messages")
local bdd = require("bdd_scenarios")
local util = require("test_util")

local EchoRequest = messages.EchoRequest
local EchoResponse = messages.EchoResponse
local EndOfStream = statusModule.EndOfStream

--- BDD: interprets the generated behavior scenarios (bdd_scenarios.lua,
--- generated from the BDD specification; prose in BDD.md) against a
--- loopback client+server. These scenarios are the executable
--- examples, so the documentation cannot drift from the behavior.
local function testBdd()
  local a, b = memoryModule.memoryTransportPair()
  local server = serverModule.Server.new()
  stubs.registerEchoServer(server, impl)
  server:serveTransport(b)
  local channel = channelModule.Channel.new(a)
  local client = stubs.EchoClient.new(channel)

  for _, c in ipairs(bdd.cases) do
    if c.kind == "unary-trailer" then
      local stream = channel:serverStream("/echo.Echo/Unary",
        EchoRequest.new(c.messages[1], 0), { ["x-echo-trailer"] = c.metadata })
      local resp = EchoResponse.new("", 0)
      stream:recv(resp)
      util.check(resp.message == c.expectMessage and resp.index == c.expectNum,
        c.name .. ": response")
      local ok2, err2 = pcall(function()
        stream:recv(EchoResponse.new("", 0))
      end)
      util.check(not ok2, c.name .. ": expected EOF, got " .. tostring(err2))
      util.check(stream.trailers ~= nil and stream.trailers["x-echo-trailer"] == c.metadata,
        c.name .. ": trailer")
    elseif c.kind == "unary" then
      local metadata = nil
      if c.metadata ~= "" then metadata = { ["x-echo"] = c.metadata } end
      local ok, resp = pcall(function()
        return client:unary(EchoRequest.new(c.messages[1], 0), metadata)
      end)
      if ok then
        util.check(c.expectStatus < 0, c.name .. ": expected failure")
        util.check(resp.message == c.expectMessage and resp.index == c.expectNum,
          c.name .. ": response")
      else
        util.check(c.expectStatus >= 0 and type(resp) == "table" and resp.code == c.expectStatus,
          c.name .. ": status " .. tostring(resp))
      end
    elseif c.kind == "server-stream" then
      local stream = client:serverStream(EchoRequest.new(c.messages[1], c.count))
      local got = 0
      while true do
        local ok, resp = pcall(function() return stream:recv() end)
        if not ok then
          if resp == EndOfStream then break end
          error(resp, 0)
        end
        util.check(resp.message == c.expectMessage and resp.index == got,
          c.name .. ": at " .. got)
        got = got + 1
      end
      util.check(got == c.expectNum, c.name .. ": got " .. got)
    elseif c.kind == "client-stream" then
      local reqs = {}
      for i, m in ipairs(c.messages) do reqs[i] = EchoRequest.new(m, 0) end
      local resp = client:clientStream(reqs)
      util.check(resp.message == c.expectMessage and resp.index == c.expectNum,
        c.name .. ": response")
    elseif c.kind == "bidi" then
      local reqs = {}
      for i, m in ipairs(c.messages) do reqs[i] = EchoRequest.new(m, 0) end
      local stream = client:bidi(reqs)
      local got = 0
      while true do
        local ok, resp = pcall(function() return stream:recv() end)
        if not ok then
          if resp == EndOfStream then break end
          error(resp, 0)
        end
        util.check(got < #c.messages and resp.message == c.messages[got + 1] and resp.index == got,
          c.name .. ": at " .. got)
        got = got + 1
      end
      util.check(got == c.expectNum, c.name .. ": got " .. got)
    elseif c.kind == "server-stream-fail" then
      local stream = client:serverStream(EchoRequest.new(c.messages[1], c.count))
      local ok, err = pcall(function()
        while true do stream:recv() end
      end)
      util.check(not ok and type(err) == "table" and err.code == c.expectStatus,
        c.name .. ": status " .. tostring(err))
    elseif c.kind == "bidi-fail" then
      local reqs = {}
      for i, m in ipairs(c.messages) do reqs[i] = EchoRequest.new(m, 0) end
      local stream = client:bidi(reqs)
      local ok, err = pcall(function()
        while true do stream:recv() end
      end)
      util.check(not ok and type(err) == "table" and err.code == c.expectStatus,
        c.name .. ": status " .. tostring(err))
    elseif c.kind == "deadline" then
      local ok, err = pcall(function()
        return client:unary(EchoRequest.new(c.messages[1], 0, c.count), nil, 0.1)
      end)
      util.check(not ok and type(err) == "table" and err.code == c.expectStatus,
        c.name .. ": status " .. tostring(err))
    elseif c.kind == "cancel" then
      local stream = channel:serverStream("/echo.Echo/ServerStream",
        EchoRequest.new(c.messages[1], c.count))
      local first = EchoResponse.new()
      stream:recv(first)
      util.check(first.message == c.messages[1], c.name .. ": first")
      stream.endpoint:cancelStream(stream.streamId)
      local terminated = false
      for _ = 1, c.count + 2 do
        local ok, err = pcall(function()
          local r = EchoResponse.new()
          stream:recv(r)
          return r
        end)
        if not ok then
          terminated = true
          break
        end
      end
      util.check(terminated, c.name .. ": stream did not terminate after cancel")
    elseif c.kind == "stream-break" then
      -- Dedicated counting server (mirrors test_echo.lua
      -- testStreamBreak): breaking the generic-for closes the
      -- closable iterator (RST CANCELLED, no explicit cancel);
      -- "waiting" pumps the coroutine-driven server endpoint.
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
      local a2, b2 = memoryModule.memoryTransportPair()
      local server2 = serverModule.Server.new()
      stubs.registerEchoServer(server2, slowImpl)
      serverEp = server2:serveTransport(b2)
      local driveServer = coroutine.wrap(function()
        while true do
          serverEp:pump()
          coroutine.yield()
        end
      end)
      a2.peerPump = function(self)
        driveServer()
        return true
      end
      local coro = stubs.EchoClientCoro.new(channelModule.Channel.new(a2))
      local seen = 0
      for resp in coro:serverStream(EchoRequest.new(c.messages[1], c.count)):iter() do
        util.check(resp.message == c.messages[1] and resp.index == 0,
          c.name .. ": first")
        seen = seen + 1
        if seen == 1 then break end
      end
      util.check(seen == 1, c.name .. ": seen " .. seen)
      for _ = 1, 4 do driveServer() end
      local settled = produced
      for _ = 1, 4 do driveServer() end
      util.check(produced == settled, c.name .. ": production did not settle")
      util.check(settled < 50, c.name .. ": server kept producing (" .. settled .. ")")
    elseif c.kind == "raw-unary" then
      local ok, resp = pcall(function()
        local r = EchoResponse.new()
        channel:unary(c.path, EchoRequest.new(c.messages[1], 0), r)
        return r
      end)
      util.check(not ok, c.name .. ": expected failure")
      util.check(type(resp) == "table" and resp.code == c.expectStatus,
        c.name .. ": status " .. tostring(resp))
    else
      error("unknown bdd kind: " .. c.kind)
    end
  end
  print("TestBdd OK")
end

return testBdd
