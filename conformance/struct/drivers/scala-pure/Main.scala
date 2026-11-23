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
    val golden2Hex = args(2)
    val golden2 = unhex(golden2Hex)
    val descriptor2 = unhex(args(3))
    val p2 = new P2()
    p2.name = "req"
    p2.count = 42
    p2.greeting = "hi"
    p2.enabled = false
    p2.ratio = 2.5
    p2.nums = List(5, -6)
    p2.extNote = "note!"
    val got2 = grpcdc.StructDc.encode(descriptor2, "shapes.P2", p2.marshalDc())
    if (!got2.sameElements(golden2)) {
      println("MARSHAL2_MISMATCH\n got " + hex(got2) + "\nwant " + golden2Hex)
      sys.exit(1)
    }
    val back2Pb = grpcdc.StructDc.decode(descriptor2, "shapes.P2", golden2)
    val back2 = new P2(); back2.unmarshalDc(back2Pb)
    val re2 = grpcdc.StructDc.encode(descriptor2, "shapes.P2", back2.marshalDc())
    if (!re2.sameElements(golden2)) {
      println("ROUNDTRIP2_MISMATCH")
      sys.exit(1)
    }
    println("DECODE_OK")
  }
}
