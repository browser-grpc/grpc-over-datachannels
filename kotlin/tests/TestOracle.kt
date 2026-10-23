package tests

import echo.EchoGrpcDc
import echo.StdioTransport
import grpcdc.Channel
import java.io.File
import java.util.concurrent.TimeUnit

/**
 * Oracle: official grpc-java, bridged over TCP<->DataChannel by
 * oracle/bridge.mjs, must agree with the Kotlin runtime on every
 * case of the generated scenario driver. Skips when the Java oracle
 * or Node bridge are unavailable (Dockerfile.ci provides both).
 */
fun testOracle() {
    val root = root()
    val cp = javaClasspath(root)
    if (cp == null) {
        println("TestOracle SKIP (java oracle not built)")
        return
    }

    // Direction A: this client -> bridge -> official server.
    val port = freePort()
    val server = ProcessBuilder("java", "-cp", cp, "dc.oracle.OracleServer", port.toString())
        .redirectOutput(ProcessBuilder.Redirect.PIPE)
        .start()
    try {
        if (!waitReady(bufferedReader(server), "READY")) {
            println("TestOracle SKIP (oracle server did not start)")
            return
        }
        val bridge = ProcessBuilder("node", "$root/oracle/bridge.mjs", "dc-to-http2", "--grpc", "127.0.0.1:$port")
            .redirectInput(ProcessBuilder.Redirect.PIPE)
            .redirectOutput(ProcessBuilder.Redirect.PIPE)
            .redirectError(ProcessBuilder.Redirect.INHERIT)
            .start()
        try {
            val transport = StdioTransport(bridge.outputStream, bridge.inputStream)
            val client = EchoGrpcDc.EchoClient(Channel(transport))
            runScenarios(client)
        } finally {
            kill(bridge)
        }
    } finally {
        kill(server)
    }

    // Direction B: official client -> bridge -> this runtime's server.
    val serverCmd = "java -jar $root/kotlin/build/echo_server_stdio.jar"
    if (!File(serverCmd.substringAfter("java -jar ")).exists()) {
        println("TestOracle SKIP (kotlin server not built)")
        return
    }
    val portB = freePort()
    val bridge = ProcessBuilder(
        "node", "$root/oracle/bridge.mjs", "http2-to-dc", "--port", portB.toString(),
        "--target-cmd", serverCmd
    ).redirectError(ProcessBuilder.Redirect.PIPE).start()
    try {
        if (!waitReady(bufferedReader(bridge), "listening")) {
            println("TestOracle SKIP (bridge did not start)")
            return
        }
        val client = ProcessBuilder(
            "java", "-cp", cp, "dc.oracle.OracleClient", portB.toString(),
            "$root/fixtures/oracle_scenarios.txt"
        ).redirectOutput(ProcessBuilder.Redirect.PIPE).redirectError(ProcessBuilder.Redirect.PIPE).start()
        val output = readAll(client.inputStream)
        val errOutput = readAll(client.errorStream)
        val finished = client.waitFor(120, TimeUnit.SECONDS)
        check(finished, "oracle client timed out")
        check(client.exitValue() == 0, "oracle client failed:\n$output$errOutput")
        check(output.contains("ORACLE CLIENT: ALL OK"), "oracle client output:\n$output$errOutput")
        kill(client)
    } finally {
        kill(bridge)
    }
    println("TestOracle OK")
}
