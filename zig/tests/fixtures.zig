/// Golden vectors stamped by racket/metagen.rkt (same values as
/// fixtures/vectors.json). Rows: name, type, streamId, frameHex, payloadHex.
pub const FrameVector = struct {
    name: []const u8,
    frame_type: u8,
    stream_id: u32,
    frame_hex: []const u8,
    payload_hex: []const u8,
};

pub const frames = [_]FrameVector{
    .{ .name = "headers", .frame_type = 1, .stream_id = 1, .frame_hex = "0100000001000000297b2270617468223a222f6563686f2e4563686f2f556e617279222c226d65746164617461223a7b7d7d", .payload_hex = "7b2270617468223a222f6563686f2e4563686f2f556e617279222c226d65746164617461223a7b7d7d" },
    .{ .name = "data", .frame_type = 2, .stream_id = 3, .frame_hex = "0200000003000000060a0268691002", .payload_hex = "0a0268691002" },
    .{ .name = "trailers", .frame_type = 3, .stream_id = 1, .frame_hex = "0300000001000000177b22636f6465223a302c226d657373616765223a22227d", .payload_hex = "7b22636f6465223a302c226d657373616765223a22227d" },
};

/// EchoRequest{message:"hi", count:2} protobuf bytes.
pub const proto_hex = "0a0268691002";
