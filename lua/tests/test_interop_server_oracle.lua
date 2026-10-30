local util = require("test_util")

--- Interop oracle, Direction B: the OFFICIAL interop clients
--- (grpc-java TestServiceClient, grpc-go interop-client) run the
--- canonical cases against the generated Lua TestService server
--- (examples/interop_server_stdio.lua), reached over HTTP/2
--- through oracle/bridge.mjs http2-to-dc. Skips when an oracle
--- binary or Node is unavailable. Mirrors
--- java/tests/TestInteropServerOracle.java. Process plumbing
--- uses output files (see test_util): Lua stdlib cannot read a
--- child exit code, so the Java client is graded on its
--- "Test completed." marker and the Go client on the absence of
--- its FATAL failure line.
local CASES = {
  "empty_unary",
  "large_unary",
  "client_streaming",
  "server_streaming",
  "ping_pong",
  "empty_stream",
  "custom_metadata",
  "status_code_and_message",
  "special_status_message",
  "unimplemented_method",
  "unimplemented_service",
  "cancel_after_begin",
  "cancel_after_first_response",
  "timeout_on_sleeping_server",
}

local JAVA_ONLY = {
  "cacheable_unary",
  "client_compressed_unary",
  "client_compressed_streaming",
  "server_compressed_unary",
  "server_compressed_streaming",
}

-- orca_oob is excluded: the case holds a FullDuplexCall open
-- while relying on the load balancer's concurrent OOB watch
-- stream, but the Lua runtime is single-threaded and cooperative
-- over a blocking stdio transport, so the concurrent streams
-- starve each other and the duplex call hits its deadline. The
-- generated C harness skips the ORCA cases for the same reason.
-- orca_per_rpc only needs the per-RPC trailer and stays in.
local GO_ONLY = { "orca_per_rpc" }

local function runClient(dir, tag, cmd, marker)
  local pid = util.spawnToFiles(cmd, dir .. "/" .. tag .. ".out", dir .. "/" .. tag .. ".err")
  util.check(pid ~= nil, "client spawn: " .. tag)
  local exited = util.waitPid(pid, 120)
  util.check(exited, "client did not exit: " .. tag)
  local output = util.readFile(dir .. "/" .. tag .. ".out")
    .. util.readFile(dir .. "/" .. tag .. ".err")
  if marker ~= nil then
    util.check(output:find(marker, 1, true) ~= nil,
      "client output for " .. tag .. ":\n" .. output)
  else
    util.check(output:find("FATAL", 1, true) == nil,
      "client output for " .. tag .. ":\n" .. output)
  end
end

local function testInteropServerOracle()
  local rootPath = util.root()
  local dir = util.tmpdir()
  local cp = util.javaClasspath(rootPath)
  if cp == nil then
    print("TestInteropServerOracle SKIP (java oracle not built)")
    return
  end
  local luaBin = os.getenv("LUA") or "lua"
  local serverBin = string.format("%s %s/lua/examples/interop_server_stdio.lua", luaBin, rootPath)
  local port = util.freePort()
  local bridgeCmd = string.format(
    "node %s/oracle/bridge.mjs http2-to-dc --port %d --target-cmd '%s'",
    rootPath, port, serverBin)
  local bridge = util.spawnToFiles(bridgeCmd, dir .. "/bridge.out", dir .. "/bridge.err")
  if bridge == nil or not util.waitReady(dir .. "/bridge.err", "listening", 60) then
    util.kill(bridge)
    print("TestInteropServerOracle SKIP (bridge did not start)")
    return
  end
  local ok, err = pcall(function()
    for _, cases in ipairs({ CASES, JAVA_ONLY }) do
      for _, testCase in ipairs(cases) do
        local cmd = string.format(
          "java -cp %s io.grpc.testing.integration.TestServiceClient --server_host=127.0.0.1 --server_port=%d --test_case=%s --use_tls=false",
          cp, port, testCase)
        runClient(dir, "java_" .. testCase, cmd, "Test completed.")
        print("interop B case ok: " .. testCase .. " (java client)")
      end
    end
    local goClient = rootPath .. "/oracle/go-interop/interop-client"
    if os.execute("test -f " .. goClient) ~= true then
      print("TestInteropServerOracle GO SKIP (go client not built)")
    else
      for _, cases in ipairs({ CASES, GO_ONLY }) do
        for _, testCase in ipairs(cases) do
          local cmd = string.format(
            "%s -server_host 127.0.0.1 -server_port %d -test_case %s",
            goClient, port, testCase)
          if testCase:sub(1, 4) == "orca" then
            cmd = cmd .. " -service_config_json '{ \"loadBalancingConfig\": [{ \"test_backend_metrics_load_balancer\": {} }]}'"
          end
          runClient(dir, "go_" .. testCase, cmd, nil)
          print("interop B case ok: " .. testCase .. " (go client)")
        end
      end
      print("interop B case SKIP: orca_oob (go client; generated Lua server is single-threaded/cooperative, ORCA OOB needs concurrent streams)")
    end
  end)
  util.kill(bridge)
  if not ok then error(err, 0) end
  print("TestInteropServerOracle OK")
end

return testInteropServerOracle
