-- Matrix tracing entry point (native Lua/Wasm runtime): one
-- traced unary over the real DataChannel transport; spans ride
-- back in the result JSON in the same shape the nested tracing
-- entry reports.

local channelModule = require("grpcdc.channel")
local statusModule = require("grpcdc.status")
local stubs = require("examples.echo_grpc_dc")
local messages = require("examples.echo_messages")
local dcModule = require("dc_transport")

local EchoRequest = messages.EchoRequest

local function run()
  local starts = {}
  local endKinds = {}
  statusModule.setTracer({
    onStart = function(kind, method, traceId, spanId, parentSpanId)
      starts[#starts + 1] = {
        kind = kind, traceId = traceId,
        spanId = spanId, parentSpanId = parentSpanId,
      }
    end,
    onEnd = function(kind, method, traceId, spanId, status, durationMs)
      endKinds[#endKinds + 1] = kind
    end,
  })

  local transport = dcModule.DcTransport.new()
  local channel = channelModule.Channel.new(transport)
  local client = stubs.EchoClient.new(channel)
  local resp = client:unary(EchoRequest.new("hello", 0))
  statusModule.setTracer(nil)

  local startsJson = {}
  for i, s in ipairs(starts) do
    startsJson[i] = string.format("[%q,%q,%q,%q]",
      s.kind, s.traceId, s.spanId, s.parentSpanId)
  end
  local endsJson = {}
  for i, k in ipairs(endKinds) do
    endsJson[i] = string.format("%q", k)
  end
  return string.format(
    '{"message":%q,"starts":[%s],"ends":[%s]}',
    resp.message,
    table.concat(startsJson, ","), table.concat(endsJson, ","))
end

local ok, result = pcall(run)
if ok then
  host_result(result)
elseif type(result) == "table" and result.code ~= nil then
  host_error(string.format("grpc status %s: %s", tostring(result.code), tostring(result.message)))
else
  host_error(tostring(result))
end
