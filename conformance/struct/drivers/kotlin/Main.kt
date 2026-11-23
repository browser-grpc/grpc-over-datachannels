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
}
