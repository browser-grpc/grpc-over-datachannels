local channelModule = require("grpcdc.channel")
local stubs = require("examples.echo_grpc_dc")
local runner = require("scenario_runner")
local util = require("test_util")

--- Oracle: official grpc-java, bridged over TCP<->DataChannel by
--- oracle/bridge.mjs, must agree with the Lua runtime on every case
--- of the generated scenario driver. Skips when the Java oracle or
--- Node bridge are unavailable (Dockerfile.ci provides both).
--- Process plumbing uses FIFO spawns (see test_util).
local function testOracle()
  local rootPath = util.root()
  local dir = util.tmpdir()
  local cp = util.javaClasspath(rootPath)
  if cp == nil then
    print("TestOracle SKIP (java oracle not built)")
    return
  end

  -- Direction A: this client -> bridge -> official server.
  local port = util.freePort()
  local serverCmd = string.format("java -cp %s dc.oracle.OracleServer %d", cp, port)
  local server = util.spawnToFiles(serverCmd, dir .. "/server.out", dir .. "/server.err")
  if server == nil or not util.waitReady(dir .. "/server.err", "READY", 60) then
    util.kill(server)
    print("TestOracle SKIP (oracle server did not start)")
    return
  end
  local bridgeCmd = string.format("node %s/oracle/bridge.mjs dc-to-http2 --grpc 127.0.0.1:%d", rootPath, port)
  local bridge = util.spawnPipe(bridgeCmd)
  if bridge == nil then
    util.kill(server)
    print("TestOracle SKIP (bridge did not start)")
    return
  end
  local okA, errA = pcall(function()
    local client = stubs.EchoClient.new(channelModule.Channel.new(bridge.transport))
    runner.runScenarios(client)
  end)
  util.kill(bridge.pid)
  util.kill(server)
  if not okA then
    error(errA .. "\nbridge stderr:\n" .. util.readFile(bridge.dir .. "/stderr.txt"), 0)
  end

  -- Direction B: official client -> bridge -> this runtime's server.
  local luaBin = os.getenv("LUA") or "lua"
  local serverBin = string.format("%s %s/lua/examples/echo_server_stdio.lua", luaBin, rootPath)
  local portB = util.freePort()
  local bridgeBCmd = string.format(
    "node %s/oracle/bridge.mjs http2-to-dc --port %d --target-cmd '%s'",
    rootPath, portB, serverBin)
  local bridgeB = util.spawnToFiles(bridgeBCmd, dir .. "/bridge.out", dir .. "/bridge.err")
  if bridgeB == nil or not util.waitReady(dir .. "/bridge.err", "listening", 60) then
    util.kill(bridgeB)
    print("TestOracle SKIP (bridge did not start)")
    return
  end
  local clientCmd = string.format("java -cp %s dc.oracle.OracleClient %d %s/fixtures/oracle_scenarios.txt",
    cp, portB, rootPath)
  local client = util.spawnToFiles(clientCmd, dir .. "/client.out", dir .. "/client.err")
  local exited = client ~= nil and util.waitPid(client, 120)
  util.kill(bridgeB)
  util.check(exited, "oracle client did not exit")
  local output = util.readFile(dir .. "/client.out") .. util.readFile(dir .. "/client.err")
  util.check(output:find("ORACLE CLIENT: ALL OK", 1, true) ~= nil,
    "oracle client output:\n" .. output)
  print("TestOracle OK")
end

return testOracle
