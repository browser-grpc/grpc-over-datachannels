/// Hand-written protobuf messages for proto/echo.proto (package echo).
///
/// Deliberately minimal (two messages) so the example needs no
/// protobuf codegen dependency — the wire bytes are genuine protobuf:
/// EchoRequest{message:"hi", count:2} encodes to 0a0268691002.
/// Mirrors go/examples/echo_pb.go.
final class EchoRequest: Marshaler, Unmarshaler, CustomStringConvertible {
    var message: String = ""
    var count: Int32 = 0
    var delayMs: Int32 = 0

    init() {}
    init(_ message: String, _ count: Int32) {
        self.message = message
        self.count = count
    }

    func MarshalDc() -> [UInt8] {
        let w = Pb.Writer()
        w.StringField(1, message)
        w.Int32Field(2, count)
        w.Int32Field(3, delayMs)
        return w.ToBytes()
    }

    func UnmarshalDc(_ data: [UInt8]) {
        message = ""
        count = 0
        delayMs = 0
        let r = Pb.Reader(data)
        while true {
            let next: Pb.Field?
            do { next = try r.Next() } catch { break }
            guard let field = next else { break }
            switch field.number {
            case 1: message = field.AsString()
            case 2: count = field.AsInt32()
            case 3: delayMs = field.AsInt32()
            default: break  // skip unknown fields
            }
        }
    }

    var description: String { "EchoRequest{message=\(message), count=\(count), delayMs=\(delayMs)}" }
}

final class EchoResponse: Marshaler, Unmarshaler, CustomStringConvertible {
    var message: String = ""
    var index: Int32 = 0

    init() {}
    init(_ message: String, _ index: Int32) {
        self.message = message
        self.index = index
    }

    func MarshalDc() -> [UInt8] {
        let w = Pb.Writer()
        w.StringField(1, message)
        w.Int32Field(2, index)
        return w.ToBytes()
    }

    func UnmarshalDc(_ data: [UInt8]) {
        message = ""
        index = 0
        let r = Pb.Reader(data)
        while true {
            let next: Pb.Field?
            do { next = try r.Next() } catch { break }
            guard let field = next else { break }
            switch field.number {
            case 1: message = field.AsString()
            case 2: index = field.AsInt32()
            default: break  // skip unknown fields
            }
        }
    }

    var description: String { "EchoResponse{message=\(message), index=\(index)}" }
}
