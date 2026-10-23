--- Browser test entry point (native runtime, server role):
--- runs the generated Lua Echo server over the real grpcdc
--- runtime on the worker DataChannel transport. The endpoint
--- pumps inline (single-threaded Lua), so this loop drives
--- dispatch. The JS client in the Node test drives the four
--- call shapes plus a deadline the slow handler must miss.
--- Mirrors wasm/swift/native/echo_server.swift.

local serverModule = require("grpcdc.server")
local stubs = require("examples.echo_grpc_dc")
local implModule = require("examples.echo_service_impl")
local dcModule = require("dc_transport")

-- Slow wrapper: busy-wait in Unary for delayMs so the JS
-- client's deadline fires (host_now() is seconds).
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

local function run()
  local server = serverModule.Server.new()
  stubs.registerEchoServer(server, setmetatable({}, SlowEcho))
  local endpoint = server:serveTransport(dcModule.DcTransport.new())
  -- pump() blocks briefly in the transport; the worker lives
  -- for the page's lifetime, so pump forever.
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
