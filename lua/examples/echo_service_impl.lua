local wire = require("grpcdc.wire")
local statusModule = require("grpcdc.status")
local messages = require("examples.echo_messages")

local Status = statusModule.Status
local EndOfStream = statusModule.EndOfStream
local EchoResponse = messages.EchoResponse

--- Reference Echo implementation (mirrors the other language demos):
--- "fail" is rejected, everything else echoes.
local EchoServiceImpl = {}

function EchoServiceImpl:unary(ctx, req)
  if req.message == "fail" then
    error(Status.new(wire.CODE_INVALID_ARGUMENT, "asked to fail"), 0)
  end
  if req.delayMs > 0 then
    -- Seconds clock: os.clock natively, host_now in the
    -- WASM host (which excludes loslib).
    local now = (type(host_now) == "function") and host_now or os.clock
    local deadline = now() + req.delayMs / 1000.0
    while now() < deadline do
    end
  end
  local marker = ctx.metadata["x-echo"]
  local suffix = (marker ~= nil and marker ~= "") and (" [" .. marker .. "]") or ""
  local trailerMarker = ctx.metadata["x-echo-trailer"]
  if trailerMarker ~= nil and trailerMarker ~= "" then
    ctx:setTrailers({ ["x-echo-trailer"] = trailerMarker })
  end
  return EchoResponse.new("echo: " .. req.message .. suffix, 0)
end

function EchoServiceImpl:serverStream(ctx, req, stream)
  if req.message == "fail" then
    error(Status.new(wire.CODE_INVALID_ARGUMENT, "asked to fail"), 0)
  end
  for i = 0, math.max(0, req.count) - 1 do
    stream:send(EchoResponse.new(req.message, i))
  end
end

function EchoServiceImpl:clientStream(ctx, stream)
  local parts = {}
  while true do
    local ok, req = pcall(function() return stream:recv() end)
    if not ok then
      if req == EndOfStream then break end
      error(req, 0)
    end
    if req.message == "fail" then
      error(Status.new(wire.CODE_INVALID_ARGUMENT, "asked to fail"), 0)
    end
    parts[#parts + 1] = req.message
  end
  stream:sendAndClose(EchoResponse.new(table.concat(parts, "+"), #parts))
end

function EchoServiceImpl:bidi(ctx, stream)
  local index = 0
  while true do
    local ok, req = pcall(function() return stream:recv() end)
    if not ok then
      if req == EndOfStream then return end
      error(req, 0)
    end
    if req.message == "fail" then
      error(Status.new(wire.CODE_INVALID_ARGUMENT, "asked to fail"), 0)
    end
    stream:send(EchoResponse.new(req.message, index))
    index = index + 1
  end
end

return EchoServiceImpl
