package tests

import java.io.BufferedReader
import java.io.File
import java.io.InputStreamReader
import java.nio.charset.StandardCharsets
import java.util.concurrent.TimeUnit

/**
 * Interop oracle, Direction B: the OFFICIAL interop clients
 * (grpc-java TestServiceClient, grpc-go interop-client) run the
 * canonical cases against the generated Kotlin TestService
 * server (examples/InteropServerStdio), reached over HTTP/2
 * through oracle/bridge.mjs http2-to-dc. Skips when an oracle
 * binary or Node is unavailable. Mirrors
 * java/tests/TestInteropServerOracle.java.
 */
private val INTEROP_B_CASES = listOf(
    "empty_unary",
    "large_unary",
    "client_streaming",
    "server_streaming",
    "ping_pong",
    "empty_stream",
    "custom_metadata",
    "status_code_and_message",
    "special_status_message",
    "unimplemented_method",
    "unimplemented_service",
    "cancel_after_begin",
    "cancel_after_first_response",
    "timeout_on_sleeping_server")

private val INTEROP_B_JAVA_ONLY = listOf(
    "cacheable_unary",
    "client_compressed_unary",
    "client_compressed_streaming",
    "server_compressed_unary",
    "server_compressed_streaming")

private val INTEROP_B_GO_ONLY = listOf("orca_per_rpc", "orca_oob")

private fun runClientB(argv: List<String>): String {
    val proc = ProcessBuilder(argv).redirectErrorStream(true).start()
    val out = StringBuilder()
    val drain = Thread {
        try {
            BufferedReader(InputStreamReader(proc.inputStream, StandardCharsets.UTF_8)).use { reader ->
                while (true) {
                    val line = reader.readLine() ?: break
                    synchronized(out) { out.append(line).append('\n') }
                }
            }
        } catch (e: Exception) {
            // process gone
        }
    }
    drain.isDaemon = true
    drain.start()
    if (!proc.waitFor(120, TimeUnit.SECONDS)) {
        proc.destroyForcibly()
        throw AssertionError("client timed out: $argv")
    }
    drain.join(5000)
    check(proc.exitValue() == 0) { "client exit ${proc.exitValue()}: $argv\n$out" }
    return synchronized(out) { out.toString() }
}

fun testInteropServerOracle() {
    val rootPath = root()
    val cp = javaClasspath(rootPath)
    if (cp == null) {
        println("TestInteropServerOracle SKIP (oracle not built)")
        return
    }
    val serverJar = File("$rootPath/kotlin/build/interop_server_stdio.jar")
    if (!serverJar.exists()) {
        println("TestInteropServerOracle SKIP (kotlin server not built)")
        return
    }
    val port = freePort()
    val bridge = ProcessBuilder(
        "node", "$rootPath/oracle/bridge.mjs", "http2-to-dc",
        "--port", port.toString(),
        "--target-cmd", "java -jar ${serverJar.path}")
        .redirectError(ProcessBuilder.Redirect.PIPE).start()
    try {
        if (!waitReady(bufferedReader(bridge), "listening")) {
            println("TestInteropServerOracle SKIP (bridge did not start)")
            return
        }
        for (testCase in INTEROP_B_CASES + INTEROP_B_JAVA_ONLY) {
            val out = runClientB(listOf(
                "java", "-cp", cp, "io.grpc.testing.integration.TestServiceClient",
                "--server_host=127.0.0.1", "--server_port=$port",
                "--test_case=$testCase", "--use_tls=false"))
            check(out.contains("Test completed.")) { "java case $testCase: unexpected output: $out" }
            println("interop B case ok: $testCase (java client)")
        }
        val goClient = File("$rootPath/oracle/go-interop/interop-client")
        if (!goClient.exists()) {
            println("TestInteropServerOracle GO SKIP (go client not built)")
        } else {
            for (testCase in INTEROP_B_CASES + INTEROP_B_GO_ONLY) {
                val argv = mutableListOf(
                    goClient.path,
                    "-server_host", "127.0.0.1",
                    "-server_port", port.toString(),
                    "-test_case", testCase)
                if (testCase.startsWith("orca")) {
                    argv.add("-service_config_json")
                    argv.add("{ \"loadBalancingConfig\": [{ \"test_backend_metrics_load_balancer\": {} }]}")
                }
                runClientB(argv)
                println("interop B case ok: $testCase (go client)")
            }
        }
    } finally {
        kill(bridge)
    }
    println("TestInteropServerOracle OK")
}
