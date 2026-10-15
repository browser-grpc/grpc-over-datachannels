local statusModule = require("grpcdc.status")

--- Frames DataChannel messages over a byte stream with a 4-byte
--- big-endian length prefix (the prefix exists only to frame messages
--- on a byte stream; each framed unit is exactly one DataChannel
--- message). Used by the cross-language interop harnesses over
--- stdin/stdout or FIFO/file handles.
---
--- Lua caveat: stdlib file reads are blocking, so recvMessage blocks
--- until a full framed message arrives (or EOF). That is exactly
--- what a dedicated harness process wants; in-process loopback uses
--- the memory transport instead.
local StdioTransport = {}
StdioTransport.__index = StdioTransport

--- input/output are Lua file handles (io.stdin/io.stdout or opened
--- FIFO files). onEof (optional) runs once when input reaches EOF.
function StdioTransport.new(input, output, onEof)
  input:setvbuf("no")
  output:setvbuf("no")
  return setmetatable({
    input = input,
    output = output,
    onEof = onEof,
    closedFlag = false,
    eof = false,
    endpoint = nil,
  }, StdioTransport)
end

local function readExact(file, n)
  local parts = {}
  local got = 0
  while got < n do
    local chunk = file:read(n - got)
    if chunk == nil or chunk == "" then
      return nil
    end
    parts[#parts + 1] = chunk
    got = got + #chunk
  end
  return table.concat(parts)
end

function StdioTransport:recvMessage()
  if self.eof then return nil end
  local header = readExact(self.input, 4)
  if header == nil then
    self.eof = true
    if self.onEof then self.onEof() end
    return nil
  end
  local len = string.unpack(">I4", header)
  if len == 0 then return "" end
  local body = readExact(self.input, len)
  if body == nil then
    self.eof = true
    if self.onEof then self.onEof() end
    return nil
  end
  return body
end

function StdioTransport:send(data)
  if self.closedFlag then
    error(statusModule.EndOfStream, 0)
  end
  self.output:write(string.pack(">I4", #data))
  self.output:write(data)
  self.output:flush()
end

function StdioTransport:close()
  self.closedFlag = true
end

return {
  StdioTransport = StdioTransport,
}
