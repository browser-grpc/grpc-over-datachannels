package echo

import grpcdc.Marshaler
import grpcdc.Unmarshaler

/**
 * Hand-written protobuf messages for proto/echo.proto
 * (package echo), common-Kotlin only for the WASM build.
 * Mirrors kotlin/examples/EchoMessages.kt; the wire bytes are
 * genuine protobuf: EchoRequest{message:"hi", count:2}
 * encodes to 0a0268691002.
 */
class EchoRequest(
    var message: String = "",
    var count: Int = 0,
    var delayMs: Int = 0
) : Marshaler, Unmarshaler {
    override fun marshalDc(): ByteArray {
        val w = Pb.Writer()
        w.stringField(1, message)
        w.int32Field(2, count)
        w.int32Field(3, delayMs)
        return w.toBytes()
    }

    override fun unmarshalDc(data: ByteArray) {
        message = ""
        count = 0
        delayMs = 0
        val r = Pb.Reader(data)
        while (true) {
            val field = r.next() ?: break
            when (field.number) {
                1 -> message = field.asString()
                2 -> count = field.asInt32()
                3 -> delayMs = field.asInt32()
                else -> {
                    // skip unknown fields
                }
            }
        }
    }

    override fun toString(): String =
        "EchoRequest{message=$message, count=$count, delayMs=$delayMs}"
}

class EchoResponse(
    var message: String = "",
    var index: Int = 0
) : Marshaler, Unmarshaler {
    override fun marshalDc(): ByteArray {
        val w = Pb.Writer()
        w.stringField(1, message)
        w.int32Field(2, index)
        return w.toBytes()
    }

    override fun unmarshalDc(data: ByteArray) {
        message = ""
        index = 0
        val r = Pb.Reader(data)
        while (true) {
            val field = r.next() ?: break
            when (field.number) {
                1 -> message = field.asString()
                2 -> index = field.asInt32()
                else -> {
                    // skip unknown fields
                }
            }
        }
    }

    override fun toString(): String = "EchoResponse{message=$message, index=$index}"
}
