package tests

import java.io.File

/**
 * Generated Kotlin message types (<Base>Messages.kt) from the
 * native protoc-gen-grpc-dc-kotlin plugin: kitchen-sink
 * round-trip plus a protoc oracle — protoc's own --encode bytes
 * must decode to the same message and re-encode identically.
 */
fun testPbMessages() {
    val kitchenText = """
        d: 1.5 f: 2.5 i32: -3 i64: -4 u32: 5 u64: 6 s32: -7 s64: -8
        f32: 9 f64: 10 sf32: -11 sf64: -12 flag: true name: "sink"
        blob: "\x01\x02\x03" color: GREEN
        nested { note: "n" level: 3 }
        item { sku: "abc" quantity: 2 }
        nums: [1, -2, 300] words: ["a", "", "bc"]
        manys { note: "m" level: 1 }
        vals: [0.5, -1.25]
        counts { key: "x" value: 1 } counts { key: "y" value: -2 }
        by_id { key: 7 value { note: "z" level: 9 } }
        text: "chosen" big_negative: -9007199254740993 neg32: -123456
        """.trimIndent()

    val harness = """
        import java.io.File
        import kitchen.v1.Color
        import kitchen.v1.Kitchen
        import kitchen.v1.Nested
        import shop.common.Item

        fun fail(msg: String): Nothing {
            System.err.println("FAIL: " + msg)
            kotlin.system.exitProcess(1)
        }

        fun make(): Kitchen {
            val k = Kitchen()
            k.d = 1.5; k.f = 2.5f; k.i32 = -3; k.i64 = -4; k.u32 = 5u; k.u64 = 6uL
            k.s32 = -7; k.s64 = -8; k.f32 = 9u; k.f64 = 10uL; k.sf32 = -11; k.sf64 = -12
            k.flag = true; k.name = "sink"; k.blob = byteArrayOf(1, 2, 3); k.color = Color.GREEN
            val nested = Nested(); nested.note = "n"; nested.level = 3
            k.nested = nested
            val item = Item(); item.sku = "abc"; item.quantity = 2
            k.item = item
            k.nums = mutableListOf(1, -2, 300)
            k.words = mutableListOf("a", "", "bc")
            val m = Nested(); m.note = "m"; m.level = 1
            k.manys = mutableListOf(m)
            k.vals = mutableListOf(0.5, -1.25)
            k.counts = mutableMapOf("x" to 1, "y" to -2)
            val z = Nested(); z.note = "z"; z.level = 9
            k.byId = mutableMapOf(7L to z)
            k.text = "chosen"; k.bigNegative = -9007199254740993L; k.neg32 = -123456
            return k
        }

        fun checkSame(a: Kitchen, b: Kitchen) {
            val ok = a.d == b.d && a.f == b.f && a.i32 == b.i32 && a.i64 == b.i64
                && a.u32 == b.u32 && a.u64 == b.u64 && a.s32 == b.s32 && a.s64 == b.s64
                && a.f32 == b.f32 && a.f64 == b.f64 && a.sf32 == b.sf32 && a.sf64 == b.sf64
                && a.flag == b.flag && a.name == b.name && a.blob.contentEquals(b.blob) && a.color == b.color
                && a.nested?.note == b.nested?.note && a.nested?.level == b.nested?.level
                && a.item?.sku == b.item?.sku && a.item?.quantity == b.item?.quantity
                && a.nums == b.nums && a.words == b.words
                && a.manys.size == b.manys.size && a.manys[0].note == b.manys[0].note
                && a.vals == b.vals && a.counts == b.counts
                && a.byId[7]?.note == b.byId[7]?.note
                && a.text == b.text && a.bigNegative == b.bigNegative && a.neg32 == b.neg32
            if (!ok) fail("mismatch")
        }

        fun main(args: Array<String>) {
            val k = make()
            if (args[0] == "roundtrip") {
                val back = Kitchen()
                back.unmarshalDc(k.marshalDc())
                checkSame(back, k)
                if (Kitchen().marshalDc().isNotEmpty()) fail("empty must encode empty")
                val both = Kitchen()
                both.text = "a"; both.code = 7
                val bothBack = Kitchen()
                bothBack.unmarshalDc(both.marshalDc())
                if (bothBack.text != "" || bothBack.code != 7) fail("oneof encode clearing")
                println("roundtrip OK")
                return
            }
            val bytes = File(args[1]).readBytes()
            val from = Kitchen()
            from.unmarshalDc(bytes)
            checkSame(from, k)
            val again = Kitchen()
            again.unmarshalDc(from.marshalDc())
            checkSame(again, from)
            println("oracle OK")
        }
        """.trimIndent()

    fun run(cmd: List<String>, cwd: File, stdin: String? = null): String {
        val pb = ProcessBuilder(cmd).directory(cwd).redirectErrorStream(true)
        val p = pb.start()
        if (stdin != null) {
            p.outputStream.write(stdin.toByteArray())
            p.outputStream.close()
        } else {
            p.outputStream.close()
        }
        val out = p.inputStream.readAllBytes().decodeToString()
        val code = p.waitFor()
        check(code == 0 && !out.contains("FAIL")) { "command failed $cmd: $out" }
        return out
    }

    var root = File("..")
    if (!File(root, "webapp/testdata/kitchen.proto").exists()) {
        root = File(".")
    }
    val rootAbs = root.canonicalFile
    val testdata = File(rootAbs, "webapp/testdata")
    val tmp = File(System.getProperty("java.io.tmpdir"), "grpcdc-kt-pb-" + System.nanoTime())
    val gen = File(tmp, "gen")
    check(gen.mkdirs()) { "mkdir gen" }
    run(listOf("protoc",
        "--plugin=protoc-gen-grpc-dc-kotlin=" + File(rootAbs, "bin/protoc-gen-grpc-dc-kotlin"),
        "--grpc-dc-kotlin_out=" + gen,
        "-I", testdata.toString(), "common.proto", "kitchen.proto"), testdata)
    File(gen, "CommonGrpcDc.kt").delete()
    File(gen, "KitchenGrpcDc.kt").delete()
    File(gen, "Main.kt").writeText(harness)
    val grpcdc = File(rootAbs, "kotlin/grpcdc").listFiles { f -> f.extension == "kt" }!!
        .map { it.toString() }.sorted()
    val cmd = mutableListOf("kotlinc", "-include-runtime", "-d", File(tmp, "harness.jar").toString())
    cmd += grpcdc
    cmd += listOf(File(gen, "CommonMessages.kt").toString(), File(gen, "KitchenMessages.kt").toString(),
        File(gen, "Main.kt").toString())
    run(cmd, tmp)
    val out1 = run(listOf("java", "-jar", File(tmp, "harness.jar").toString(), "roundtrip"), tmp)
    check(out1.contains("roundtrip OK")) { "roundtrip: $out1" }
    val bin = File(tmp, "protoc.bin")
    val enc = ProcessBuilder("protoc", "--encode=kitchen.v1.Kitchen",
        "-I", testdata.toString(), "kitchen.proto").directory(testdata).start()
    enc.outputStream.write(kitchenText.toByteArray())
    enc.outputStream.close()
    val bytes = enc.inputStream.readAllBytes()
    check(enc.waitFor() == 0) { "protoc encode" }
    bin.writeBytes(bytes)
    val out2 = run(listOf("java", "-jar", File(tmp, "harness.jar").toString(), "oracle", bin.toString()), tmp)
    check(out2.contains("oracle OK")) { "oracle: $out2" }
    println("TestPbMessages OK")
}
