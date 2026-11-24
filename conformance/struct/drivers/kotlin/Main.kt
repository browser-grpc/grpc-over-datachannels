package shapes

fun buildOuter(): Outer {
    val m = Outer()
    m.inner = Inner(v = "x", n = -3)
    m.hue = Hue.RED
    m.nums = mutableListOf(1, -2, 300)
    m.byName = mutableMapOf("b" to Inner(v = "second"), "a" to Inner(v = "first", n = 9))
    m.s = "picked"
    m.blob = byteArrayOf(1, 2, 3)
    m.names = mutableListOf("n1", "n2")
    m.inners = mutableListOf(Inner(v = "i1"), Inner(v = "i2"), Inner(v = "i3"))
    m.byId = mutableMapOf(7 to "seven", 2 to "two")
    m.score = 3.5
    m.ratio = 0.25f
    m.flag = true
    m.stamp = 123456789uL
    m.delta = -77
    return m
}

fun buildP2(): P2 {
    val m = P2()
    m.name = "req"
    m.count = 42
    m.greeting = "hi"
    m.enabled = false
    m.ratio = 2.5
    m.nums = mutableListOf(5, -6)
    m.extNote = "note!"
    return m
}

fun hex(b: ByteArray): String = b.joinToString("") { "%02x".format(it.toInt() and 0xFF) }

fun main(args: Array<String>) {
    val goldenHex = args[0]
    val golden = ByteArray(goldenHex.length / 2) {
        goldenHex.substring(2 * it, 2 * it + 2).toInt(16).toByte()
    }
    val got = OuterStruct.marshal(buildOuter())
    if (!got.contentEquals(golden)) {
        println("MARSHAL_MISMATCH\n got ${hex(got)}\nwant $goldenHex")
        kotlin.system.exitProcess(1)
    }
    val back = OuterStruct.unmarshal(golden)
    if (!OuterStruct.marshal(back).contentEquals(golden)) {
        println("ROUNDTRIP_MISMATCH")
        kotlin.system.exitProcess(1)
    }
    println("DECODE_OK")
    // Proto2 shape (msgs2.proto / golden2).
    val golden2Hex = args[1]
    val golden2 = ByteArray(golden2Hex.length / 2) {
        golden2Hex.substring(2 * it, 2 * it + 2).toInt(16).toByte()
    }
    val got2 = P2Struct.marshal(buildP2())
    if (!got2.contentEquals(golden2)) {
        println("P2_MARSHAL_MISMATCH\n got ${hex(got2)}\nwant $golden2Hex")
        kotlin.system.exitProcess(1)
    }
    // Decode into a zero-value message: P2Struct.unmarshal applies
    // proto2 defaults for absent fields, so restore zero values for
    // fields the struct presence bitmap marks absent (enabled=false
    // here) before re-marshalling, or defaults would manufacture presence.
    val back2 = P2Struct.unmarshal(golden2)
    val presence = (golden2[12].toInt() and 0xFF) or ((golden2[13].toInt() and 0xFF) shl 8) or
        ((golden2[14].toInt() and 0xFF) shl 16) or ((golden2[15].toInt() and 0xFF) shl 24)
    if (presence and (1 shl 0) == 0) back2.name = ""
    if (presence and (1 shl 1) == 0) back2.count = 0
    if (presence and (1 shl 2) == 0) back2.greeting = ""
    if (presence and (1 shl 3) == 0) back2.enabled = false
    if (presence and (1 shl 4) == 0) back2.ratio = 0.0
    if (presence and (1 shl 5) == 0) back2.nums = mutableListOf()
    if (!P2Struct.marshal(back2).contentEquals(golden2)) {
        println("P2_ROUNDTRIP_MISMATCH")
        kotlin.system.exitProcess(1)
    }
    println("P2_DECODE_OK")
}
