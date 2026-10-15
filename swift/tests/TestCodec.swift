import Foundation

/// Golden-vector codec tests (Fixtures stamped by the metaprogram).
func TestCodec() throws {
    for v in Fixtures.Frames {
        let raw = FromHex(v.frameHex)
        let frame = try Codec.DecodeFrame(raw)
        try Check(frame.type == v.type, "\(v.name): type")
        try Check(frame.streamId == v.streamId, "\(v.name): stream")
        try Check(ToHex(try Codec.EncodeFrame(frame.type, frame.streamId, frame.payload)) == v.frameHex,
                  "\(v.name): re-encode")
        try Check(ToHex(frame.payload) == v.payloadHex, "\(v.name): payload")
    }

    let req = EchoRequest("hi", 2)
    try Check(ToHex(req.MarshalDc()) == Fixtures.ProtoHex, "protobuf encode")
    let decoded = EchoRequest()
    decoded.UnmarshalDc(FromHex(Fixtures.ProtoHex))
    try Check(decoded.message == "hi" && decoded.count == 2, "protobuf decode")

    try Check(Wire.StatusName(0) == "OK", "status 0")
    try Check(Wire.StatusName(3) == "INVALID-ARGUMENT", "status 3")
    try Check(Wire.StatusName(999) == "CODE_999", "status 999")
    print("TestCodec OK")
}
