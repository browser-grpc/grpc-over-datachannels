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

    override fun marshalStruct(): ByteArray = EchoRequestStruct.marshal(this)

    override fun unmarshalStruct(data: ByteArray) {
        val m = EchoRequestStruct.unmarshal(data)
        message = m.message
        count = m.count
        delayMs = m.delayMs
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

    override fun marshalStruct(): ByteArray = EchoResponseStruct.marshal(this)

    override fun unmarshalStruct(data: ByteArray) {
        val m = EchoResponseStruct.unmarshal(data)
        message = m.message
        index = m.index
    }

    override fun toString(): String = "EchoResponse{message=$message, index=$index}"
}

/** Struct companions for the Wasm build: transcode through the
 *  pure grpcdc.StructDc (the JVM build's JNI call-in is
 *  unavailable on Wasm). Descriptor is proto/echo.proto's set,
 *  mirroring kotlin/examples/EchoRequestStruct.kt. */
object EchoStruct {
    val descriptor: ByteArray = hexDecode("0ac1090a0a6563686f2e70726f746f12046563686f22580a0b4563686f5265717565737412180a076d65737361676518012001280952076d65737361676512140a05636f756e741802200128055205636f756e7412190a0864656c61795f6d73180320012805520764656c61794d73223e0a0c4563686f526573706f6e736512180a076d65737361676518012001280952076d65737361676512140a05696e6465781802200128055205696e64657832db010a044563686f122e0a05556e61727912112e6563686f2e4563686f526571756573741a122e6563686f2e4563686f526573706f6e736512370a0c53657276657253747265616d12112e6563686f2e4563686f526571756573741a122e6563686f2e4563686f526573706f6e7365300112370a0c436c69656e7453747265616d12112e6563686f2e4563686f526571756573741a122e6563686f2e4563686f526573706f6e7365280112310a044269646912112e6563686f2e4563686f526571756573741a122e6563686f2e4563686f526573706f6e7365280130014aac060a061204000015010a080a010c12030000120a080a0102120302000d0a0a0a0204001204040008010a0a0a0304000112030408130a0b0a040400020012030502150a0c0a05040002000512030502080a0c0a05040002000112030509100a0c0a05040002000312030513140a3f0a040400020112030602122232207365727665722d73747265616d696e673a206e756d626572206f6620726573706f6e73657320746f2070726f647563650a0a0c0a05040002010512030602070a0c0a050400020101120306080d0a0c0a05040002010312030610110a390a04040002021203070215222c2069676e6f72656420627920746865207265666572656e636520736572766572733b2072657365727665640a0a0c0a05040002020512030702070a0c0a05040002020112030708100a0c0a05040002020312030713140a0a0a02040112040a000d010a0a0a0304010112030a08140a0b0a040401020012030b02150a0c0a05040102000512030b02080a0c0a05040102000112030b09100a0c0a05040102000312030b13140a0b0a040401020112030c02120a0c0a05040102010512030c02070a0c0a05040102010112030c080d0a0c0a05040102010312030c10110a490a0206001204100015011a3d2045786572636973657320616c6c20666f75722067525043206d6574686f6420736861706573206f766572206f6e6520446174614368616e6e656c2e0a0a0a0a03060001120310080c0a0b0a040600020012031102300a0c0a050600020001120311060b0a0c0a0506000200021203110c170a0c0a050600020003120311222e0a0b0a0406000201120312023e0a0c0a05060002010112031206120a0c0a050600020102120312131e0a0c0a050600020106120312292f0a0c0a050600020103120312303c0a0b0a0406000202120313023e0a0c0a05060002020112031306120a0c0a05060002020512031313190a0c0a0506000202021203131a250a0c0a050600020203120313303c0a0b0a0406000203120314023d0a0c0a050600020301120314060a0a0c0a0506000203051203140b110a0c0a050600020302120314121d0a0c0a050600020306120314282e0a0c0a0506000203031203142f3b620670726f746f33")

    private fun hexDigit(c: Char): Int = "0123456789abcdef".indexOf(c)

    fun hexDecode(s: String): ByteArray {
        val out = ByteArray(s.length / 2)
        for (i in out.indices) {
            out[i] = ((hexDigit(s[2 * i]) shl 4) or hexDigit(s[2 * i + 1])).toByte()
        }
        return out
    }
}

object EchoRequestStruct {
    fun marshal(m: EchoRequest): ByteArray =
        grpcdc.StructDc.encode(EchoStruct.descriptor, "echo.EchoRequest", m.marshalDc())

    fun unmarshal(data: ByteArray): EchoRequest {
        val m = EchoRequest()
        m.unmarshalDc(grpcdc.StructDc.decode(EchoStruct.descriptor, "echo.EchoRequest", data))
        return m
    }
}

object EchoResponseStruct {
    fun marshal(m: EchoResponse): ByteArray =
        grpcdc.StructDc.encode(EchoStruct.descriptor, "echo.EchoResponse", m.marshalDc())

    fun unmarshal(data: ByteArray): EchoResponse {
        val m = EchoResponse()
        m.unmarshalDc(grpcdc.StructDc.decode(EchoStruct.descriptor, "echo.EchoResponse", data))
        return m
    }
}
