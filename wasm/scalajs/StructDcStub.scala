package grpcdc

/** Scala.js stand-in for the JNI-backed StructDc: the struct codec is unavailable on JS. */
object StructDc {
  def encode(descriptor: Array[Byte], typeName: String, pb: Array[Byte]): Array[Byte] =
    throw new UnsupportedOperationException("struct codec unavailable on Scala.js")

  def decode(descriptor: Array[Byte], typeName: String, data: Array[Byte]): Array[Byte] =
    throw new UnsupportedOperationException("struct codec unavailable on Scala.js")
}
