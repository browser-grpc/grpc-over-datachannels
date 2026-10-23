-- Host-provided TCP socket for the Lua sidecar test.
--
-- Generated Lua code is stdlib-only and pure Lua has no sockets,
-- so the host application supplies the socket implementation
-- (see grpcdc/sidecar_transport.lua for the contract:
-- sendAll / recvExact / close). This test harness is one such
-- host: it bridges TCP through two FIFOs and a small python3
-- helper process -- the same FIFO technique test_util uses for
-- process plumbing. An embedded host would instead bind its
-- platform sockets directly; the generated code cannot tell
-- the difference.
local util = require("test_util")

local M = {}

local HELPER = [[
import socket, sys, threading
mode, host, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
to_sock, from_sock = sys.argv[4], sys.argv[5]
fin = open(to_sock, "rb", buffering=0)
if mode == "connect":
    sock = socket.create_connection((host, port))
else:
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((host, port))
    srv.listen(1)
    sock, _ = srv.accept()
fout = open(from_sock, "wb", buffering=0)
def pump_in():
    try:
        while True:
            data = fin.read(65536)
            if not data:
                break
            sock.sendall(data)
    except OSError:
        pass
    try:
        sock.close()
    except OSError:
        pass
threading.Thread(target=pump_in, daemon=True).start()
try:
    while True:
        data = sock.recv(65536)
        if not data:
            break
        fout.write(data)
        fout.flush()
except OSError:
    pass
]]

local function spawn(mode, host, port)
  local dir = util.tmpdir()
  os.execute("mkfifo " .. dir .. "/to_sock " .. dir .. "/from_sock")
  local helperPath = dir .. "/host_tcp.py"
  local f = io.open(helperPath, "w")
  f:write(HELPER)
  f:close()
  local pid = util.spawnBackground(string.format(
    "python3 %s %s %s %d %s %s", helperPath, mode, host, port,
    dir .. "/to_sock", dir .. "/from_sock"))
  -- Open order: the helper opens the read end of to_sock first,
  -- so open the write end, then the read end of from_sock (the
  -- helper opens it after the TCP connection is established).
  local out = io.open(dir .. "/to_sock", "wb")
  if not out then return nil end
  local inp = io.open(dir .. "/from_sock", "rb")
  if not inp then
    out:close()
    return nil
  end
  local socket = { pid = pid, dir = dir, _in = inp, _out = out }

  function socket:sendAll(data)
    self._out:write(data)
    self._out:flush()
  end

  function socket:recvExact(n)
    local chunks = {}
    local got = 0
    while got < n do
      local chunk = self._in:read(n - got)
      if not chunk then return nil end
      chunks[#chunks + 1] = chunk
      got = got + #chunk
    end
    return table.concat(chunks)
  end

  function socket:close()
    pcall(function() self._out:close() end)
    pcall(function() self._in:close() end)
    util.kill(self.pid)
  end

  return socket
end

--- Host connector: connect(host, port) -> socket.
function M.connect(host, port)
  return spawn("connect", host, port)
end

--- Host acceptor: accept(port) -> socket (one connection).
function M.accept(port)
  return spawn("accept", "127.0.0.1", port)
end

return M
