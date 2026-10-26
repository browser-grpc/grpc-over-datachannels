local channelModule = require("grpcdc.channel")
local statusModule = require("grpcdc.status")
local stubs = require("examples.test_grpc_dc")
local messages = require("examples.messages_messages")
local emptyMessages = require("examples.empty_messages")
local scenarios = require("interop_scenarios")
local util = require("test_util")

local Empty = emptyMessages.Empty
local Payload = messages.Payload
local PayloadType = messages.PayloadType
local SimpleRequest = messages.SimpleRequest
local EchoStatus = messages.EchoStatus
local StreamingInputCallRequest = messages.StreamingInputCallRequest
local StreamingOutputCallRequest = messages.StreamingOutputCallRequest
local ResponseParameters = messages.ResponseParameters
local EndOfStream = statusModule.EndOfStream

local INITIAL_KEY = "x-grpc-test-echo-initial"
local INITIAL_VAL = "test_initial_metadata_value"
local TRAILER_KEY = "x-grpc-test-echo-trailing-bin"
-- -bin values are base64 on the grpc-dc wire: "q83v" is base64
-- for the bytes AB CD EF the official case sends.
local TRAILER_VAL = "q83v"

local function payload(size)
  return Payload.new(PayloadType.COMPRESSABLE, string.rep("\0", size))
end

local function outReq(respSizes, status)
  local req = StreamingOutputCallRequest.new()
  local params = {}
  for i, s in ipairs(respSizes) do params[i] = ResponseParameters.new(s) end
  req.responseParameters = params
  if status ~= nil then req.responseStatus = status end
  return req
end

local function expectStatus(what, fn, code, message)
  local ok, err = pcall(fn)
  util.check(not ok, what .. ": expected status error")
  local st = statusModule.toStatus(err)
  util.check(st.code == code and (message == nil or st.message == message),
    what .. ": status " .. tostring(st.code) .. " " .. tostring(st.message))
end

local function recvAll(stream, what)
  local sizes = {}
  while true do
    local ok, resp = pcall(function() return stream:recv() end)
    if not ok then
      if resp == EndOfStream then break end
      error(resp, 0)
    end
    sizes[#sizes + 1] = #resp.payload.body
  end
  return sizes
end

local function checkSizes(what, got, want)
  util.check(#got == #want, what .. ": count " .. #got .. " ~= " .. #want)
  for i = 1, #want do
    util.check(got[i] == want[i], what .. ": size[" .. i .. "]")
  end
end

local function runCases(client, unimpl)
  for _, c in ipairs(scenarios.cases) do
    local what = "interop " .. c.name
    if c.kind == "EMPTY" then
      local ok, err = pcall(function() return client:emptyCall(Empty.new()) end)
      util.check(ok, what .. ": " .. tostring(err))
    elseif c.kind == "LARGE_UNARY" then
      local req = SimpleRequest.new()
      req.responseType = PayloadType.COMPRESSABLE
      req.responseSize = c.respSizes[1]
      req.payload = payload(c.reqSizes[1])
      local resp = client:unaryCall(req)
      util.check(#resp.payload.body == c.respSizes[1], what)
    elseif c.kind == "CLIENT_STREAMING" then
      local reqs = {}
      local want = 0
      for i, s in ipairs(c.reqSizes) do
        reqs[i] = StreamingInputCallRequest.new(payload(s))
        want = want + s
      end
      local resp = client:streamingInputCall(reqs)
      util.check(resp.aggregatedPayloadSize == want, what)
    elseif c.kind == "SERVER_STREAMING" then
      local stream = client:streamingOutputCall(outReq(c.respSizes))
      checkSizes(what, recvAll(stream, what), c.respSizes)
      stream:close()
    elseif c.kind == "PING_PONG" then
      local reqs = {}
      for i = 1, #c.reqSizes do
        reqs[i] = outReq({ c.respSizes[i] })
        reqs[i].payload = payload(c.reqSizes[i])
      end
      local stream = client:fullDuplexCall(reqs)
      checkSizes(what, recvAll(stream, what), c.respSizes)
      stream:close()
    elseif c.kind == "EMPTY_STREAM" then
      local stream = client:fullDuplexCall({})
      local ok, resp = pcall(function() return stream:recv() end)
      util.check(not ok and resp == EndOfStream, what)
      stream:close()
    elseif c.kind == "CUSTOM_METADATA" then
      local md = { [INITIAL_KEY] = INITIAL_VAL, [TRAILER_KEY] = TRAILER_VAL }
      local stream = client:fullDuplexCall({ outReq({ 314159 }) }, md)
      local resp = stream:recv()
      util.check(#resp.payload.body == 314159, what)
      local headers = stream:headers()
      util.check(headers ~= nil and headers[INITIAL_KEY] == INITIAL_VAL, what .. ": header")
      local ok, err = pcall(function() return stream:recv() end)
      util.check(not ok and err == EndOfStream, what .. ": eof")
      local trailers = stream:trailers()
      util.check(trailers ~= nil and trailers[TRAILER_KEY] == TRAILER_VAL, what .. ": trailer")
      stream:close()
    elseif c.kind == "STATUS_UNARY" then
      local req = SimpleRequest.new()
      req.responseStatus = EchoStatus.new(c.statusCode, c.statusMessage)
      expectStatus(what, function() return client:unaryCall(req) end,
        c.statusCode, c.statusMessage)
    elseif c.kind == "STATUS_DUPLEX" then
      local req = outReq({}, EchoStatus.new(c.statusCode, c.statusMessage))
      local stream = client:fullDuplexCall({ req })
      expectStatus(what, function() return stream:recv() end,
        c.statusCode, c.statusMessage)
      stream:close()
    elseif c.kind == "UNIMPLEMENTED_METHOD" then
      expectStatus(what, function() return client:unimplementedCall(Empty.new()) end,
        c.statusCode, nil)
    elseif c.kind == "UNIMPLEMENTED_SERVICE" then
      expectStatus(what, function() return unimpl:unimplementedCall(Empty.new()) end,
        c.statusCode, nil)
    else
      util.check(false, what .. ": unknown kind " .. c.kind)
    end
    print("interop case ok: " .. c.name)
  end
end

--- Interop client grading: the generated Lua TestService client
--- runs the canonical grpc interop cases (generated table:
--- interop_scenarios.lua) against the official grpc-go
--- TestServiceServer, through the bridge (dc-to-http2, stdio =
--- DataChannel). Skips when the Go server binary is not built
--- (Dockerfile.ci builds it).
local function testInteropOracle()
  local rootPath = util.root()
  local dir = util.tmpdir()
  local serverBin = rootPath .. "/oracle/go-interop/interop-server"
  if not util.fileExists(serverBin) then
    print("TestInteropOracle SKIP (go interop server not built)")
    return
  end
  local port = util.freePort()
  local server = util.spawnToFiles(
    string.format("%s -port %d", serverBin, port),
    dir .. "/server.out", dir .. "/server.err")
  -- The Go server logs nothing at startup: poll the TCP port.
  local ready = false
  for _ = 1, 300 do
    if server == nil then break end
    if os.execute(string.format(
        "python3 -c \"import socket; socket.create_connection(('127.0.0.1',%d),2).close()\" 2>/dev/null",
        port)) == true then
      ready = true
      break
    end
    util.sleep(0.1)
  end
  if not ready then
    util.kill(server)
    print("TestInteropOracle SKIP (interop server did not start)")
    return
  end
  local bridge = util.spawnPipe(string.format(
    "node %s/oracle/bridge.mjs dc-to-http2 --grpc 127.0.0.1:%d", rootPath, port))
  if bridge == nil then
    util.kill(server)
    print("TestInteropOracle SKIP (bridge did not start)")
    return
  end
  local ok, err = pcall(function()
    local channel = channelModule.Channel.new(bridge.transport)
    local client = stubs.TestServiceClient.new(channel)
    local unimpl = stubs.UnimplementedServiceClient.new(channel)
    runCases(client, unimpl)
  end)
  util.kill(bridge.pid)
  util.kill(server)
  if not ok then error(err, 0) end
  print("TestInteropOracle OK")
end

return testInteropOracle
