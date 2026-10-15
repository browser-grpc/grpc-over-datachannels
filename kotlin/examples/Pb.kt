package echo

import java.io.ByteArrayOutputStream
import java.nio.charset.StandardCharsets

/** Minimal protobuf wire writer/reader for the hand-written messages. */
object Pb {
    class Writer {
        private val out = ByteArrayOutputStream()

        fun varint(value: Long) {
            var v = value
            while ((v and -0x80L) != 0L) {
                out.write(((v and 0x7f) or 0x80).toInt())
                v = v ushr 7
            }
            out.write(v.toInt())
        }

        fun stringField(field: Int, value: String) {
            if (value.isEmpty()) {
                return
            }
            val bytes = value.toByteArray(StandardCharsets.UTF_8)
            varint(((field shl 3) or 2).toLong())
            varint(bytes.size.toLong())
            out.write(bytes)
        }

        fun int32Field(field: Int, value: Int) {
            if (value == 0) {
                return
            }
            varint(((field shl 3) or 0).toLong())
            varint(value.toLong())
        }

        fun toBytes(): ByteArray = out.toByteArray()
    }

    class Field(val number: Int, val varintValue: Long, val bytesValue: ByteArray) {
        fun asInt32(): Int = varintValue.toInt()
        fun asString(): String = String(bytesValue, StandardCharsets.UTF_8)
    }

    class Reader(private val buf: ByteArray) {
        private var pos = 0

        fun varint(): Long {
            var result = 0L
            var shift = 0
            while (true) {
                if (pos >= buf.size) {
                    throw IllegalArgumentException("truncated varint")
                }
                val b = buf[pos++].toInt() and 0xff
                result = result or ((b and 0x7f).toLong() shl shift)
                if (b and 0x80 == 0) {
                    return result
                }
                shift += 7
                if (shift >= 64) {
                    throw IllegalArgumentException("varint too long")
                }
            }
        }

        /** Next field, or null at end. */
        fun next(): Field? {
            if (pos >= buf.size) {
                return null
            }
            val tag = varint()
            val number = (tag ushr 3).toInt()
            return when ((tag and 7).toInt()) {
                0 -> Field(number, varint(), ByteArray(0))
                2 -> {
                    val n = varint().toInt()
                    if (pos + n > buf.size) {
                        throw IllegalArgumentException("truncated bytes field")
                    }
                    val bytes = buf.copyOfRange(pos, pos + n)
                    pos += n
                    Field(number, 0, bytes)
                }
                1 -> {
                    if (pos + 8 > buf.size) {
                        throw IllegalArgumentException("truncated fixed64")
                    }
                    val bytes = buf.copyOfRange(pos, pos + 8)
                    pos += 8
                    Field(number, 0, bytes)
                }
                5 -> {
                    if (pos + 4 > buf.size) {
                        throw IllegalArgumentException("truncated fixed32")
                    }
                    val bytes = buf.copyOfRange(pos, pos + 4)
                    pos += 4
                    Field(number, 0, bytes)
                }
                else -> throw IllegalArgumentException("bad wire type")
            }
        }
    }
}
