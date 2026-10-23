local channelModule = require("grpcdc.channel")
local statusModule = require("grpcdc.status")
local stubs = require("examples.echo_grpc_dc")
local messages = require("examples.echo_messages")
local util = require("test_util")

local EchoRequest = messages.EchoRequest
local EndOfStream = statusModule.EndOfStream

local function req(message, count)
  return EchoRequest.new(message, count)
end

local function buildGo(rootPath, output, pkg)
  local cmd = string.format("cd %s/go && go build -o %s %s", rootPath, output, pkg)
  return os.execute(cmd) == true
end

--- Interop: the Lua runtime against the Go stdio harnesses (cross-
--- language wire compatibility). Skips when Go is unavailable.
local function testInterop()
  local rootPath = util.root()
  local dir = util.tmpdir()
  local serverBin = dir .. "/echo_server_stdio"
  if not buildGo(rootPath, serverBin, "./examples/echo_server_stdio") then
    print("TestInterop SKIP (no go)")
    return
  end

  local server = util.spawnPipe(serverBin)
  util.check(server ~= nil, "go server did not start")
  local ok, err = pcall(function()
    local client = stubs.EchoClient.new(channelModule.Channel.new(server.transport))

    local unary = client:unary(req("hello", 0))
    util.check(unary.message == "echo: hello", "unary: " .. unary.message)

    local stream = client:serverStream(req("tick", 3))
    local indexes = {}
    while true do
      local okR, resp = pcall(function() return stream:recv() end)
      if not okR then
        if resp == EndOfStream then break end
        error(resp, 0)
      end
      indexes[#indexes + 1] = resp.index
    end
    util.check(#indexes == 3 and indexes[1] == 0 and indexes[2] == 1 and indexes[3] == 2,
      "server stream")

    local joined = client:clientStream({ req("a", 0), req("b", 0), req("c", 0) })
    util.check(joined.message == "a+b+c", "client stream: " .. joined.message)

    local bidi = client:bidi({ req("x", 0), req("y", 0) })
    local echoed = {}
    while true do
      local okR, resp = pcall(function() return bidi:recv() end)
      if not okR then
        if resp == EndOfStream then break end
        error(resp, 0)
      end
      echoed[#echoed + 1] = resp.message
    end
    util.check(#echoed == 2 and echoed[1] == "x" and echoed[2] == "y", "bidi")

    local okF, errF = pcall(function() return client:unary(req("fail", 0)) end)
    util.check(not okF, "fail should raise")
    util.check(type(errF) == "table" and errF.code == 3, "fail status: " .. tostring(errF))
  end)
  util.kill(server.pid)
  if not ok then error(err, 0) end

  -- Reverse: Go client harness against the Lua stdio server, wired
  -- directly FIFO-to-FIFO by the shell (no test-process pumping).
  local clientBin = dir .. "/echo_client_stdio"
  if not buildGo(rootPath, clientBin, "./examples/echo_client_stdio") then
    print("TestInterop partial SKIP (client build)")
    return
  end
  local luaBin = os.getenv("LUA") or "lua"
  local fifoDir = util.tmpdir()
  os.execute("mkfifo " .. fifoDir .. "/to_server " .. fifoDir .. "/to_client")
  local serverCmd = string.format("%s %s/lua/examples/echo_server_stdio.lua < %s > %s 2> %s",
    luaBin, rootPath, fifoDir .. "/to_server", fifoDir .. "/to_client", fifoDir .. "/server.err")
  local clientCmd = string.format("%s < %s > %s 2> %s",
    clientBin, fifoDir .. "/to_client", fifoDir .. "/to_server", fifoDir .. "/client.err")
  -- Hold RDWR keeper handles on both FIFOs: opening a FIFO with
  -- "r+b" never blocks and gives each shell redirect a peer, so the
  -- two children cannot deadlock opening their stdin/stdout FIFOs
  -- in opposite orders.
  local keeperA = io.open(fifoDir .. "/to_server", "r+b")
  local keeperB = io.open(fifoDir .. "/to_client", "r+b")
  local luaServer = util.spawnBackground(serverCmd)
  local goClient = util.spawnBackground(clientCmd)
  util.check(goClient ~= nil, "go client did not start")
  local exited = util.waitPid(goClient, 60)
  util.kill(luaServer)
  util.kill(goClient)
  if keeperA then keeperA:close() end
  if keeperB then keeperB:close() end
  util.check(exited, "go client harness did not exit")
  local errText = util.readFile(fifoDir .. "/client.err")
  util.check(errText:find("unary=echo: hello", 1, true) ~= nil, "go client unary: " .. errText)
  util.check(errText:find("server_stream=tick#0,tick#1,tick#2", 1, true) ~= nil,
    "go client stream: " .. errText)
  util.check(errText:find("client_stream=a+b+c", 1, true) ~= nil, "go client client-stream: " .. errText)
  util.check(errText:find("bidi=x,y", 1, true) ~= nil, "go client bidi: " .. errText)
  print("TestInterop OK")
end

return testInterop
