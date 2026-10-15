local pb = require("examples.pb")

--- Hand-written protobuf messages for proto/echo.proto (package echo).
---
--- Deliberately minimal (two messages) so the example needs no
--- protobuf codegen dependency — the wire bytes are genuine protobuf:
--- EchoRequest{message:"hi", count:2} encodes to 0a0268691002.
local EchoRequest = {}
EchoRequest.__index = EchoRequest

function EchoRequest.new(message, count, delayMs)
  return setmetatable({
    message = message or "",
    count = count or 0,
    delayMs = delayMs or 0,
  }, EchoRequest)
end

function EchoRequest:marshalDc()
  local w = pb.PbWriter.new()
  w:stringField(1, self.message)
  w:int32Field(2, self.count)
  w:int32Field(3, self.delayMs)
  return w:toBytes()
end

function EchoRequest:unmarshalDc(data)
  self.message = ""
  self.count = 0
  self.delayMs = 0
  local r = pb.PbReader.new(data)
  while true do
    local field = r:next()
    if field == nil then break end
    if field.number == 1 then
      self.message = field.bytesValue
    elseif field.number == 2 then
      self.count = pb.asInt32(field)
    elseif field.number == 3 then
      self.delayMs = pb.asInt32(field)
    end
    -- unknown fields skipped
  end
end

local EchoResponse = {}
EchoResponse.__index = EchoResponse

function EchoResponse.new(message, index)
  return setmetatable({ message = message or "", index = index or 0 }, EchoResponse)
end

function EchoResponse:marshalDc()
  local w = pb.PbWriter.new()
  w:stringField(1, self.message)
  w:int32Field(2, self.index)
  return w:toBytes()
end

function EchoResponse:unmarshalDc(data)
  self.message = ""
  self.index = 0
  local r = pb.PbReader.new(data)
  while true do
    local field = r:next()
    if field == nil then break end
    if field.number == 1 then
      self.message = field.bytesValue
    elseif field.number == 2 then
      self.index = pb.asInt32(field)
    end
  end
end

return {
  EchoRequest = EchoRequest,
  EchoResponse = EchoResponse,
}
