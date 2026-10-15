local Codec = require("grpcdc.codec")
local wire = require("grpcdc.wire")
local messages = require("examples.echo_messages")
local fixtures = require("fixtures")
local util = require("test_util")

--- Golden-vector codec tests (fixtures stamped by the metaprogram).
local function testCodec()
  for _, v in ipairs(fixtures.frames) do
    local raw = util.fromHex(v.frameHex)
    local frame = Codec.decodeFrame(raw)
    util.check(frame.type == v.frameType, v.name .. ": type")
    util.check(frame.streamId == v.streamId, v.name .. ": stream")
    util.check(util.toHex(Codec.encodeFrame(frame.type, frame.streamId, frame.payload)) == v.frameHex,
      v.name .. ": re-encode")
    util.check(util.toHex(frame.payload) == v.payloadHex, v.name .. ": payload")
  end

  local req = messages.EchoRequest.new("hi", 2)
  util.check(util.toHex(req:marshalDc()) == fixtures.protoHex, "protobuf encode")
  local decoded = messages.EchoRequest.new()
  decoded:unmarshalDc(util.fromHex(fixtures.protoHex))
  util.check(decoded.message == "hi" and decoded.count == 2, "protobuf decode")

  util.check(wire.statusName(0) == "OK", "status 0")
  util.check(wire.statusName(3) == "INVALID-ARGUMENT", "status 3")
  util.check(wire.statusName(999) == "CODE_999", "status 999")
  print("TestCodec OK")
end

return testCodec
