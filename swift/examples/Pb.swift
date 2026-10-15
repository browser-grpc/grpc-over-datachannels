/// Minimal protobuf wire writer/reader for the hand-written messages.
enum Pb {
    final class Writer {
        private var out: [UInt8] = []

        func Varint(_ value: Int64) {
            var v = UInt64(bitPattern: value)
            while (v & ~0x7f) != 0 {
                out.append(UInt8((v & 0x7f) | 0x80))
                v >>= 7
            }
            out.append(UInt8(v))
        }

        func StringField(_ field: Int, _ value: String) {
            if value.isEmpty { return }
            let bytes = [UInt8](value.utf8)
            Varint(Int64((field << 3) | 2))
            Varint(Int64(bytes.count))
            out.append(contentsOf: bytes)
        }

        func Int32Field(_ field: Int, _ value: Int32) {
            if value == 0 { return }
            Varint(Int64((field << 3) | 0))
            Varint(Int64(value))
        }

        func ToBytes() -> [UInt8] { out }
    }

    struct Field {
        var number: Int = 0
        var varintValue: Int64 = 0
        var bytesValue: [UInt8] = []

        func AsInt32() -> Int32 { Int32(truncatingIfNeeded: varintValue) }
        func AsString() -> String { String(decoding: bytesValue, as: UTF8.self) }
    }

    final class Reader {
        private let buf: [UInt8]
        private var pos = 0

        init(_ buf: [UInt8]) { self.buf = buf }

        func Varint() throws -> Int64 {
            var result: Int64 = 0
            var shift = 0
            while true {
                if pos >= buf.count {
                    throw StatusException(Wire.CodeInvalidArgument, "truncated varint")
                }
                let b = buf[pos]
                pos += 1
                result |= Int64(b & 0x7f) << shift
                if (b & 0x80) == 0 { return result }
                shift += 7
                if shift >= 64 {
                    throw StatusException(Wire.CodeInvalidArgument, "varint too long")
                }
            }
        }

        /// Next field, or nil at end.
        func Next() throws -> Field? {
            if pos >= buf.count { return nil }
            let tag = try Varint()
            var field = Field()
            field.number = Int(tag >> 3)
            switch Int(tag & 7) {
            case 0:
                field.varintValue = try Varint()
            case 2:
                let n = Int(try Varint())
                if pos + n > buf.count {
                    throw StatusException(Wire.CodeInvalidArgument, "truncated bytes field")
                }
                field.bytesValue = Array(buf[pos..<(pos + n)])
                pos += n
            case 1:
                if pos + 8 > buf.count {
                    throw StatusException(Wire.CodeInvalidArgument, "truncated fixed64")
                }
                field.bytesValue = Array(buf[pos..<(pos + 8)])
                pos += 8
            case 5:
                if pos + 4 > buf.count {
                    throw StatusException(Wire.CodeInvalidArgument, "truncated fixed32")
                }
                field.bytesValue = Array(buf[pos..<(pos + 4)])
                pos += 4
            default:
                throw StatusException(Wire.CodeInvalidArgument, "bad wire type")
            }
            return field
        }
    }
}
