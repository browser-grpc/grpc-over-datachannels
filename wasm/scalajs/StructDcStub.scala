package grpcdc

import java.nio.charset.StandardCharsets
import scala.collection.mutable

/** Scala.js implementation of the struct codec: a pure,
  * descriptor-driven DCS1 transcoder over a minimal internal
  * dynamic model (the JNI-backed StructDc used on the JVM is
  * unavailable on JS). Byte-identical to the shared Rust
  * implementation (conformance/struct). Replaces the former
  * throwing stub, so struct calls work in Scala.js builds.
  */
object StructDc {
  def encode(descriptor: Array[Byte], typeName: String, pb: Array[Byte]): Array[Byte] =
    StructdcPure.transcode(descriptor, typeName, pb, encode = true)

  def decode(descriptor: Array[Byte], typeName: String, data: Array[Byte]): Array[Byte] =
    StructdcPure.transcode(descriptor, typeName, data, encode = false)
}

private object StructdcPure {
  // FieldDescriptorProto.Type values.
  private val T_DOUBLE = 1
  private val T_FLOAT = 2
  private val T_INT64 = 3
  private val T_UINT64 = 4
  private val T_INT32 = 5
  private val T_FIXED64 = 6
  private val T_FIXED32 = 7
  private val T_BOOL = 8
  private val T_STRING = 9
  private val T_GROUP = 10
  private val T_MESSAGE = 11
  private val T_BYTES = 12
  private val T_UINT32 = 13
  private val T_ENUM = 14
  private val T_SFIXED32 = 15
  private val T_SFIXED64 = 16
  private val T_SINT32 = 17
  private val T_SINT64 = 18

  private def fail(msg: String): StatusException =
    new StatusException(Wire.CODE_INVALID_ARGUMENT, msg)

  private class FieldM(
      var number: Int = 0,
      var name: String = "",
      var ftype: Int = 0,
      var repeated: Boolean = false,
      var typeName: String = ""
  )

  private class MsgM(val fullName: String) {
    val fields: mutable.Map[Int, FieldM] = mutable.TreeMap()
    var mapEntry: Boolean = false
  }

  private class FileM {
    val messages: mutable.Map[String, MsgM] = mutable.HashMap()
  }

  private class Generic(val model: MsgM) {
    val values: mutable.Map[Int, mutable.ListBuffer[Any]] = mutable.TreeMap()
    val unknown: mutable.ListBuffer[Array[Byte]] = mutable.ListBuffer()
    def add(number: Int, value: Any): Unit =
      values.getOrElseUpdate(number, mutable.ListBuffer()) += value
    def set(number: Int, value: Any): Unit =
      values(number) = mutable.ListBuffer(value)
    def get(number: Int): Any = {
      val l = values.getOrElse(number, null)
      if (l == null || l.isEmpty) null else l.head
    }
    def getAll(number: Int): List[Any] =
      values.getOrElse(number, mutable.ListBuffer()).toList
  }

  private class Reader(val buf: Array[Byte]) {
    var pos: Int = 0
    def varint(): Long = {
      var result = 0L
      var shift = 0
      while (true) {
        if (pos >= buf.length) throw fail("truncated varint")
        val b = buf(pos) & 0xff
        pos += 1
        result |= (b & 0x7f).toLong << shift
        if ((b & 0x80) == 0) return result
        shift += 7
        if (shift >= 70) throw fail("varint too long")
      }
      0L
    }
    def take(n: Int): Array[Byte] = {
      if (pos + n > buf.length) throw fail("truncated field")
      val out = buf.slice(pos, pos + n)
      pos += n
      out
    }
    def bytesField(): Array[Byte] = take(varint().toInt)
  }

  // ---- descriptor parsing ----

  private def parseField(data: Array[Byte]): FieldM = {
    val f = new FieldM
    val r = new Reader(data)
    while (r.pos < data.length) {
      val start = r.pos
      val tag = r.varint()
      val num = (tag >> 3).toInt
      val wire = (tag & 7).toInt
      val _ = start
      wire match {
        case 0 =>
          val v = r.varint()
          num match {
            case 1 => ()
            case 3 => f.number = v.toInt
            case 4 => f.repeated = v == 3L
            case 5 => f.ftype = v.toInt
            case _ => ()
          }
        case 2 =>
          val v = r.bytesField()
          num match {
            case 1 => f.name = new String(v, StandardCharsets.UTF_8)
            case 6 => f.typeName = new String(v, StandardCharsets.UTF_8)
            case _ => ()
          }
        case 1 => r.take(8)
        case 5 => r.take(4)
        case _ => throw fail(s"unsupported wire type $wire")
      }
    }
    f
  }

  private def parseMessage(prefix: String, data: Array[Byte], fm: FileM): Unit = {
    var name = ""
    var options: Array[Byte] = null
    val rawFields = mutable.ListBuffer[Array[Byte]]()
    val nested = mutable.ListBuffer[Array[Byte]]()
    val r = new Reader(data)
    while (r.pos < data.length) {
      val tag = r.varint()
      val num = (tag >> 3).toInt
      val wire = (tag & 7).toInt
      wire match {
        case 0 => r.varint()
        case 2 =>
          val v = r.bytesField()
          num match {
            case 1 => name = new String(v, StandardCharsets.UTF_8)
            case 2 => rawFields += v
            case 3 => nested += v
            case 7 => options = v
            case _ => ()
          }
        case 1 => r.take(8)
        case 5 => r.take(4)
        case _ => throw fail(s"unsupported wire type $wire")
      }
    }
    val fullName = if (prefix.isEmpty) name else s"$prefix.$name"
    val model = new MsgM(fullName)
    if (options != null) {
      val ordr = new Reader(options)
      while (ordr.pos < options.length) {
        val tag = ordr.varint()
        val num = (tag >> 3).toInt
        val wire = (tag & 7).toInt
        wire match {
          case 0 => if (num == 7 && ordr.varint() != 0L) model.mapEntry = true
          case 2 => ordr.bytesField()
          case 1 => ordr.take(8)
          case 5 => ordr.take(4)
          case _ => throw fail(s"unsupported wire type $wire")
        }
      }
    }
    fm.messages("." + fullName) = model
    for (b <- rawFields) {
      val f = parseField(b)
      model.fields(f.number) = f
    }
    for (b <- nested) parseMessage(fullName, b, fm)
  }

  private def parseDescriptorSet(data: Array[Byte]): FileM = {
    val fm = new FileM
    val r = new Reader(data)
    while (r.pos < data.length) {
      val tag = r.varint()
      val num = (tag >> 3).toInt
      val wire = (tag & 7).toInt
      wire match {
        case 0 => r.varint()
        case 2 =>
          val fileBytes = r.bytesField()
          if (num == 1) {
            var pkg = ""
            val msgs = mutable.ListBuffer[Array[Byte]]()
            val fr = new Reader(fileBytes)
            while (fr.pos < fileBytes.length) {
              val t2 = fr.varint()
              val n2 = (t2 >> 3).toInt
              val w2 = (t2 & 7).toInt
              w2 match {
                case 0 => fr.varint()
                case 2 =>
                  val v = fr.bytesField()
                  if (n2 == 2) pkg = new String(v, StandardCharsets.UTF_8)
                  else if (n2 == 4) msgs += v
                case 1 => fr.take(8)
                case 5 => fr.take(4)
                case _ => throw fail(s"unsupported wire type $w2")
              }
            }
            for (m <- msgs) parseMessage(pkg, m, fm)
          }
        case 1 => r.take(8)
        case 5 => r.take(4)
        case _ => throw fail(s"unsupported wire type $wire")
      }
    }
    fm
  }

  // ---- protobuf generic codec ----

  private def zigzagDecode(v: Long): Long = (v >> 1) ^ -(v & 1)

  private def decodeValueS(f: FieldM, wire: Int, raw: Any, fm: FileM): Any = {
    wire match {
      case 0 =>
        val v = raw.asInstanceOf[Long]
        f.ftype match {
          case T_BOOL => v != 0L
          case T_SINT32 | T_SINT64 => zigzagDecode(v)
          case T_INT32 | T_ENUM => v.toInt.toLong
          case _ => v
        }
      case 1 =>
        val b = raw.asInstanceOf[Array[Byte]]
        if (f.ftype == T_DOUBLE) java.lang.Double.longBitsToDouble(u64(b, 0))
        else u64(b, 0)
      case 5 =>
        val b = raw.asInstanceOf[Array[Byte]]
        if (f.ftype == T_FLOAT) java.lang.Float.intBitsToFloat(u32(b, 0).toInt).toDouble
        else if (f.ftype == T_SFIXED32) u32(b, 0).toInt.toLong
        else u32(b, 0)
      case _ =>
        val b = raw.asInstanceOf[Array[Byte]]
        f.ftype match {
          case T_STRING => new String(b, StandardCharsets.UTF_8)
          case T_MESSAGE => decodeGenericS(fm.messages(f.typeName), b, fm)
          case _ => b
        }
    }
  }

  private def decodePacked(f: FieldM, data: Array[Byte], fm: FileM): List[Any] = {
    val out = mutable.ListBuffer[Any]()
    if (f.ftype == T_DOUBLE || f.ftype == T_FIXED64 || f.ftype == T_SFIXED64) {
      var i = 0
      while (i + 8 <= data.length) { out += decodeValueS(f, 1, data.slice(i, i + 8), fm); i += 8 }
    } else if (f.ftype == T_FLOAT || f.ftype == T_FIXED32 || f.ftype == T_SFIXED32) {
      var i = 0
      while (i + 4 <= data.length) { out += decodeValueS(f, 5, data.slice(i, i + 4), fm); i += 4 }
    } else {
      val r = new Reader(data)
      while (r.pos < data.length) out += decodeValueS(f, 0, r.varint(), fm)
    }
    out.toList
  }

  private def decodeGenericS(model: MsgM, data: Array[Byte], fm: FileM): Generic = {
    val msg = new Generic(model)
    val r = new Reader(data)
    while (r.pos < data.length) {
      val start = r.pos
      val tag = r.varint()
      val num = (tag >> 3).toInt
      val wire = (tag & 7).toInt
      var raw: Any = null
      wire match {
        case 0 => raw = r.varint()
        case 2 => raw = r.bytesField()
        case 1 => raw = r.take(8)
        case 5 => raw = r.take(4)
        case _ => throw fail(s"unsupported wire type $wire")
      }
      val chunk = data.slice(start, r.pos)
      val f = model.fields.getOrElse(num, null)
      if (f == null) msg.unknown += chunk
      else if (f.repeated && wire == 2 && f.ftype != T_STRING && f.ftype != T_BYTES &&
        f.ftype != T_MESSAGE && f.ftype != T_GROUP) {
        for (v <- decodePacked(f, raw.asInstanceOf[Array[Byte]], fm)) msg.add(num, v)
      } else msg.add(num, decodeValueS(f, wire, raw, fm))
    }
    msg
  }

  private def encodeVarint(out: java.io.ByteArrayOutputStream, value: Long): Unit = {
    var v = value
    while ((v & ~0x7fL) != 0L) {
      out.write(((v & 0x7f) | 0x80).toInt)
      v >>>= 7
    }
    out.write((v & 0xff).toInt)
  }

  private def wireType(t: Int): Int = t match {
    case T_INT64 | T_UINT64 | T_INT32 | T_BOOL | T_UINT32 | T_ENUM | T_SINT32 | T_SINT64 => 0
    case T_FIXED64 | T_SFIXED64 | T_DOUBLE => 1
    case T_STRING | T_MESSAGE | T_BYTES | T_GROUP => 2
    case _ => 5
  }

  private def asLong(v: Any): Long = v match {
    case b: Boolean => if (b) 1L else 0L
    case n: Number => n.longValue()
    case _ => 0L
  }

  private def encodeValue(out: java.io.ByteArrayOutputStream, f: FieldM, v: Any, fm: FileM): Unit = {
    val wire = wireType(f.ftype)
    encodeVarint(out, (f.number << 3 | wire).toLong)
    wire match {
      case 0 =>
        f.ftype match {
          case T_SINT32 =>
            val sv = asLong(v).toInt
            encodeVarint(out, (((sv << 1) ^ (sv >> 31)) & 0xffffffffL).toLong)
          case T_SINT64 =>
            val sv = asLong(v)
            encodeVarint(out, (sv << 1) ^ (sv >> 63))
          case T_BOOL => encodeVarint(out, if (asLong(v) != 0L) 1L else 0L)
          case _ => encodeVarint(out, asLong(v))
        }
      case 1 =>
        if (f.ftype == T_DOUBLE) putU64(out, java.lang.Double.doubleToLongBits(v.asInstanceOf[Number].doubleValue()))
        else putU64(out, asLong(v))
      case 5 =>
        if (f.ftype == T_FLOAT) putU32(out, java.lang.Float.floatToIntBits(v.asInstanceOf[Number].floatValue()).toLong)
        else putU32(out, asLong(v) & 0xffffffffL)
      case _ =>
        val data: Array[Byte] = f.ftype match {
          case T_STRING => v.asInstanceOf[String].getBytes(StandardCharsets.UTF_8)
          case T_MESSAGE => encodeGeneric(fm.messages(f.typeName), v.asInstanceOf[Generic], fm)
          case _ => v.asInstanceOf[Array[Byte]]
        }
        encodeVarint(out, data.length.toLong)
        out.write(data)
    }
  }

  private def encodeGeneric(model: MsgM, msg: Generic, fm: FileM): Array[Byte] = {
    val out = new java.io.ByteArrayOutputStream()
    for (num <- msg.values.keys.toList.sorted) {
      val f = model.fields.getOrElse(num, throw fail(s"unknown field $num for ${model.fullName}"))
      val values = msg.values(num).toList
      if (f.repeated) values.foreach(v => encodeValue(out, f, v, fm))
      else if (values.nonEmpty) encodeValue(out, f, values.head, fm)
    }
    for (c <- msg.unknown) out.write(c)
    out.toByteArray
  }

  // ---- struct codec ----

  private def u32(b: Array[Byte], off: Int): Long = {
    if (off + 4 > b.length) throw fail("struct codec: out of bounds")
    (b(off) & 0xffL) | ((b(off + 1) & 0xffL) << 8) | ((b(off + 2) & 0xffL) << 16) | ((b(off + 3) & 0xffL) << 24)
  }

  private def u64(b: Array[Byte], off: Int): Long = {
    if (off + 8 > b.length) throw fail("struct codec: out of bounds")
    var v = 0L
    var i = 0
    while (i < 8) { v |= (b(off + i) & 0xffL) << (8 * i); i += 1 }
    v
  }

  private def putU32o(buf: Array[Byte], off: Int, v: Long): Unit = {
    buf(off) = (v & 0xff).toByte
    buf(off + 1) = ((v >> 8) & 0xff).toByte
    buf(off + 2) = ((v >> 16) & 0xff).toByte
    buf(off + 3) = ((v >> 24) & 0xff).toByte
  }

  private def putU64o(buf: Array[Byte], off: Int, v: Long): Unit = {
    var i = 0
    while (i < 8) { buf(off + i) = ((v >> (8 * i)) & 0xff).toByte; i += 1 }
  }

  private def putU32(out: java.io.ByteArrayOutputStream, v: Long): Unit = {
    out.write((v & 0xff).toInt); out.write(((v >> 8) & 0xff).toInt)
    out.write(((v >> 16) & 0xff).toInt); out.write(((v >> 24) & 0xff).toInt)
  }

  private def putU64(out: java.io.ByteArrayOutputStream, v: Long): Unit = {
    var i = 0
    while (i < 8) { out.write(((v >> (8 * i)) & 0xff).toInt); i += 1 }
  }

  private def fingerprint(fullName: String): Long = {
    var h = 2166136261L
    for (b <- fullName.getBytes(StandardCharsets.UTF_8)) h = ((h ^ (b & 0xffL)) * 16777619L) & 0xffffffffL
    h
  }

  private def isFixed32(f: FieldM): Boolean =
    f.ftype == T_FLOAT || f.ftype == T_FIXED32 || f.ftype == T_SFIXED32

  private def slotSize(f: FieldM): Int = if (isFixed32(f)) 4 else 8

  private def s32(v: Long): Long = {
    val x = v & 0xffffffffL
    if (x >= 0x80000000L) x - 0x100000000L else x
  }

  private def bytesOf(f: FieldM, v: Any): Array[Byte] = v match {
    case s: String => s.getBytes(StandardCharsets.UTF_8)
    case b: Array[Byte] => b
    case _ => throw fail(s"value does not match field ${f.name} type ${f.ftype}")
  }

  private def nonzero(f: FieldM, v: Any): Boolean = f.ftype match {
    case T_STRING => v.asInstanceOf[String].nonEmpty
    case T_BYTES => v.asInstanceOf[Array[Byte]].nonEmpty
    case T_MESSAGE => v.isInstanceOf[Generic]
    case T_BOOL => v == true || asLong(v) != 0L
    case T_FLOAT | T_DOUBLE => v.asInstanceOf[Number].doubleValue() != 0.0
    case _ => asLong(v) != 0L
  }

  private def sortedFields(model: MsgM): List[FieldM] =
    model.fields.keys.toList.sorted.map(model.fields(_))

  private def mapModel(f: FieldM, fm: FileM): MsgM = {
    if (f.ftype != T_MESSAGE || !f.repeated) return null
    val m = fm.messages.getOrElse(f.typeName, null)
    if (m != null && m.mapEntry) m else null
  }

  private def defaultValue(f: FieldM): Any = f.ftype match {
    case T_STRING => ""
    case T_BYTES => Array.empty[Byte]
    case T_BOOL => false
    case T_FLOAT | T_DOUBLE => 0.0
    case T_MESSAGE => new Generic(null)
    case _ => 0L
  }

  private def keyCmp(kf: FieldM, a: Any, b: Any): Int = {
    if (kf.ftype == T_STRING) return a.asInstanceOf[String].compareTo(b.asInstanceOf[String])
    if (kf.ftype == T_BOOL || kf.ftype == T_UINT32 || kf.ftype == T_UINT64 ||
      kf.ftype == T_FIXED32 || kf.ftype == T_FIXED64) {
      java.lang.Long.compareUnsigned(asLong(a), asLong(b))
    } else java.lang.Long.compare(asLong(a), asLong(b))
  }

  private def mapEntries(f: FieldM, values: List[Any], em: MsgM): List[(Any, Any)] = {
    val kf = em.fields(1)
    val vf = em.fields(2)
    val entries = values.map { e =>
      val entry = e.asInstanceOf[Generic]
      val key = entry.get(1)
      if (key == null) throw fail(s"map field ${f.name} entry missing key")
      val v = entry.get(2)
      (key, if (v == null) defaultValue(vf) else v)
    }
    entries.sortWith((x, y) => keyCmp(kf, x._1, y._1) < 0)
  }

  private def valueSize(f: FieldM, v: Any, fm: FileM): Int = f.ftype match {
    case T_STRING | T_BYTES => bytesOf(f, v).length
    case T_MESSAGE => encodeStruct(fm.messages(f.typeName), v.asInstanceOf[Generic], fm).length
    case _ => if (isFixed32(f)) 4 else 8
  }

  private def fieldPresent(f: FieldM, msg: Generic, fm: FileM): Boolean = {
    val values = msg.getAll(f.number)
    if (mapModel(f, fm) != null || f.repeated) values.nonEmpty
    else values.nonEmpty && nonzero(f, values.head)
  }

  private def structSize(model: MsgM, msg: Generic, fm: FileM): Int = {
    val fields = sortedFields(model)
    val words = math.max(1, (fields.length + 31) / 32)
    var size = 12 + 4 * words + fields.map(slotSize).sum
    for (f <- fields) {
      val values = msg.getAll(f.number)
      val em = mapModel(f, fm)
      if (em != null) {
        val kf = em.fields(1); val vf = em.fields(2)
        for ((k, v) <- mapEntries(f, values, em))
          size += 8 + valueSize(kf, k, fm) + valueSize(vf, v, fm)
      } else if (f.repeated) {
        if (values.nonEmpty) {
          if (f.ftype == T_STRING || f.ftype == T_BYTES || f.ftype == T_MESSAGE) size += 8 * values.length
          for (v <- values) size += valueSize(f, v, fm)
        }
      } else if ((f.ftype == T_STRING || f.ftype == T_BYTES || f.ftype == T_MESSAGE) && fieldPresent(f, msg, fm)) {
        size += valueSize(f, values.head, fm)
      }
    }
    for (c <- msg.unknown) size += c.length
    size
  }

  private def writeScalar(buf: Array[Byte], off: Int, f: FieldM, v: Any): Unit = f.ftype match {
    case T_FLOAT => putU32o(buf, off, java.lang.Float.floatToIntBits(v.asInstanceOf[Number].floatValue()).toLong & 0xffffffffL)
    case T_FIXED32 => putU32o(buf, off, asLong(v))
    case T_SFIXED32 => putU32o(buf, off, s32(asLong(v)))
    case T_DOUBLE => putU64o(buf, off, java.lang.Double.doubleToLongBits(v.asInstanceOf[Number].doubleValue()))
    case T_FIXED64 | T_SFIXED64 => putU64o(buf, off, asLong(v))
    case T_BOOL => buf(off) = (if (asLong(v) != 0L) 1 else 0).toByte
    case _ => putU64o(buf, off, asLong(v))
  }

  private def writeValue(buf: Array[Byte], off: Int, f: FieldM, v: Any, fm: FileM): Unit = f.ftype match {
    case T_STRING | T_BYTES =>
      val b = bytesOf(f, v); System.arraycopy(b, 0, buf, off, b.length)
    case T_MESSAGE =>
      val enc = encodeStruct(fm.messages(f.typeName), v.asInstanceOf[Generic], fm)
      System.arraycopy(enc, 0, buf, off, enc.length)
    case _ => writeScalar(buf, off, f, v)
  }

  private def encodeStruct(model: MsgM, msg: Generic, fm: FileM): Array[Byte] = {
    val fields = sortedFields(model)
    val words = math.max(1, (fields.length + 31) / 32)
    val header = 12 + 4 * words
    val offsets = new Array[Int](fields.length)
    var cursor = header
    for (i <- fields.indices) { offsets(i) = cursor; cursor += slotSize(fields(i)) }
    val fixedEnd = cursor
    val buf = new Array[Byte](structSize(model, msg, fm))
    System.arraycopy("DCS1".getBytes(StandardCharsets.US_ASCII), 0, buf, 0, 4)
    putU32o(buf, 4, buf.length.toLong)
    putU32o(buf, 8, fingerprint(model.fullName))
    for (i <- fields.indices if fieldPresent(fields(i), msg, fm)) {
      val at = 12 + 4 * (i / 32)
      putU32o(buf, at, u32(buf, at) | (1L << (i % 32)))
    }
    var vp = fixedEnd
    for (i <- fields.indices) {
      val f = fields(i)
      val off = offsets(i)
      val values = msg.getAll(f.number)
      val em = mapModel(f, fm)
      if (em != null) {
        if (values.nonEmpty) {
          val kf = em.fields(1); val vf = em.fields(2)
          putU32o(buf, off, vp.toLong)
          putU32o(buf, off + 4, values.length.toLong)
          for ((k, v) <- mapEntries(f, values, em)) {
            val klen = valueSize(kf, k, fm); val vlen = valueSize(vf, v, fm)
            putU32o(buf, vp, klen.toLong); putU32o(buf, vp + 4, vlen.toLong); vp += 8
            writeValue(buf, vp, kf, k, fm); vp += klen
            writeValue(buf, vp, vf, v, fm); vp += vlen
          }
        }
      } else if (f.repeated) {
        if (values.nonEmpty) {
          putU32o(buf, off, vp.toLong)
          putU32o(buf, off + 4, values.length.toLong)
          if (f.ftype == T_STRING || f.ftype == T_BYTES || f.ftype == T_MESSAGE) {
            var doff = vp + 8 * values.length
            for (v <- values) {
              putU32o(buf, vp, doff.toLong); putU32o(buf, vp + 4, valueSize(f, v, fm).toLong)
              doff += valueSize(f, v, fm); vp += 8
            }
            for (v <- values) { writeValue(buf, vp, f, v, fm); vp += valueSize(f, v, fm) }
          } else {
            for (v <- values) { writeScalar(buf, vp, f, v); vp += slotSize(f) }
          }
        }
      } else if (f.ftype == T_STRING || f.ftype == T_BYTES || f.ftype == T_MESSAGE) {
        if (fieldPresent(f, msg, fm)) {
          putU32o(buf, off, vp.toLong)
          putU32o(buf, off + 4, valueSize(f, values.head, fm).toLong)
          writeValue(buf, vp, f, values.head, fm)
          vp += valueSize(f, values.head, fm)
        }
      } else if (fieldPresent(f, msg, fm)) {
        writeScalar(buf, off, f, values.head)
      }
    }
    for (chunk <- msg.unknown) {
      System.arraycopy(chunk, 0, buf, vp, chunk.length); vp += chunk.length
    }
    buf
  }

  private def readScalar(data: Array[Byte], off: Int, f: FieldM): Any = f.ftype match {
    case T_FLOAT => java.lang.Float.intBitsToFloat(u32(data, off).toInt).toDouble
    case T_FIXED32 => u32(data, off)
    case T_SFIXED32 => u32(data, off).toInt.toLong
    case T_DOUBLE => java.lang.Double.longBitsToDouble(u64(data, off))
    case T_FIXED64 | T_SFIXED64 => u64(data, off)
    case T_BOOL => data(off) != 0
    case T_ENUM | T_INT32 | T_SINT32 => s32(u64(data, off))
    case T_INT64 | T_SINT64 => u64(data, off)
    case T_UINT32 => u64(data, off) & 0xffffffffL
    case _ => u64(data, off)
  }

  private def readValue(data: Array[Byte], off: Int, len: Int, f: FieldM, fm: FileM): Any = {
    if (off + len > data.length) throw fail("struct codec: out of bounds")
    f.ftype match {
      case T_STRING => new String(data.slice(off, off + len), StandardCharsets.UTF_8)
      case T_BYTES => data.slice(off, off + len)
      case T_MESSAGE =>
        if (len == 0) new Generic(null)
        else decodeStruct(fm.messages(f.typeName), data.slice(off, off + len), fm)
      case _ => readScalar(data, off, f)
    }
  }

  private def decodeStruct(model: MsgM, data: Array[Byte], fm: FileM): Generic = {
    val fields = sortedFields(model)
    val words = math.max(1, (fields.length + 31) / 32)
    val header = 12 + 4 * words
    if (data.length < header || new String(data.slice(0, 4), StandardCharsets.US_ASCII) != "DCS1")
      throw fail("struct codec: bad header")
    if (u32(data, 8) != fingerprint(model.fullName)) throw fail("struct codec: schema fingerprint mismatch")
    if (u32(data, 4) != data.length.toLong) throw fail("struct codec: length mismatch")
    val offsets = new Array[Int](fields.length)
    var cursor = header
    for (i <- fields.indices) { offsets(i) = cursor; cursor += slotSize(fields(i)) }
    val msg = new Generic(model)
    var vend = cursor
    for (i <- fields.indices) {
      if ((u32(data, 12 + 4 * (i / 32)) & (1L << (i % 32))) != 0L) {
        val f = fields(i)
        val off = offsets(i)
        val em = mapModel(f, fm)
        if (em != null) {
          val kf = em.fields(1); val vf = em.fields(2)
          val base = u32(data, off).toInt
          val n = u32(data, off + 4).toInt
          var p = base
          var j = 0
          while (j < n) {
            val kl = u32(data, p).toInt; val vl = u32(data, p + 4).toInt; p += 8
            val key = readValue(data, p, kl, kf, fm)
            val v = readValue(data, p + kl, vl, vf, fm)
            val entry = new Generic(em); entry.set(1, key); entry.set(2, v)
            msg.add(f.number, entry)
            p += kl + vl; j += 1
          }
          vend = math.max(vend, p)
        } else if (f.repeated) {
          val base = u32(data, off).toInt
          val n = u32(data, off + 4).toInt
          if (f.ftype == T_STRING || f.ftype == T_BYTES || f.ftype == T_MESSAGE) {
            var j = 0
            while (j < n) {
              val eo = u32(data, base + 8 * j).toInt; val el = u32(data, base + 8 * j + 4).toInt
              if (el > 0 || f.ftype != T_MESSAGE) msg.add(f.number, readValue(data, eo, el, f, fm))
              vend = math.max(vend, eo + el); j += 1
            }
          } else {
            var j = 0
            while (j < n) { msg.add(f.number, readScalar(data, base + j * slotSize(f), f)); j += 1 }
            vend = math.max(vend, base + n * slotSize(f))
          }
        } else if (f.ftype == T_STRING || f.ftype == T_BYTES || f.ftype == T_MESSAGE) {
          val base = u32(data, off).toInt; val len = u32(data, off + 4).toInt
          msg.add(f.number, readValue(data, base, len, f, fm))
          vend = math.max(vend, base + len)
        } else {
          msg.add(f.number, readScalar(data, off, f))
        }
      }
    }
    if (vend < data.length) msg.unknown += data.slice(vend, data.length)
    msg
  }

  private val cache = mutable.HashMap[String, FileM]()

  def transcode(descriptor: Array[Byte], typeName: String, data: Array[Byte], encode: Boolean): Array[Byte] = {
    val key = new String(descriptor, StandardCharsets.ISO_8859_1)
    val fm = cache.getOrElseUpdate(key, parseDescriptorSet(descriptor))
    val model = fm.messages.getOrElse(typeName, fm.messages.getOrElse("." + typeName, null))
    if (model == null) throw fail(s"unknown message type $typeName")
    if (encode) encodeStruct(model, decodeGenericS(model, data, fm), fm)
    else encodeGeneric(model, decodeStruct(model, data, fm), fm)
  }
}
