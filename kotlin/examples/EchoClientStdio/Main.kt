package echo

import grpcdc.Channel
import grpcdc.StatusException
import java.io.EOFException
import java.io.FileInputStream
import java.io.FileDescriptor
import kotlin.system.exitProcess

// Interop harness: the Kotlin echo client over stdio. Prints one
// line per call shape to stderr (stdout carries frames) and exits
// non-zero on any failure. Mirrors go/examples/echo_client_stdio.
fun main() {
    try {
        run()
    } catch (e: Exception) {
        System.err.println("error: $e")
        exitProcess(1)
    }
}

private fun req(message: String, count: Int) = EchoRequest(message, count)

private fun run() {
    val transport = StdioTransport(System.out, FileInputStream(FileDescriptor.`in`))
    val client = EchoGrpcDc.EchoClient(Channel(transport))

    val unary = client.Unary(req("hello", 0))
    System.err.println("unary=${unary.message}")

    val stream = client.ServerStream(req("tick", 3))
    val ticks = ArrayList<String>()
    while (true) {
        try {
            val resp = stream.recv()
            ticks.add("${resp.message}#${resp.index}")
        } catch (e: EOFException) {
            break
        }
    }
    System.err.println("server_stream=${ticks.joinToString(",")}")

    val joined = client.ClientStream(listOf(req("a", 0), req("b", 0), req("c", 0)))
    System.err.println("client_stream=${joined.message}")

    val bidi = client.Bidi(listOf(req("x", 0), req("y", 0)))
    val echoed = ArrayList<String>()
    while (true) {
        try {
            echoed.add(bidi.recv().message)
        } catch (e: EOFException) {
            break
        }
    }
    System.err.println("bidi=${echoed.joinToString(",")}")

    val mdResp = client.Unary(req("hello", 0), mapOf("x-echo" to "meta"))
    System.err.println("metadata=${mdResp.message}")

    try {
        client.Unary(EchoRequest("slow", 0, 400), null, java.time.Duration.ofMillis(50))
        System.err.println("deadline=no error")
    } catch (e: StatusException) {
        System.err.println("deadline=${e.code}")
    }

    try {
        client.Unary(req("fail", 0))
        System.err.println("error_case=no error")
        exitProcess(1)
    } catch (e: StatusException) {
        System.err.println("error_case=$e")
    }
}
