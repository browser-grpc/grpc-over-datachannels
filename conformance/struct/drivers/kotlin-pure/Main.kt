// Struct corpus driver (kotlin, pure/Wasm engine): the Wasm
// grpcdc.StructDc transcoder against the Go golden, run on the
// JVM through the generated companions.
package shapes

fun hex(b: ByteArray): String = b.joinToString("") { "%02x".format(it.toInt() and 0xff) }
fun unhex(s: String): ByteArray =
    ByteArray(s.length / 2) { ((Character.digit(s[2 * it], 16) shl 4) or Character.digit(s[2 * it + 1], 16)).toByte() }

fun inner(v: String, n: Int = 0): Inner {
    val m = Inner(); m.v = v; m.n = n; return m
}

fun main(args: Array<String>) {
    val goldenHex = args[0]
    val golden = unhex(goldenHex)
    val m = Outer()
    m.inner = inner("x", -3)
    m.hue = Hue.RED
    m.nums = mutableListOf(1, -2, 300)
    m.byName = mutableMapOf("b" to inner("second"), "a" to inner("first", 9))
    m.s = "picked"
    m.blob = byteArrayOf(1, 2, 3)
    m.names = mutableListOf("n1", "n2")
    m.inners = mutableListOf(inner("i1"), inner("i2"), inner("i3"))
    m.byId = mutableMapOf(7 to "seven", 2 to "two")
    m.score = 3.5
    m.ratio = 0.25f
    m.flag = true
    m.stamp = 123456789uL
    m.delta = -77
    val got = OuterStruct.marshal(m)
    if (!got.contentEquals(golden)) {
        println("MARSHAL_MISMATCH\n got ${hex(got)}\nwant $goldenHex")
        kotlin.system.exitProcess(1)
    }
    val back = OuterStruct.unmarshal(golden)
    if (!OuterStruct.marshal(back).contentEquals(golden)) {
        println("ROUNDTRIP_MISMATCH")
        kotlin.system.exitProcess(1)
    }
    val golden2Hex = args[1]
    val golden2 = unhex(golden2Hex)
    val p2 = P2()
    p2.name = "req"
    p2.count = 42
    p2.greeting = "hi"
    p2.enabled = false
    p2.ratio = 2.5
    p2.nums = mutableListOf(5, -6)
    p2.extNote = "note!"
    val got2 = P2Struct.marshal(p2)
    if (!got2.contentEquals(golden2)) {
        println("MARSHAL2_MISMATCH\n got ${hex(got2)}\nwant $golden2Hex")
        kotlin.system.exitProcess(1)
    }
    val back2 = P2Struct.unmarshal(golden2)
    if (!P2Struct.marshal(back2).contentEquals(golden2)) {
        println("ROUNDTRIP2_MISMATCH")
        kotlin.system.exitProcess(1)
    }
    println("DECODE_OK")
}
