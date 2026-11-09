-- Browser tracing entry point (native Lua/Wasm runtime):
-- runs a nested call chain entirely in the worker — client ->
-- front callee -> downstream service over memory transports —
-- with a recording span observer, and reports the spans as JSON
-- via host_result so the Playwright driver can assert the trace.

local channelModule = require("grpcdc.channel")
local serverModule = require("grpcdc.server")
local statusModule = require("grpcdc.status")
local memoryModule = require("grpcdc.memory_transport")
local stubs = require("examples.echo_grpc_dc")
local messages = require("examples.echo_messages")
local impl = require("examples.echo_service_impl")

local function req(message, count)
  return messages.EchoRequest.new(message, count)
end

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

  local a2, b2 = memoryModule.memoryTransportPair()
  local back = serverModule.Server.new()
  stubs.registerEchoServer(back, impl)
  back:serveTransport(b2)
  local downstreamChannel = channelModule.Channel.new(a2)

  local seenSpan = nil
  local frontImpl = {}
  for k, v in pairs(impl) do frontImpl[k] = v end
  frontImpl.unary = function(self, ctx, request)
    seenSpan = ctx.traceContext and ctx.traceContext.spanId or nil
    downstreamChannel:setTraceContext(ctx.traceContext)
    local downstream = stubs.EchoClient.new(downstreamChannel)
    return downstream:unary(req("nested", 0))
  end

  local a, b = memoryModule.memoryTransportPair()
  local front = serverModule.Server.new()
  stubs.registerEchoServer(front, frontImpl)
  front:serveTransport(b)
  local client = stubs.EchoClient.new(channelModule.Channel.new(a))

  local resp = client:unary(req("hello", 0))
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
    '{"message":%q,"seenSpan":%q,"starts":[%s],"ends":[%s]}',
    resp.message, seenSpan or "",
    table.concat(startsJson, ","), table.concat(endsJson, ","))
end

local ok, result = pcall(run)
if ok then
  host_result(result)
else
  host_error(tostring(result))
end
