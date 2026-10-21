package tests

import echo.EchoGrpcDc
import echo.EchoRequest
import echo.EchoServiceImpl
import grpcdc.Channel
import grpcdc.Server
import grpcdc.SidecarTransport
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.ServerSocket
import java.nio.file.Files
import java.nio.file.Path

// gRPC over WebRTC-Direct via the Rust sidecar, Kotlin to
// Kotlin: two direct_sidecar processes own the WebRTC stack;
// the Kotlin server and client only speak length-prefixed TCP
// to their local sidecar (grpcdc.SidecarTransport).

private fun sidecarBin(): String {
    val root = listOf(Path.of("."), Path.of("..")).first { Files.exists(it.resolve("webrtc/rust/Cargo.toml")) }.toAbsolutePath().normalize()
    val bin = root.resolve("webrtc/rust/target/debug/examples/direct_sidecar")
    if (!Files.isExecutable(bin)) {
        val build = ProcessBuilder("cargo", "build", "--example", "direct_sidecar")
            .directory(root.resolve("webrtc/rust").toFile())
            .inheritIO()
            .start()
        check(build.waitFor() == 0) { "cargo build direct_sidecar" }
    }
    return bin.toString()
}

private fun sidecarFreePort(): Int = ServerSocket(0).use { it.localPort }

private fun readLine(process: Process, needle: String): String {
    val reader = BufferedReader(InputStreamReader(process.inputStream))
    val deadline = System.currentTimeMillis() + 30_000
    while (System.currentTimeMillis() < deadline) {
        val line = reader.readLine() ?: break
        if (line.contains(needle)) return line.trim()
    }
    throw AssertionError("sidecar did not print $needle")
}

fun testSidecar() {
    val bin = sidecarBin()
    val langPort = sidecarFreePort()
    val serverSock = ServerSocket(langPort)
    val server = Server()
    EchoGrpcDc.registerEchoServer(server, EchoServiceImpl())
    val acceptThread = Thread {
        val sock = serverSock.accept()
        server.serveTransport(SidecarTransport(sock))
    }
    acceptThread.isDaemon = true
    acceptThread.start()

    val listen = ProcessBuilder(bin, "listen", "--udp", "127.0.0.1:0", "--tcp", "127.0.0.1:$langPort").start()
    val multiaddr = readLine(listen, "MULTIADDR").split(" ", limit = 2)[1]
    check(multiaddr.contains("/webrtc-direct/certhash/f")) { "multiaddr: $multiaddr" }

    val clientPort = sidecarFreePort()
    val dial = ProcessBuilder(bin, "dial", "--multiaddr", multiaddr, "--tcp", "127.0.0.1:$clientPort").start()
    readLine(dial, "TCP")

    try {
        val client = EchoGrpcDc.EchoClient(Channel(SidecarTransport.connect("127.0.0.1", clientPort)))
        val unary = client.Unary(EchoRequest("hello", 0))
        check(unary.message == "echo: hello") { "unary: $unary" }
        val stream = client.ServerStream(EchoRequest("tick", 3))
        val indexes = mutableListOf<Int>()
        try {
            while (true) {
                indexes.add(stream.recv().index)
            }
        } catch (e: java.io.EOFException) {
            // stream complete
        }
        check(indexes == listOf(0, 1, 2)) { "stream indexes: $indexes" }
        println("TestSidecar OK")
    } finally {
        dial.destroy()
        listen.destroy()
        serverSock.close()
    }
}
