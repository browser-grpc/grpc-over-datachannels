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

local function run()
  local transport = dcModule.DcTransport.new()
  local client = stubs.EchoClient.new(channelModule.Channel.new(transport))

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

  local tickJson = {}
  for i, t in ipairs(ticks) do tickJson[i] = tostring(t) end
  local echoJson = {}
  for i, m in ipairs(echoed) do echoJson[i] = string.format("%q", m) end
  return string.format(
    '{"unary":%s,"ticks":[%s],"joined":%s,"echoed":[%s]}',
    string.format("%q", unary.message),
    table.concat(tickJson, ","),
    string.format("%q", joined.message),
    table.concat(echoJson, ","))
end

local ok, result = pcall(run)
if ok then
  host_result(result)
elseif type(result) == "table" and result.code ~= nil then
  host_error(string.format("grpc status %s: %s", tostring(result.code), tostring(result.message)))
else
  host_error(tostring(result))
end
