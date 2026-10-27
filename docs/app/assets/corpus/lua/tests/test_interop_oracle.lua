local channelModule = require("grpcdc.channel")
local statusModule = require("grpcdc.status")
local stubs = require("examples.test_grpc_dc")
local messages = require("examples.messages_messages")
local emptyMessages = require("examples.empty_messages")
local scenarios = require("interop_scenarios")
local orcaStubs = require("examples.orca_grpc_dc")
local orcaMessages = require("examples.orca_messages")
local orcaReportMessages = require("examples.orca_load_report_messages")
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

local function runCases(channel, client, unimpl)
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
    elseif c.kind == "SPECIAL_STATUS" then
      local req = SimpleRequest.new()
      req.responseStatus = EchoStatus.new(c.statusCode, c.statusMessage)
      expectStatus(what, function() return client:unaryCall(req) end,
        c.statusCode, c.statusMessage)
    elseif c.kind == "CANCEL_AFTER_BEGIN" then
      -- Begin a client-streaming call and cancel it before
      -- sending any request: the pending recv must report
      -- CANCELLED.
      local stream = channel:open("/grpc.testing.TestService/StreamingInputCall")
      stream:cancel()
      expectStatus(what, function()
        return stream:recv(messages.StreamingInputCallResponse.new())
      end, c.statusCode, nil)
    elseif c.kind == "CANCEL_AFTER_FIRST" then
      -- Duplex call (no half-close): the server answers the one
      -- request, then waits for more input, so the cancel
      -- deterministically lands mid-call (same shape as the
      -- Python/JS suites).
      local stream = channel:open("/grpc.testing.TestService/FullDuplexCall")
      channel:sendMessage(stream, outReq({ c.respSizes[1] }))
      local resp = messages.StreamingOutputCallResponse.new()
      stream:recv(resp)
      util.check(#resp.payload.body == c.respSizes[1], what)
      stream:cancel()
      expectStatus(what, function()
        return stream:recv(messages.StreamingOutputCallResponse.new())
      end, c.statusCode, nil)
    elseif c.kind == "TIMEOUT_SLEEPING" then
      local req = StreamingOutputCallRequest.new()
      local params = {}
      for i, s in ipairs(c.respSizes) do params[i] = ResponseParameters.new(s, 1000000) end
      req.responseParameters = params
      req.payload = payload(0)
      expectStatus(what, function()
        -- Native Lua clock resolution is one second: use a 2 s
        -- deadline against the server's 1 s response intervals.
        local stream = client:streamingOutputCall(req, nil, 2)
        while true do stream:recv() end
      end, c.statusCode, nil)
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

-- Base64 decode (pure Lua; the runtime carries no base64 helper).
local B64 = {}
for i, ch in ipairs({
  "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M",
  "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z",
  "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m",
  "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z",
  "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "+", "/",
}) do B64[ch] = i - 1 end

local function b64decode(text)
  -- Decode four sextets at a time: a single accumulator would
  -- lose low bits to double rounding on longer inputs.
  local clean = {}
  for i = 1, #text do
    local ch = text:sub(i, i)
    if ch == "=" then break end
    if B64[ch] ~= nil then clean[#clean + 1] = B64[ch] end
  end
  local out = {}
  for i = 1, #clean, 4 do
    local a, b, c, d = clean[i], clean[i + 1], clean[i + 2], clean[i + 3]
    local n = a * 262144 + b * 4096 + (c or 0) * 64 + (d or 0)
    out[#out + 1] = string.char(math.floor(n / 65536) % 256)
    if c ~= nil then out[#out + 1] = string.char(math.floor(n / 256) % 256) end
    if d ~= nil then out[#out + 1] = string.char(n % 256) end
  end
  return table.concat(out)
end

-- Compression rows (upstream client_compressed_unary,
-- client_compressed_streaming, server_compressed_unary,
-- server_compressed_streaming): the DataChannel wire is
-- compression-free; the client declares grpc-encoding: gzip
-- and the bridge gzips request messages on the HTTP/2 hop,
-- decompressing responses the same way.
local function runCompressionCases(client)
  local gzip = { ["grpc-encoding"] = "gzip" }
  do
    local req = SimpleRequest.new()
    req.responseSize = 31415
    req.payload = payload(271828)
    req.expectCompressed = messages.BoolValue.new(true)
    local resp = client:unaryCall(req, gzip)
    util.check(#resp.payload.body == 31415, "client_compressed_unary: body")
    print("interop case ok: client_compressed_unary")
  end
  do
    local sizes = { 27182, 8, 1828, 45904 }
    local reqs = {}
    local total = 0
    for i, s in ipairs(sizes) do
      reqs[i] = StreamingInputCallRequest.new(payload(s))
      reqs[i].expectCompressed = messages.BoolValue.new(true)
      total = total + s
    end
    local resp = client:streamingInputCall(reqs, gzip)
    util.check(resp.aggregatedPayloadSize == total, "client_compressed_streaming: aggregated")
    print("interop case ok: client_compressed_streaming")
  end
  do
    local req = SimpleRequest.new()
    req.responseSize = 31415
    req.payload = payload(271828)
    req.responseCompressed = messages.BoolValue.new(true)
    local resp = client:unaryCall(req)
    util.check(#resp.payload.body == 31415, "server_compressed_unary: body")
    print("interop case ok: server_compressed_unary")
  end
  do
    local sizes = { 31415, 9, 2653, 58979 }
    local req = StreamingOutputCallRequest.new()
    local params = {}
    for i, s in ipairs(sizes) do params[i] = ResponseParameters.new(s, 0, messages.BoolValue.new(true)) end
    req.responseParameters = params
    req.payload = payload(0)
    local stream = client:streamingOutputCall(req)
    checkSizes("server_compressed_streaming", recvAll(stream, "server_compressed_streaming"), sizes)
    stream:close()
    print("interop case ok: server_compressed_streaming")
  end
end

-- ORCA rows (upstream orca_per_rpc / orca_oob): per-RPC the
-- report returns as the serialized OrcaLoadReport in the
-- endpoint-load-metrics-bin trailer (base64 -bin value); OOB the
-- value fed through FullDuplexCall comes back on the
-- OpenRcaService StreamCoreMetrics stream.
local function runOrcaCases(channel, client)
  local req = SimpleRequest.new()
  req.orcaPerQueryReport = messages.TestOrcaReport.new(
    0.8210, 0.5847, { cost = 3456.32 }, { util = 0.30499 })
  local stream = channel:serverStream("/grpc.testing.TestService/UnaryCall", req)
  local resp = messages.SimpleResponse.new()
  stream:recv(resp)
  local ok, err = pcall(function()
    return stream:recv(messages.SimpleResponse.new())
  end)
  util.check(not ok and err == EndOfStream, "orca_per_rpc: expected end")
  local encoded = stream.trailers and stream.trailers["endpoint-load-metrics-bin"]
  util.check(encoded ~= nil, "orca_per_rpc: no endpoint-load-metrics-bin trailer")
  local report = orcaReportMessages.OrcaLoadReport.new()
  report:unmarshalDc(b64decode(encoded))
  util.check(report.cpuUtilization == 0.8210 and report.memUtilization == 0.5847
    and report.requestCost["cost"] == 3456.32
    and report.utilization["util"] == 0.30499, "orca_per_rpc: report mismatch")
  stream:close()
  print("interop case ok: orca_per_rpc")

  local feedReq = StreamingOutputCallRequest.new()
  feedReq.orcaOobReport = messages.TestOrcaReport.new(0.9, 0.85, {}, { util = 0.5 })
  local feed = client:fullDuplexCall({ feedReq })
  local fok, ferr = pcall(function() return feed:recv() end)
  util.check(not fok and ferr == EndOfStream, "orca_oob: feed did not complete")
  feed:close()
  local orca = orcaStubs.OpenRcaServiceClient.new(channel)
  local metrics = orca:streamCoreMetrics(orcaMessages.OrcaLoadReportRequest.new(), nil, 30)
  local matched = false
  for _ = 1, 30 do
    local got = metrics:recv()
    if got.cpuUtilization == 0.9 and got.memUtilization == 0.85
      and got.utilization["util"] == 0.5 then
      matched = true
      break
    end
  end
  util.check(matched, "orca_oob: no matching OOB report")
  metrics:close()
  print("interop case ok: orca_oob")
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
    runCases(channel, client, unimpl)
    runCompressionCases(client)
    runOrcaCases(channel, client)
  end)
  util.kill(bridge.pid)
  util.kill(server)
  if not ok then error(err, 0) end
  print("TestInteropOracle OK")
end

return testInteropOracle
