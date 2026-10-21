@file:OptIn(kotlin.js.ExperimentalJsExport::class)

// Browser test entry point (native runtime): runs the four
// Echo call shapes with the *native* generated Kotlin client
// (wasm/kotlin/native/EchoGrpcDc.kt) over the real grpcdc
// channel/endpoint runtime on a DataChannel transport, in a
// Web Worker. The endpoint runs in inline pump mode (tryRecv
// transport), so the ordinary blocking client code below
// drives itself. Mirrors wasm/swift/native's echo client.

package echo

import grpcdc.Channel
import grpcdc.EOFException
import grpcdc.StatusException
import kotlin.js.JsAny
import kotlin.js.JsExport
import kotlin.js.JsString
import kotlin.js.toJsString

private fun jsonEscape(s: String): String {
    val out = StringBuilder()
    for (ch in s) {
        when (ch) {
            '"' -> out.append("\\\"")
            '\\' -> out.append("\\\\")
            '\n' -> out.append("\\n")
            '\r' -> out.append("\\r")
            '\t' -> out.append("\\t")
            else -> out.append(ch)
        }
    }
    return out.toString()
}

private fun codeOf(body: () -> Unit): Int {
    return try {
        body()
        0
    } catch (e: StatusException) {
        e.code
    } catch (e: Exception) {
        // e.g. EOFException when a peer ends a failed call with
        // OK trailers instead of a status; the BDD runner asserts
        // real codes against the Node server.
        -1
    }
}

@JsExport
fun runEchoClientNative(sab: JsAny): JsString {
    val channel = Channel(DcTransport(sab))
    val client = EchoGrpcDc.EchoClient(channel)

    val unary = client.Unary(EchoRequest("hello", 0))

    val stream = client.ServerStream(EchoRequest("tick", 3))
    val ticks = ArrayList<Int>()
    while (true) {
        try {
            ticks.add(stream.recv().index)
        } catch (e: EOFException) {
            break
        }
    }

    val joined = client.ClientStream(listOf(EchoRequest("a", 0), EchoRequest("b", 0)))

    val bidi = client.Bidi(listOf(EchoRequest("x", 0), EchoRequest("y", 0)))
    val echoed = ArrayList<String>()
    while (true) {
        try {
            echoed.add(bidi.recv().message)
        } catch (e: EOFException) {
            break
        }
    }

    // BDD deepening: failure, metadata, unknown-method, and
    // cancellation scenarios executed by this module.
    val unaryFailureCode = codeOf { client.Unary(EchoRequest("fail", 0)) }
    val metadataResp = client.Unary(EchoRequest("hello", 0), mapOf("x-echo" to "meta"))
    val serverStreamFailureCode = codeOf {
        val s = client.ServerStream(EchoRequest("fail", 3))
        while (true) s.recv()
    }
    val bidiFailureCode = codeOf {
        val s = client.Bidi(listOf(EchoRequest("fail", 0)))
        while (true) s.recv()
    }
    val unknownMethodCode = codeOf {
        channel.unary("/echo.Echo/Nope", EchoRequest("hello", 0), EchoResponse())
    }
    var cancelTerminated = false
    try {
        val stream = channel.serverStream("/echo.Echo/ServerStream", EchoRequest("tick", 5), null)
        stream.recv(EchoResponse())
        stream.cancel()
        try {
            for (i in 0 until 7) {
                stream.recv(EchoResponse())
            }
        } catch (e: Exception) {
            cancelTerminated = true
        }
    } catch (e: Exception) {
        // leave cancelTerminated false
    }

    var deadlineCode = 0
    try {
        client.Unary(EchoRequest("slow", 0, 400), null, 50_000_000L)
    } catch (e: StatusException) {
        deadlineCode = e.code
    }

    val ticksText = ticks.joinToString(",")
    val echoedText = echoed.joinToString(",") { "\"" + jsonEscape(it) + "\"" }
    return ("{\"unary\":\"" + jsonEscape(unary.message) + "\",\"ticks\":[" + ticksText +
        "],\"joined\":\"" + jsonEscape(joined.message) + "\",\"echoed\":[" + echoedText +
        "],\"deadlineCode\":" + deadlineCode +
        ",\"unaryFailureCode\":" + unaryFailureCode +
        ",\"metadataMessage\":\"" + jsonEscape(metadataResp.message) + "\"" +
        ",\"serverStreamFailureCode\":" + serverStreamFailureCode +
        ",\"bidiFailureCode\":" + bidiFailureCode +
        ",\"unknownMethodCode\":" + unknownMethodCode +
        ",\"cancelTerminated\":" + cancelTerminated + "}").toJsString()
}
