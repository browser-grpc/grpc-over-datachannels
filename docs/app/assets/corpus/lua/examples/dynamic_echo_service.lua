local wire = require("grpcdc.wire")
local statusModule = require("grpcdc.status")
local dynamic = require("grpcdc.dynamic")

local Status = statusModule.Status
local EndOfStream = statusModule.EndOfStream
local GenericMessage = dynamic.GenericMessage

--- Dynamic Echo implementation: the reference Echo semantics built
--- purely on the descriptor-driven runtime (no generated stubs).
--- Field numbers come from proto/echo.proto: EchoRequest{message=1,
--- count=2}, EchoResponse{message=1, index=2}.
local DynamicEchoService = {}

local function response(method, message, index)
  return GenericMessage.new(method.output):set(1, message):set(2, index)
end

function DynamicEchoService:unary(ctx, method, req)
  local message = req:getString(1)
  if message == "fail" then
    error(Status.new(wire.CODE_INVALID_ARGUMENT, "asked to fail"), 0)
  end
  local marker = ctx.metadata["x-echo"]
  local suffix = (marker ~= nil and marker ~= "") and (" [" .. marker .. "]") or ""
  return response(method, "echo: " .. message .. suffix, 0)
end

function DynamicEchoService:serverStream(ctx, method, req, send)
  local count = req:getInt(2)
  for i = 0, count - 1 do
    send(response(method, req:getString(1), i))
  end
end

function DynamicEchoService:clientStream(ctx, method, recv)
  local parts = {}
  while true do
    local ok, req = pcall(recv)
    if not ok then
      if req == EndOfStream then break end
      error(req, 0)
    end
    parts[#parts + 1] = req:getString(1)
  end
  return response(method, table.concat(parts, "+"), #parts)
end

function DynamicEchoService:bidi(ctx, method, recv, send)
  local index = 0
  while true do
    local ok, req = pcall(recv)
    if not ok then
      if req == EndOfStream then return end
      error(req, 0)
    end
    send(response(method, req:getString(1), index))
    index = index + 1
  end
end

return DynamicEchoService
