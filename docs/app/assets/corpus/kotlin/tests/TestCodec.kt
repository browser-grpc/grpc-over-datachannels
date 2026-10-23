package tests

import echo.EchoRequest
import grpcdc.Codec
import grpcdc.Wire

/** Golden-vector codec tests (Fixtures stamped by the metaprogram). */
fun testCodec() {
    for (v in Fixtures.Frames) {
        val raw = fromHex(v.frameHex)
        val frame = Codec.decodeFrame(raw)
        check(frame.type == v.type, "${v.name}: type")
        check(frame.streamId == v.streamId, "${v.name}: stream")
        check(toHex(Codec.encodeFrame(frame.type, frame.streamId, frame.payload)) == v.frameHex, "${v.name}: re-encode")
        check(toHex(frame.payload) == v.payloadHex, "${v.name}: payload")
    }

    val req = EchoRequest("hi", 2)
    check(toHex(req.marshalDc()) == Fixtures.ProtoHex, "protobuf encode")
    val decoded = EchoRequest()
    decoded.unmarshalDc(fromHex(Fixtures.ProtoHex))
    check(decoded.message == "hi" && decoded.count == 2, "protobuf decode")

    check(Wire.statusName(0) == "OK", "status 0")
    check(Wire.statusName(3) == "INVALID-ARGUMENT", "status 3")
    check(Wire.statusName(999) == "CODE_999", "status 999")
    println("TestCodec OK")
}
