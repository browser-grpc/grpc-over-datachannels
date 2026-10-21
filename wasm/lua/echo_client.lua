--- Browser test entry point (native runtime): the four Echo
--- call shapes with the real generated Lua client over the
--- worker DataChannel transport. Mirrors echo_client_stdio,
--- reporting one JSON object via host_result.

local channelModule = require("grpcdc.channel")
local stubs = require("examples.echo_grpc_dc")
local messages = require("examples.echo_messages")
local dcModule = require("dc_transport")
local EndOfStream = require("grpcdc.status").EndOfStream

local EchoRequest = messages.EchoRequest

local function req(message, count)
  return EchoRequest.new(message, count)
end

local function codeOf(fn)
  local ok, err = pcall(fn)
  if ok then return 0 end
  if type(err) == "table" and err.code ~= nil then return err.code end
  error(err)
end

local function run()
  local transport = dcModule.DcTransport.new()
  local channel = channelModule.Channel.new(transport)
  local client = stubs.EchoClient.new(channel)

  local unary = client:unary(req("hello", 0))

  local stream = client:serverStream(req("tick", 3))
  local ticks = {}
  while true do
    local ok, resp = pcall(function() return stream:recv() end)
    if not ok then
      if resp == EndOfStream then break end
      error(resp)
    end
    ticks[#ticks + 1] = resp.index
  end

  local joined = client:clientStream({ req("a", 0), req("b", 0) })

  local bidi = client:bidi({ req("x", 0), req("y", 0) })
  local echoed = {}
  while true do
    local ok, resp = pcall(function() return bidi:recv() end)
    if not ok then
      if resp == EndOfStream then break end
      error(resp)
    end
    echoed[#echoed + 1] = resp.message
  end

  -- BDD deepening: failure, metadata, unknown-method, cancel,
  -- and deadline scenarios executed by this module.
  local unaryFailureCode = codeOf(function() return client:unary(req("fail", 0)) end)
  local metadataResp = client:unary(req("hello", 0), { ["x-echo"] = "meta" })
  local serverStreamFailureCode = codeOf(function()
    local s = client:serverStream(req("fail", 3))
    while true do s:recv() end
  end)
  local bidiFailureCode = codeOf(function()
    local s = client:bidi({ req("fail", 0) })
    while true do s:recv() end
  end)
  local unknownMethodCode = codeOf(function()
    local r = messages.EchoResponse.new()
    channel:unary("/echo.Echo/Nope", req("hello", 0), r)
    return r
  end)
  local cancelTerminated = false
  do
    local stream = channel:serverStream("/echo.Echo/ServerStream", req("tick", 5))
    local first = messages.EchoResponse.new()
    stream:recv(first)
    stream.endpoint:cancelStream(stream.streamId)
    for _ = 1, 7 do
      local ok = pcall(function()
        local r = messages.EchoResponse.new()
        stream:recv(r)
        return r
      end)
      if not ok then
        cancelTerminated = true
        break
      end
    end
  end
  local deadlineCode = codeOf(function()
    return client:unary(EchoRequest.new("slow", 0, 600), nil, 0.1)
  end)

  local tickJson = {}
  for i, t in ipairs(ticks) do tickJson[i] = tostring(t) end
  local echoJson = {}
  for i, m in ipairs(echoed) do echoJson[i] = string.format("%q", m) end
  return string.format(
    '{"unary":%s,"ticks":[%s],"joined":%s,"echoed":[%s],'
      .. '"unaryFailureCode":%d,"metadataMessage":%s,'
      .. '"serverStreamFailureCode":%d,"bidiFailureCode":%d,'
      .. '"unknownMethodCode":%d,"cancelTerminated":%s,"deadlineCode":%d}',
    string.format("%q", unary.message),
    table.concat(tickJson, ","),
    string.format("%q", joined.message),
    table.concat(echoJson, ","),
    unaryFailureCode,
    string.format("%q", metadataResp.message),
    serverStreamFailureCode,
    bidiFailureCode,
    unknownMethodCode,
    cancelTerminated and "true" or "false",
    deadlineCode)
end

local ok, result = pcall(run)
if ok then
  host_result(result)
elseif type(result) == "table" and result.code ~= nil then
  host_error(string.format("grpc status %s: %s", tostring(result.code), tostring(result.message)))
else
  host_error(tostring(result))
end
