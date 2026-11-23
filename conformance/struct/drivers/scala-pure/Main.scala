package shapes

// Struct corpus driver (scala, pure/JS engine): the Scala.js
// StructDc transcoder (wasm/scalajs/StructDcStub.scala) against
// the Go golden, run on the JVM. args: goldenHex descriptorHex.
object StructDriverPure {
  def buildOuter(): Outer = {
    val m = new Outer()
    val i0 = new Inner(); i0.v = "x"; i0.n = -3
    m.inner = i0
    m.hue = Hue.RED
    m.nums = List(1, -2, 300)
    val b1 = new Inner(); b1.v = "second"
    val b2 = new Inner(); b2.v = "first"; b2.n = 9
    m.byName = Map("b" -> b1, "a" -> b2)
    m.s = "picked"
    m.blob = Array[Byte](1, 2, 3)
    m.names = List("n1", "n2")
    m.inners = List({ val e = new Inner(); e.v = "i1"; e },
                    { val e = new Inner(); e.v = "i2"; e },
                    { val e = new Inner(); e.v = "i3"; e })
    m.byId = Map(7 -> "seven", 2 -> "two")
    m.score = 3.5
    m.ratio = 0.25f
    m.flag = true
    m.stamp = 123456789L
    m.delta = -77
    m
  }

  def hex(b: Array[Byte]): String = b.map(x => "%02x".format(x & 0xFF)).mkString
  def unhex(s: String): Array[Byte] = s.grouped(2).map(Integer.parseInt(_, 16).toByte).toArray

  def main(args: Array[String]): Unit = {
    val goldenHex = args(0)
    val golden = unhex(goldenHex)
    val descriptor = unhex(args(1))
    val got = grpcdc.StructDc.encode(descriptor, "shapes.Outer", buildOuter().marshalDc())
    if (!got.sameElements(golden)) {
      println("MARSHAL_MISMATCH\n got " + hex(got) + "\nwant " + goldenHex)
      sys.exit(1)
    }
    val backPb = grpcdc.StructDc.decode(descriptor, "shapes.Outer", golden)
    val back = new Outer(); back.unmarshalDc(backPb)
    val re = grpcdc.StructDc.encode(descriptor, "shapes.Outer", back.marshalDc())
    if (!re.sameElements(golden)) {
      println("ROUNDTRIP_MISMATCH")
      sys.exit(1)
    }
    println("DECODE_OK")
  }
}
