local statusModule = require("grpcdc.status")
local dynamic = require("grpcdc.dynamic")
local messages = require("examples.echo_messages")
local scenarios = require("oracle_scenarios")
local util = require("test_util")

local EchoRequest = messages.EchoRequest
local EndOfStream = statusModule.EndOfStream
local GenericMessage = dynamic.GenericMessage

local function unmsg(token)
  if token == "-" then return "" end
  return token
end

local function caseMessages(c)
  local out = {}
  for i, m in ipairs(c.messages) do out[i] = unmsg(m) end
  return out
end

local function caseLine(c)
  return c.kind .. " " .. table.concat(c.messages, " ")
end

--- Shared oracle-scenario runner for the typed stub client
--- (TestOracle) and the dynamic client (TestDynamic).
local function runScenarios(client)
  for _, c in ipairs(scenarios.cases) do
    local msgs = caseMessages(c)
    local line = caseLine(c)
    if c.kind == "UNARY" then
      local ok, resp = pcall(function()
        return client:unary(EchoRequest.new(msgs[1], 0))
      end)
      if ok then
        util.check(c.expectStatus < 0, line .. ": expected failure")
        util.check(resp.message == "echo: " .. msgs[1] and resp.index == 0, line .. ": response")
      else
        util.check(c.expectStatus >= 0 and type(resp) == "table" and resp.code == c.expectStatus,
          line .. ": status " .. tostring(resp))
      end
    elseif c.kind == "SERVER_STREAM" then
      local stream = client:serverStream(EchoRequest.new(msgs[1], c.count))
      local got = 0
      while true do
        local ok, resp = pcall(function() return stream:recv() end)
        if not ok then
          if resp == EndOfStream then break end
          error(resp, 0)
        end
        util.check(resp.message == msgs[1] and resp.index == got, line .. ": at " .. got)
        got = got + 1
      end
      util.check(got == c.count, line .. ": got " .. got)
    elseif c.kind == "CLIENT_STREAM" then
      local reqs = {}
      for i, m in ipairs(msgs) do reqs[i] = EchoRequest.new(m, 0) end
      local resp = client:clientStream(reqs)
      util.check(resp.message == table.concat(msgs, "+") and resp.index == #msgs,
        line .. ": response")
    elseif c.kind == "BIDI" then
      local reqs = {}
      for i, m in ipairs(msgs) do reqs[i] = EchoRequest.new(m, 0) end
      local stream = client:bidi(reqs)
      local got = 0
      while true do
        local ok, resp = pcall(function() return stream:recv() end)
        if not ok then
          if resp == EndOfStream then break end
          error(resp, 0)
        end
        util.check(got < #msgs and resp.message == msgs[got + 1] and resp.index == got,
          line .. ": at " .. got)
        got = got + 1
      end
      util.check(got == #msgs, line .. ": got " .. got)
    else
      error("unknown scenario kind: " .. c.kind)
    end
  end
end

local SERVICE = "echo.Echo"

local function dynReq(model, message, count)
  return GenericMessage.new(model:message(".echo.EchoRequest"))
    :set(1, message):set(2, count)
end

local function runDynamicScenarios(client, model)
  for _, c in ipairs(scenarios.cases) do
    local msgs = caseMessages(c)
    local line = caseLine(c)
    if c.kind == "UNARY" then
      local ok, resp = pcall(function()
        return client:unary(SERVICE, "Unary", dynReq(model, msgs[1], 0))
      end)
      if ok then
        util.check(c.expectStatus < 0, line .. ": expected failure")
        util.check(resp:getString(1) == "echo: " .. msgs[1] and resp:getInt(2) == 0,
          line .. ": response")
      else
        util.check(c.expectStatus >= 0 and type(resp) == "table" and resp.code == c.expectStatus,
          line .. ": status " .. tostring(resp))
      end
    elseif c.kind == "SERVER_STREAM" then
      local stream = client:serverStream(SERVICE, "ServerStream", dynReq(model, msgs[1], c.count))
      local responses = stream:collect()
      util.check(#responses == c.count, line .. ": got " .. #responses)
      for i, resp in ipairs(responses) do
        util.check(resp:getString(1) == msgs[1] and resp:getInt(2) == i - 1, line .. ": at " .. i)
      end
    elseif c.kind == "CLIENT_STREAM" then
      local reqs = {}
      for i, m in ipairs(msgs) do reqs[i] = dynReq(model, m, 0) end
      local resp = client:clientStream(SERVICE, "ClientStream", reqs)
      util.check(resp:getString(1) == table.concat(msgs, "+") and resp:getInt(2) == #msgs,
        line .. ": response")
    elseif c.kind == "BIDI" then
      local reqs = {}
      for i, m in ipairs(msgs) do reqs[i] = dynReq(model, m, 0) end
      local stream = client:bidi(SERVICE, "Bidi", reqs)
      local responses = stream:collect()
      util.check(#responses == #msgs, line .. ": got " .. #responses)
      for i, resp in ipairs(responses) do
        util.check(resp:getString(1) == msgs[i] and resp:getInt(2) == i - 1, line .. ": at " .. i)
      end
    else
      error("unknown scenario kind: " .. c.kind)
    end
  end
end

return {
  runScenarios = runScenarios,
  runDynamicScenarios = runDynamicScenarios,
}
