package shapes

object StructDriver {
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

  def buildP2(): P2 = {
    val m = new P2()
    m.name = "req"
    m.count = 42
    m.greeting = "hi"
    m.enabled = false
    m.ratio = 2.5
    m.nums = List(5, -6)
    m.extNote = "note!"
    m
  }

  def hex(b: Array[Byte]): String = b.map(x => "%02x".format(x & 0xFF)).mkString

  def main(args: Array[String]): Unit = {
    val goldenHex = args(0)
    val golden = goldenHex.grouped(2).map(Integer.parseInt(_, 16).toByte).toArray
    val got = OuterStruct.marshal(buildOuter())
    if (!got.sameElements(golden)) {
      println("MARSHAL_MISMATCH\n got " + hex(got) + "\nwant " + goldenHex)
      sys.exit(1)
    }
    val back = OuterStruct.unmarshal(golden)
    if (!OuterStruct.marshal(back).sameElements(golden)) {
      println("ROUNDTRIP_MISMATCH")
      sys.exit(1)
    }
    println("DECODE_OK")
    // Proto2 shape (msgs2.proto / golden2).
    val golden2Hex = args(1)
    val golden2 = golden2Hex.grouped(2).map(Integer.parseInt(_, 16).toByte).toArray
    val got2 = P2Struct.marshal(buildP2())
    if (!got2.sameElements(golden2)) {
      println("P2_MARSHAL_MISMATCH\n got " + hex(got2) + "\nwant " + golden2Hex)
      sys.exit(1)
    }
    // Decode into a zero-value message: P2Struct.unmarshal applies
    // proto2 defaults for absent fields, so restore zero values for
    // fields the struct presence bitmap marks absent (enabled=false
    // here) before re-marshalling, or defaults would manufacture presence.
    val back2 = P2Struct.unmarshal(golden2)
    val presence = (golden2(12) & 0xFF) | ((golden2(13) & 0xFF) << 8) |
      ((golden2(14) & 0xFF) << 16) | ((golden2(15) & 0xFF) << 24)
    if ((presence & (1 << 0)) == 0) back2.name = ""
    if ((presence & (1 << 1)) == 0) back2.count = 0
    if ((presence & (1 << 2)) == 0) back2.greeting = ""
    if ((presence & (1 << 3)) == 0) back2.enabled = false
    if ((presence & (1 << 4)) == 0) back2.ratio = 0.0
    if ((presence & (1 << 5)) == 0) back2.nums = List.empty
    if (!P2Struct.marshal(back2).sameElements(golden2)) {
      println("P2_ROUNDTRIP_MISMATCH")
      sys.exit(1)
    }
    println("P2_DECODE_OK")
  }
}
