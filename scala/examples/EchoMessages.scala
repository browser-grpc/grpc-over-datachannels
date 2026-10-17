package echo

import grpcdc.{Marshaler, Unmarshaler}

/**
 * Hand-written protobuf messages for proto/echo.proto (package echo).
 *
 * Deliberately minimal (two messages) so the example needs no
 * protobuf codegen dependency — the wire bytes are genuine protobuf:
 * EchoRequest{message:"hi", count:2} encodes to 0a0268691002.
 * Mirrors kotlin/examples/EchoMessages.kt.
 */
class EchoRequest(
    var message: String = "",
    var count: Int = 0,
    var delayMs: Int = 0) extends Marshaler with Unmarshaler {
  def marshalDc(): Array[Byte] = {
    val w = new Pb.Writer()
    w.stringField(1, message)
    w.int32Field(2, count)
    w.int32Field(3, delayMs)
    w.toBytes
  }

  def unmarshalDc(data: Array[Byte]): Unit = {
    message = ""
    count = 0
    delayMs = 0
    val r = new Pb.Reader(data)
    var field = r.next()
    while (field != null) {
      field.number match {
        case 1 => message = field.asString
        case 2 => count = field.asInt32
        case 3 => delayMs = field.asInt32
        case _ => () // skip unknown fields
      }
      field = r.next()
    }
  }

  override def toString: String = s"EchoRequest{message=$message, count=$count, delayMs=$delayMs}"
}

class EchoResponse(
    var message: String = "",
    var index: Int = 0) extends Marshaler with Unmarshaler {
  def marshalDc(): Array[Byte] = {
    val w = new Pb.Writer()
    w.stringField(1, message)
    w.int32Field(2, index)
    w.toBytes
  }

  def unmarshalDc(data: Array[Byte]): Unit = {
    message = ""
    index = 0
    val r = new Pb.Reader(data)
    var field = r.next()
    while (field != null) {
      field.number match {
        case 1 => message = field.asString
        case 2 => index = field.asInt32
        case _ => () // skip unknown fields
      }
      field = r.next()
    }
  }

  override def toString: String = s"EchoResponse{message=$message, index=$index}"
}
