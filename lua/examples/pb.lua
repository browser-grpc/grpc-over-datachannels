--- Minimal protobuf wire writer/reader for the hand-written messages.
local PbWriter = {}
PbWriter.__index = PbWriter

function PbWriter.new()
  return setmetatable({ parts = {} }, PbWriter)
end

function PbWriter:varint(value)
  local v = value
  if v < 0 then
    -- Negative int32/int64: canonical 10-byte two's-complement form.
    for _ = 1, 9 do
      self.parts[#self.parts + 1] = string.char((v & 0x7f) | 0x80)
      v = v >> 7
    end
    self.parts[#self.parts + 1] = string.char(v & 0x7f)
    return
  end
  while (v & ~0x7f) ~= 0 do
    self.parts[#self.parts + 1] = string.char((v & 0x7f) | 0x80)
    v = v >> 7
  end
  self.parts[#self.parts + 1] = string.char(v & 0xff)
end

function PbWriter:stringField(field, value)
  if value == "" then return end
  self:varint((field << 3) | 2)
  self:varint(#value)
  self.parts[#self.parts + 1] = value
end

function PbWriter:int32Field(field, value)
  if value == 0 then return end
  self:varint((field << 3) | 0)
  self:varint(value)
end

function PbWriter:toBytes()
  return table.concat(self.parts)
end

local PbReader = {}
PbReader.__index = PbReader

function PbReader.new(buf)
  return setmetatable({ buf = buf, pos = 1 }, PbReader)
end

function PbReader:varint()
  local result = 0
  local shift = 0
  while true do
    if self.pos > #self.buf then error("truncated varint") end
    local b = self.buf:byte(self.pos)
    self.pos = self.pos + 1
    result = result | ((b & 0x7f) << shift)
    if (b & 0x80) == 0 then return result end
    shift = shift + 7
    if shift >= 70 then error("varint too long") end
  end
end

--- Next field {number, varintValue, bytesValue}, or nil at end.
function PbReader:next()
  if self.pos > #self.buf then return nil end
  local tag = self:varint()
  local number = tag >> 3
  local wireType = tag & 7
  if wireType == 0 then
    return { number = number, varintValue = self:varint(), bytesValue = "" }
  elseif wireType == 2 then
    local n = self:varint()
    if self.pos + n - 1 > #self.buf then error("truncated bytes field") end
    local bytes = self.buf:sub(self.pos, self.pos + n - 1)
    self.pos = self.pos + n
    return { number = number, varintValue = 0, bytesValue = bytes }
  elseif wireType == 1 then
    if self.pos + 7 > #self.buf then error("truncated fixed64") end
    local bytes = self.buf:sub(self.pos, self.pos + 7)
    self.pos = self.pos + 8
    return { number = number, varintValue = 0, bytesValue = bytes }
  elseif wireType == 5 then
    if self.pos + 3 > #self.buf then error("truncated fixed32") end
    local bytes = self.buf:sub(self.pos, self.pos + 3)
    self.pos = self.pos + 4
    return { number = number, varintValue = 0, bytesValue = bytes }
  end
  error("bad wire type")
end

local function asInt32(field)
  local v = field.varintValue & 0xffffffff
  if v >= 0x80000000 then v = v - 0x100000000 end
  return v
end

return {
  PbWriter = PbWriter,
  PbReader = PbReader,
  asInt32 = asInt32,
}
