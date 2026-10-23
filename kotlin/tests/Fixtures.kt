package tests

/** Golden vectors stamped by racket/metagen.rkt (same values as
 * fixtures/vectors.json). Rows: name, type, streamId, frameHex, payloadHex. */
object Fixtures {
    class FrameVector(
        val name: String,
        val type: Int,
        val streamId: Long,
        val frameHex: String,
        val payloadHex: String
    )

    val Frames: List<FrameVector> = listOf(
        FrameVector("headers", 1, 1, "0100000001000000297b2270617468223a222f6563686f2e4563686f2f556e617279222c226d65746164617461223a7b7d7d", "7b2270617468223a222f6563686f2e4563686f2f556e617279222c226d65746164617461223a7b7d7d"),
        FrameVector("data", 2, 3, "0200000003000000060a0268691002", "0a0268691002"),
        FrameVector("trailers", 3, 1, "0300000001000000177b22636f6465223a302c226d657373616765223a22227d", "7b22636f6465223a302c226d657373616765223a22227d")
    )

    /** EchoRequest{message:"hi", count:2} protobuf bytes. */
    const val ProtoHex = "0a0268691002"
}
