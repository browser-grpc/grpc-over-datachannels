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

@JsExport
fun runEchoClientNative(sab: JsAny): JsString {
    val client = EchoGrpcDc.EchoClient(Channel(DcTransport(sab)))

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
        "],\"deadlineCode\":" + deadlineCode + "}").toJsString()
}
