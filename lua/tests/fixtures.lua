--- Golden vectors stamped by racket/metagen.rkt (same values as
--- fixtures/vectors.json). Rows: name, type, streamId, frameHex, payloadHex.
local frames = {
  { name = "headers", frameType = 1, streamId = 1, frameHex = "0100000001000000297b2270617468223a222f6563686f2e4563686f2f556e617279222c226d65746164617461223a7b7d7d", payloadHex = "7b2270617468223a222f6563686f2e4563686f2f556e617279222c226d65746164617461223a7b7d7d" },
  { name = "data", frameType = 2, streamId = 3, frameHex = "0200000003000000060a0268691002", payloadHex = "0a0268691002" },
  { name = "trailers", frameType = 3, streamId = 1, frameHex = "0300000001000000177b22636f6465223a302c226d657373616765223a22227d", payloadHex = "7b22636f6465223a302c226d657373616765223a22227d" },
}

--- EchoRequest{message:"hi", count:2} protobuf bytes.
local protoHex = "0a0268691002"

return { frames = frames, protoHex = protoHex }
