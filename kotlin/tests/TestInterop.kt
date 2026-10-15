package tests

import echo.EchoGrpcDc
import echo.EchoRequest
import echo.StdioTransport
import grpcdc.Channel
import grpcdc.StatusException
import java.io.EOFException
import java.io.File
import java.util.concurrent.TimeUnit

private fun buildGo(root: String, output: String, pkg: String): Boolean {
    val proc = ProcessBuilder("go", "build", "-o", output, pkg)
        .directory(File(root, "go"))
        .redirectOutput(ProcessBuilder.Redirect.DISCARD)
        .redirectError(ProcessBuilder.Redirect.DISCARD)
        .start()
    return proc.waitFor(120, TimeUnit.SECONDS) && proc.exitValue() == 0
}

/** Pump raw bytes between two streams until EOF (raw IO: buffered
 * readNBytes-style reads block trying to fill the whole buffer). */
private fun pump(from: java.io.InputStream, to: java.io.OutputStream) {
    val buf = ByteArray(65536)
    while (true) {
        val n = from.read(buf, 0, buf.size)
        if (n < 0) {
            break
        }
        to.write(buf, 0, n)
        to.flush()
    }
}

/**
 * Interop: the Kotlin runtime against the Go stdio harnesses (cross-
 * language wire compatibility). Skips when Go is unavailable.
 * Mirrors python/tests/test_interop.py.
 */
fun testInterop() {
    val root = root()
    val tmp = "/tmp/grpcdc_kotlin_interop"
    File(tmp).mkdirs()
    val serverBin = "$tmp/echo_server_stdio"
    if (!buildGo(root, serverBin, "./examples/echo_server_stdio")) {
        println("TestInterop SKIP (no go)")
        return
    }

    val server = ProcessBuilder(serverBin)
        .redirectInput(ProcessBuilder.Redirect.PIPE)
        .redirectOutput(ProcessBuilder.Redirect.PIPE)
        .redirectError(ProcessBuilder.Redirect.INHERIT)
        .start()
    try {
        val transport = StdioTransport(server.outputStream, server.inputStream)
        val client = EchoGrpcDc.EchoClient(Channel(transport))

        val unary = client.Unary(EchoRequest("hello", 0))
        check(unary.message == "echo: hello", "unary: $unary")

        val stream = client.ServerStream(EchoRequest("tick", 3))
        val indexes = ArrayList<Int>()
        while (true) {
            try {
                indexes.add(stream.recv().index)
            } catch (e: EOFException) {
                break
            }
        }
        check(indexes == listOf(0, 1, 2), "server stream: $indexes")

        val joined = client.ClientStream(listOf(EchoRequest("a", 0), EchoRequest("b", 0), EchoRequest("c", 0)))
        check(joined.message == "a+b+c", "client stream: $joined")

        val bidi = client.Bidi(listOf(EchoRequest("x", 0), EchoRequest("y", 0)))
        val echoed = ArrayList<String>()
        while (true) {
            try {
                echoed.add(bidi.recv().message)
            } catch (e: EOFException) {
                break
            }
        }
        check(echoed == listOf("x", "y"), "bidi: $echoed")

        try {
            client.Unary(EchoRequest("fail", 0))
            check(false, "fail should throw")
        } catch (e: StatusException) {
            check(e.code == 3, "fail status: $e")
        }
    } finally {
        kill(server)
    }

    // Reverse: Go client harness against the Kotlin stdio server.
    val clientBin = "$tmp/echo_client_stdio"
    if (!buildGo(root, clientBin, "./examples/echo_client_stdio")) {
        println("TestInterop partial SKIP (client build)")
        return
    }
    val kotlinServer = "$root/kotlin/build/echo_server_stdio.jar"
    if (!File(kotlinServer).exists()) {
        println("TestInterop partial SKIP (kotlin server not built)")
        return
    }
    val kotlin = ProcessBuilder("java", "-jar", kotlinServer)
        .redirectInput(ProcessBuilder.Redirect.PIPE)
        .redirectOutput(ProcessBuilder.Redirect.PIPE)
        .redirectError(ProcessBuilder.Redirect.INHERIT)
        .start()
    val goClient = ProcessBuilder(clientBin)
        .redirectInput(ProcessBuilder.Redirect.PIPE)
        .redirectOutput(ProcessBuilder.Redirect.PIPE)
        .redirectError(ProcessBuilder.Redirect.PIPE)
        .start()
    try {
        val pumpA = Thread { pump(goClient.inputStream, kotlin.outputStream) }
        val pumpB = Thread { pump(kotlin.inputStream, goClient.outputStream) }
        pumpA.isDaemon = true
        pumpB.isDaemon = true
        pumpA.start()
        pumpB.start()
        val finished = goClient.waitFor(60, TimeUnit.SECONDS)
        check(finished && goClient.exitValue() == 0, "go client harness exit")
        kill(kotlin)
        pumpA.join(10000)
        pumpB.join(10000)
        val stderrText = readAll(goClient.errorStream)
        check(stderrText.contains("unary=echo: hello"), "go client unary: $stderrText")
        check(stderrText.contains("server_stream=tick#0,tick#1,tick#2"), "go client stream: $stderrText")
        check(stderrText.contains("client_stream=a+b+c"), "go client client-stream: $stderrText")
        check(stderrText.contains("bidi=x,y"), "go client bidi: $stderrText")
    } finally {
        kill(kotlin)
        kill(goClient)
    }
    println("TestInterop OK")
}
