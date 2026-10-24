package tests

import java.io.File

/// BDD schema scenarios: golden protoc bytes, generated classes.
/// The case table (BDD_SCHEMAS in BddSchemas.kt, generated from
/// the schema scenarios) carries protoc's own --encode output
/// over webapp/testdata/{kitchen,features}.proto. Each case
/// decodes with the generated classes and re-encodes
/// byte-identically. The generated-classes harness mirrors
/// TestPbMessages.
fun testBddSchemas() {
    fun run(cmd: List<String>, cwd: File): String {
        val pb = ProcessBuilder(cmd).directory(cwd).redirectErrorStream(true)
        val p = pb.start()
        p.outputStream.close()
        val out = p.inputStream.readAllBytes().decodeToString()
        val code = p.waitFor()
        check(code == 0 && !out.contains("FAIL")) { "command failed $cmd: $out" }
        return out
    }

    var root = File("..").canonicalFile
    if (!File(root, "webapp/testdata/kitchen.proto").exists()) {
        root = File(".").canonicalFile
    }
    val rootAbs = root.absoluteFile

    val rows = BDD_SCHEMAS.joinToString("\n") {
        "        arrayOf(\"${it.name}\", \"${it.message}\", \"${it.input}\", \"${it.expect}\"),"
    }
    val harness = """
        import kitchen.v1.Kitchen
        import feat.v1.Outer

        fun unhex(s: String): ByteArray {
            val out = ByteArray(s.length / 2)
            for (i in out.indices) {
                out[i] = s.substring(i * 2, i * 2 + 2).toInt(16).toByte()
            }
            return out
        }

        fun main() {
            val cases = arrayOf(
        $rows
            )
            for (c in cases) {
                val input = unhex(c[2])
                val got = when (c[1]) {
                    "kitchen" -> {
                        val m = Kitchen()
                        m.unmarshalDc(input)
                        m.marshalDc()
                    }
                    "outer" -> {
                        val m = Outer()
                        m.unmarshalDc(input)
                        m.marshalDc()
                    }
                    else -> {
                        System.err.println("FAIL: unknown message " + c[1])
                        kotlin.system.exitProcess(1)
                    }
                }
                val hex = got.joinToString("") { "%02x".format(it.toInt() and 0xFF) }
                if (hex != c[3]) {
                    System.err.println("FAIL: re-encode mismatch: " + c[0])
                    kotlin.system.exitProcess(1)
                }
            }
            println("schemas OK")
        }
        """.trimIndent()

    val tmp = kotlin.io.path.createTempDirectory("grpcdc-kotlin-schemas-").toFile()
    val gen = File(tmp, "gen").apply { mkdirs() }
    val testdata = File(rootAbs, "webapp/testdata")
    run(listOf("protoc",
        "--plugin=protoc-gen-grpc-dc-kotlin=" + File(rootAbs, "bin/protoc-gen-grpc-dc-kotlin"),
        "--grpc-dc-kotlin_out=" + gen,
        "-I", testdata.toString(), "common.proto", "kitchen.proto", "features.proto"), testdata)
    File(gen, "CommonGrpcDc.kt").delete()
    File(gen, "KitchenGrpcDc.kt").delete()
    File(gen, "FeaturesGrpcDc.kt").delete()
    File(gen, "Main.kt").writeText(harness)
    val grpcdc = File(rootAbs, "kotlin/grpcdc").listFiles { f -> f.extension == "kt" }!!
        .map { it.toString() }.sorted()
    val cmd = mutableListOf("kotlinc", "-include-runtime", "-d", File(tmp, "harness.jar").toString())
    cmd += grpcdc
    cmd += listOf(
        File(gen, "CommonMessages.kt").toString(),
        File(gen, "KitchenMessages.kt").toString(),
        File(gen, "FeaturesMessages.kt").toString(),
        File(gen, "Main.kt").toString())
    run(cmd, tmp)
    val out = run(listOf("java", "-jar", File(tmp, "harness.jar").toString()), tmp)
    check(out.contains("schemas OK")) { "schemas: $out" }
    println("TestBddSchemas OK")
}
