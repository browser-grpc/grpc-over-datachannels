--- Native DataChannel transport for the browser/WASM build.
--- Runs in a Web Worker: dc_try_recv waits on the page's
--- SharedArrayBuffer mailbox, so blocking here is fine and
--- the endpoint's pump loops make progress exactly as with
--- the stdio transport.

local DcTransport = {}
DcTransport.__index = DcTransport

function DcTransport.new()
  return setmetatable({}, DcTransport)
end

function DcTransport:send(bytes)
  dc_send(bytes)
end

--- Blocks (in short host waits) until a message arrives;
--- nil exactly when the channel closes.
function DcTransport:recvMessage()
  while true do
    local msg, code = dc_try_recv(50)
    if msg ~= nil then return msg end
    if code == -2 then return nil end
  end
end

function DcTransport:close()
end

return { DcTransport = DcTransport }
