-- Matrix tracing entry point (native Lua/Wasm runtime, server
-- role): the generated Echo server over the worker DataChannel
-- transport with a recording span observer; every span
-- start/end re-reports the cumulative spans via host_result so
-- the page can expose them to the matrix driver
-- (window.__spans) while the pump keeps running.

local serverModule = require("grpcdc.server")
local statusModule = require("grpcdc.status")
local stubs = require("examples.echo_grpc_dc")
local implModule = require("examples.echo_service_impl")
local dcModule = require("dc_transport")

-- Slow wrapper mirrors echo_server.lua: busy-wait in Unary
-- for delayMs so clients' deadlines fire.
local SlowEcho = {}
SlowEcho.__index = SlowEcho

local function delay(req)
  if req.delayMs ~= nil and req.delayMs > 0 then
    local deadline = host_now() + req.delayMs / 1000.0
    while host_now() < deadline do
    end
  end
end

function SlowEcho:unary(ctx, req)
  delay(req)
  return implModule:unary(ctx, req)
end

function SlowEcho:serverStream(ctx, req, stream)
  return implModule:serverStream(ctx, req, stream)
end

function SlowEcho:clientStream(ctx, stream)
  return implModule:clientStream(ctx, stream)
end

function SlowEcho:bidi(ctx, stream)
  return implModule:bidi(ctx, stream)
end

local starts = {}
local endKinds = {}

local function report()
  local startsJson = {}
  for i, s in ipairs(starts) do
    startsJson[i] = string.format("[%q,%q,%q,%q]",
      s.kind, s.traceId, s.spanId, s.parentSpanId)
  end
  local endsJson = {}
  for i, k in ipairs(endKinds) do
    endsJson[i] = string.format("%q", k)
  end
  host_result(string.format(
    '{"starts":[%s],"ends":[%s]}',
    table.concat(startsJson, ","), table.concat(endsJson, ",")))
end

local function run()
  statusModule.setTracer({
    onStart = function(kind, method, traceId, spanId, parentSpanId)
      starts[#starts + 1] = {
        kind = kind, traceId = traceId,
        spanId = spanId, parentSpanId = parentSpanId,
      }
      report()
    end,
    onEnd = function(kind, method, traceId, spanId, status, durationMs)
      endKinds[#endKinds + 1] = kind
      report()
    end,
  })
  local server = serverModule.Server.new()
  stubs.registerEchoServer(server, setmetatable({}, SlowEcho))
  local endpoint = server:serveTransport(dcModule.DcTransport.new())
  while true do
    endpoint:pump()
  end
end

local ok, result = pcall(run)
if not ok then
  if type(result) == "table" and result.code ~= nil then
    host_error(string.format("grpc status %s: %s", tostring(result.code), tostring(result.message)))
  else
    host_error(tostring(result))
  end
end
