local channelModule = require("grpcdc.channel")
local serverModule = require("grpcdc.server")
local statusModule = require("grpcdc.status")
local wire = require("grpcdc.wire")
local memoryModule = require("grpcdc.memory_transport")
local stubs = require("examples.echo_grpc_dc")
local impl = require("examples.echo_service_impl")
local messages = require("examples.echo_messages")
local util = require("test_util")

local EchoRequest = messages.EchoRequest
local EndOfStream = statusModule.EndOfStream

local function req(message, count)
  return EchoRequest.new(message, count)
end

local function setup(clientStruct, serverStruct)
  local a, b = memoryModule.memoryTransportPair()
  local server = serverModule.Server.new()
  server:setStructCodec(serverStruct)
  stubs.registerEchoServer(server, impl)
  server:serveTransport(b)
  local channel = channelModule.Channel.new(a)
  channel:setStructCodec(clientStruct)
  return stubs.EchoClient.new(channel)
end

--- Struct-codec negotiation: struct<->struct roundtrip, mismatch
--- rejected UNIMPLEMENTED, plain client still works.
local function testStructCodec()
  local client = setup(true, true)

  local unary = client:unary(req("hello", 0))
  util.check(unary.message == "echo: hello", "struct unary: " .. unary.message)

  local stream = client:serverStream(req("tick", 3))
  local n = 0
  while true do
    local ok, resp = pcall(function() return stream:recv() end)
    if not ok then
      if resp == EndOfStream then break end
      error(resp, 0)
    end
    n = n + 1
  end
  util.check(n == 3, "struct server-stream count: " .. n)

  local joined = client:clientStream({ req("a", 0), req("b", 0) })
  util.check(joined.message == "a+b", "struct client-stream: " .. joined.message)

  local bidi = client:bidi({ req("x", 0), req("y", 0) })
  local echoed = {}
  while true do
    local ok, resp = pcall(function() return bidi:recv() end)
    if not ok then
      if resp == EndOfStream then break end
      error(resp, 0)
    end
    echoed[#echoed + 1] = resp.message
  end
  util.check(#echoed == 2 and echoed[1] == "x" and echoed[2] == "y",
    "struct bidi: " .. table.concat(echoed, ","))

  local structBytes = req("hello", 0):marshalStruct()
  util.check(structBytes:sub(1, 4) == "DCS1", "struct magic")
  local back = EchoRequest.new()
  back:unmarshalStruct(structBytes)
  util.check(back.message == "hello", "struct roundtrip: " .. back.message)

  local mismatch = setup(true, false)
  local ok, err = pcall(function() return mismatch:unary(req("hello", 0)) end)
  util.check(not ok, "struct client vs plain server should fail")
  util.check(type(err) == "table" and err.code == wire.CODE_UNIMPLEMENTED,
    "mismatch status: " .. tostring(err))

  local plain = setup(false, true)
  local plainResp = plain:unary(req("hello", 0))
  util.check(plainResp.message == "echo: hello",
    "plain vs struct server: " .. plainResp.message)

  print("TestStructCodec OK")
end

return testStructCodec
