local stdioModule = require("examples.stdio_transport")

local M = {}

function M.check(cond, what)
  if not cond then
    error("check failed: " .. tostring(what), 0)
  end
end

function M.fromHex(hex)
  return (hex:gsub("%x%x", function(cc)
    return string.char(tonumber(cc, 16))
  end))
end

function M.toHex(bytes)
  return (bytes:gsub(".", function(c)
    return string.format("%02x", c:byte())
  end))
end

function M.fileExists(path)
  local f = io.open(path, "rb")
  if f then
    f:close()
    return true
  end
  return false
end

--- Repository root, located by walking up from the cwd looking for
--- fixtures/echo_descriptor_set.bin.
function M.root()
  local env = os.getenv("GRPC_DC_ROOT")
  if env ~= nil and env ~= "" then return env end
  local prefix = "."
  for _ = 1, 8 do
    if M.fileExists(prefix .. "/fixtures/echo_descriptor_set.bin") then
      return prefix
    end
    if M.fileExists(prefix .. "/grpc-over-datachannels/fixtures/echo_descriptor_set.bin") then
      return prefix .. "/grpc-over-datachannels"
    end
    prefix = prefix .. "/.."
  end
  return "."
end

function M.javaClasspath(rootPath)
  local cpFile = io.open(rootPath .. "/oracle/java/target/cp.txt", "r")
  if not cpFile then return nil end
  local cp = cpFile:read("a")
  cpFile:close()
  if not M.fileExists(rootPath .. "/oracle/java/target/classes") then
    -- io.open cannot probe directories portably; use test(1).
    if os.execute("test -d " .. rootPath .. "/oracle/java/target/classes") ~= true then
      return nil
    end
  end
  cp = cp:gsub("%s+$", "")
  return rootPath .. "/oracle/java/target/classes:" .. cp
end

--- Free TCP port (stdlib has no sockets; CI provides python3).
function M.freePort()
  local p = io.popen("python3 -c 'import socket; s=socket.socket(); s.bind((\"127.0.0.1\",0)); print(s.getsockname()[1]); s.close()'", "r")
  if not p then return 0 end
  local line = p:read("l")
  p:close()
  return tonumber(line) or 0
end

function M.sleep(seconds)
  os.execute("sleep " .. tostring(seconds))
end

function M.readFile(path)
  local f = io.open(path, "rb")
  if not f then return "" end
  local data = f:read("a")
  f:close()
  return data or ""
end

function M.tmpdir()
  local p = io.popen("mktemp -d /tmp/grpcdc_lua_XXXXXX", "r")
  local dir = p:read("l")
  p:close()
  return dir
end

--- Spawn a command with FIFO pipes for stdin/stdout (pure stdlib
--- gives no bidirectional popen, so tests use named FIFOs — the
--- documented Lua process caveat). Returns {pid, transport, dir} or
--- nil. stderr goes to <dir>/stderr.txt.
function M.spawnPipe(command)
  local dir = M.tmpdir()
  os.execute("mkfifo " .. dir .. "/in " .. dir .. "/out")
  local launcher = io.popen(string.format(
    "%s < %s > %s 2> %s; echo started", command, dir .. "/in", dir .. "/out", dir .. "/stderr.txt & echo $!"), "r")
  if not launcher then return nil end
  local pid = tonumber(launcher:read("l"))
  launcher:close()
  if pid == nil then return nil end
  -- Open order matters: the shell child opens its stdin redirect
  -- first (blocking until a writer appears), so the test opens the
  -- write end first, then the read end.
  local input = io.open(dir .. "/in", "wb")
  if not input then return nil end
  local output = io.open(dir .. "/out", "rb")
  if not output then
    input:close()
    return nil
  end
  if os.execute("kill -0 " .. pid .. " 2>/dev/null") ~= true then
    input:close()
    output:close()
    return nil
  end
  local transport = stdioModule.StdioTransport.new(output, input)
  return { pid = pid, transport = transport, dir = dir }
end

--- Spawn a command with stdout/stderr redirected to files; returns
--- pid or nil. Used when the test only needs the output afterwards.
function M.spawnToFiles(command, outPath, errPath)
  local launcher = io.popen(string.format(
    "%s > %s 2> %s & echo $!", command, outPath, errPath), "r")
  if not launcher then return nil end
  local pid = tonumber(launcher:read("l"))
  launcher:close()
  return pid
end

--- Spawn a command in the background exactly as written (the
--- command carries its own redirections); returns pid or nil.
function M.spawnBackground(command)
  local launcher = io.popen(command .. " & echo $!", "r")
  if not launcher then return nil end
  local pid = tonumber(launcher:read("l"))
  launcher:close()
  return pid
end

--- Wait until a file contains needle (timeout in seconds).
function M.waitReady(path, needle, timeoutSec)
  local waited = 0
  while waited < timeoutSec do
    if M.readFile(path):find(needle, 1, true) then return true end
    M.sleep(0.05)
    waited = waited + 0.05
  end
  return M.readFile(path):find(needle, 1, true) ~= nil
end

--- Wait for pid exit (timeout seconds); returns true when it exited.
--- Exit status is not available through stdlib, so harnesses signal
--- success via their output (checked by callers).
function M.waitPid(pid, timeoutSec)
  local waited = 0
  while waited < timeoutSec do
    if os.execute("kill -0 " .. pid .. " 2>/dev/null") ~= true then
      return true
    end
    M.sleep(0.05)
    waited = waited + 0.05
  end
  return false
end

function M.kill(pid)
  if pid then os.execute("kill -9 " .. pid .. " 2>/dev/null") end
end

return M
