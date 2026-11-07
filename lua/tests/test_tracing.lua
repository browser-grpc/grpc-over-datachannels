-- Tracing: nested callee call joins the trace via the bound channel.

local channelModule = require("grpcdc.channel")
local serverModule = require("grpcdc.server")
local statusModule = require("grpcdc.status")
local memoryModule = require("grpcdc.memory_transport")
local util = require("test_util")
local stubs = require("examples.echo_grpc_dc")
local messages = require("examples.echo_messages")
local impl = require("examples.echo_service_impl")

local function req(message, count)
  return messages.EchoRequest.new(message, count)
end

local function testTracing()
  local starts = {}
  local endDurations = {}
  statusModule.setTracer({
    onStart = function(kind, method, traceId, spanId, parentSpanId)
      starts[#starts + 1] = {
        kind = kind, method = method, traceId = traceId,
        spanId = spanId, parentSpanId = parentSpanId,
      }
    end,
    onEnd = function(kind, method, traceId, spanId, status, durationMs)
      endDurations[#endDurations + 1] = durationMs
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
  util.check(resp.message == "echo: nested", "resp " .. tostring(resp.message))

  util.check(#starts == 4, "starts " .. #starts)
  util.check(starts[1].kind == "client" and starts[2].kind == "server"
    and starts[3].kind == "client" and starts[4].kind == "server", "kinds")
  for _, s in ipairs(starts) do
    util.check(s.traceId == starts[1].traceId, "trace ids")
  end
  util.check(starts[2].parentSpanId == starts[1].spanId, "server parent")
  util.check(starts[3].parentSpanId == starts[2].spanId, "inner client parent")
  util.check(starts[4].parentSpanId == starts[3].spanId, "inner server parent")
  util.check(seenSpan == starts[2].spanId, "ctx span")
  util.check(#endDurations == 4, "ends " .. #endDurations)
  for _, d in ipairs(endDurations) do
    util.check(d >= 0, "durations")
  end
  statusModule.setTracer(nil)
  print("TestTracing OK")
end

return testTracing
