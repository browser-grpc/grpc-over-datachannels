local channelModule = require("grpcdc.channel")
local serverModule = require("grpcdc.server")
local memoryModule = require("grpcdc.memory_transport")
local stdioModule = require("examples.stdio_transport")
local dynamic = require("grpcdc.dynamic")
local dynamicImpl = require("examples.dynamic_echo_service")
local runner = require("scenario_runner")
local util = require("test_util")

local function loadModel(rootPath)
  local path = rootPath .. "/fixtures/echo_descriptor_set.bin"
  local f = io.open(path, "rb")
  if not f then return nil end
  local data = f:read("a")
  f:close()
  return dynamic.parseDescriptorSet(data)
end

--- Dynamic (descriptor-driven) runtime: schemas consumed as data at
--- runtime, no generated stubs. Loopback plus the official grpc-java
--- oracle in both directions (the oracle is the runtime test bed).
local function testDynamic()
  local rootPath = util.root()
  local dir = util.tmpdir()
  local model = loadModel(rootPath)
  if model == nil then
    print("TestDynamic SKIP (descriptor fixture missing)")
    return
  end

  -- Generic codec + unknown-field retention round trip.
  local requestType = model:message(".echo.EchoRequest")
  local payload = string.char(0x0a, 0x02, 0x68, 0x69, 0x10, 0x02, 0x98, 0x06, 0x2a, 0xa2, 0x06, 0x01, 0x78)
  local decoded = dynamic.decodeGeneric(requestType, payload, model)
  util.check(#decoded.unknown == 2, "unknown retained: " .. #decoded.unknown)
  util.check(dynamic.encodeGeneric(requestType, decoded, model) == payload, "unknown round trip")

  -- Loopback: dynamic client against dynamic server.
  local a, b = memoryModule.memoryTransportPair()
  local loopbackServer = serverModule.Server.new()
  dynamic.registerDynamicService(loopbackServer, model, "echo.Echo", dynamicImpl)
  loopbackServer:serveTransport(b)
  runner.runDynamicScenarios(
    dynamic.DynamicClient.new(channelModule.Channel.new(a), model), model)

  local cp = util.javaClasspath(rootPath)
  if cp == nil then
    print("TestDynamic OK (loopback; oracle skipped)")
    return
  end

  -- Direction A: dynamic client -> bridge -> official server.
  local port = util.freePort()
  local serverCmd = string.format("java -cp %s dc.oracle.OracleServer %d", cp, port)
  local server = util.spawnToFiles(serverCmd, dir .. "/server.out", dir .. "/server.err")
  if server == nil or not util.waitReady(dir .. "/server.err", "READY", 60) then
    util.kill(server)
    print("TestDynamic SKIP (oracle server did not start)")
    return
  end
  local bridgeCmd = string.format("node %s/oracle/bridge.mjs dc-to-http2 --grpc 127.0.0.1:%d", rootPath, port)
  local bridge = util.spawnPipe(bridgeCmd)
  if bridge == nil then
    util.kill(server)
    print("TestDynamic SKIP (bridge did not start)")
    return
  end
  local okA, errA = pcall(function()
    runner.runDynamicScenarios(
      dynamic.DynamicClient.new(channelModule.Channel.new(bridge.transport), model), model)
  end)
  util.kill(bridge.pid)
  util.kill(server)
  if not okA then
    error(errA .. "\nbridge stderr:\n" .. util.readFile(bridge.dir .. "/stderr.txt"), 0)
  end

  -- Direction B: official client -> bridge -> dynamic server.
  local luaBin = os.getenv("LUA") or "lua"
  local serverBin = string.format("%s %s/lua/examples/dynamic_echo_server_stdio.lua", luaBin, rootPath)
  local portB = util.freePort()
  local bridgeBCmd = string.format(
    "node %s/oracle/bridge.mjs http2-to-dc --port %d --target-cmd %s",
    rootPath, portB, "'" .. serverBin .. "'")
  local bridgeB = util.spawnToFiles(bridgeBCmd, dir .. "/bridge.out", dir .. "/bridge.err")
  if bridgeB == nil or not util.waitReady(dir .. "/bridge.err", "listening", 60) then
    util.kill(bridgeB)
    print("TestDynamic SKIP (bridge did not start)")
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
  print("TestDynamic OK")
end

return testDynamic
