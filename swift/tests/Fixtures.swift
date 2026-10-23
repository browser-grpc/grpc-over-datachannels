/// Golden vectors stamped by racket/metagen.rkt (same values as
/// fixtures/vectors.json). Rows: name, type, streamId, frameHex, payloadHex.
enum Fixtures {
    struct FrameVector {
        let name: String
        let type: Int
        let streamId: UInt32
        let frameHex: String
        let payloadHex: String
    }

    static let Frames: [FrameVector] = [
        FrameVector(name: "headers", type: 1, streamId: 1, frameHex: "0100000001000000297b2270617468223a222f6563686f2e4563686f2f556e617279222c226d65746164617461223a7b7d7d", payloadHex: "7b2270617468223a222f6563686f2e4563686f2f556e617279222c226d65746164617461223a7b7d7d"),
        FrameVector(name: "data", type: 2, streamId: 3, frameHex: "0200000003000000060a0268691002", payloadHex: "0a0268691002"),
        FrameVector(name: "trailers", type: 3, streamId: 1, frameHex: "0300000001000000177b22636f6465223a302c226d657373616765223a22227d", payloadHex: "7b22636f6465223a302c226d657373616765223a22227d"),
    ]

    /// EchoRequest{message:"hi", count:2} protobuf bytes.
    static let ProtoHex = "0a0268691002"
}
