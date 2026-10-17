package echo

import java.io.ByteArrayOutputStream
import java.nio.charset.StandardCharsets

/** Minimal protobuf wire writer/reader for the hand-written messages. */
object Pb {
  class Writer {
    private val out = new ByteArrayOutputStream()

    def varint(value: Long): Unit = {
      var v = value
      while ((v & -0x80L) != 0L) {
        out.write(((v & 0x7f) | 0x80).toInt)
        v = v >>> 7
      }
      out.write(v.toInt)
    }

    def stringField(field: Int, value: String): Unit = {
      if (value.isEmpty) {
        return
      }
      val bytes = value.getBytes(StandardCharsets.UTF_8)
      varint(((field << 3) | 2).toLong)
      varint(bytes.length.toLong)
      out.write(bytes)
    }

    def int32Field(field: Int, value: Int): Unit = {
      if (value == 0) {
        return
      }
      varint(((field << 3) | 0).toLong)
      varint(value.toLong)
    }

    def toBytes: Array[Byte] = out.toByteArray
  }

  class Field(val number: Int, val varintValue: Long, val bytesValue: Array[Byte]) {
    def asInt32: Int = varintValue.toInt
    def asString: String = new String(bytesValue, StandardCharsets.UTF_8)
  }

  class Reader(private val buf: Array[Byte]) {
    private var pos = 0

    def varint(): Long = {
      var result = 0L
      var shift = 0
      while (true) {
        if (pos >= buf.length) {
          throw new IllegalArgumentException("truncated varint")
        }
        val b = buf(pos).toInt & 0xff
        pos += 1
        result = result | ((b & 0x7f).toLong << shift)
        if ((b & 0x80) == 0) {
          return result
        }
        shift += 7
        if (shift >= 64) {
          throw new IllegalArgumentException("varint too long")
        }
      }
      0L // unreachable
    }

    /** Next field, or null at end. */
    def next(): Field = {
      if (pos >= buf.length) {
        return null
      }
      val tag = varint()
      val number = (tag >>> 3).toInt
      (tag & 7).toInt match {
        case 0 => new Field(number, varint(), Array.empty[Byte])
        case 2 =>
          val n = varint().toInt
          if (pos + n > buf.length) {
            throw new IllegalArgumentException("truncated bytes field")
          }
          val bytes = buf.slice(pos, pos + n)
          pos += n
          new Field(number, 0, bytes)
        case 1 =>
          if (pos + 8 > buf.length) {
            throw new IllegalArgumentException("truncated fixed64")
          }
          val bytes = buf.slice(pos, pos + 8)
          pos += 8
          new Field(number, 0, bytes)
        case 5 =>
          if (pos + 4 > buf.length) {
            throw new IllegalArgumentException("truncated fixed32")
          }
          val bytes = buf.slice(pos, pos + 4)
          pos += 4
          new Field(number, 0, bytes)
        case _ => throw new IllegalArgumentException("bad wire type")
      }
    }
  }
}
