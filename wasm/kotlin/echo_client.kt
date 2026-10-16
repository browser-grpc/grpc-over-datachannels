@file:OptIn(kotlin.js.ExperimentalJsExport::class)

package echo

import grpcdcwasm.GrpcdcJsBridge
import grpcdcwasm.GrpcdcWasmBridge
import grpcdcwasm.StatusException
import kotlin.js.JsAny
import kotlin.js.JsExport
import kotlin.js.JsName
import kotlin.js.JsString
import kotlin.js.Promise
import kotlin.js.toJsString

// Browser test entry point: runs the four Echo call shapes
// through the generated Kotlin/Wasm facade (EchoWasmGrpcDc)
// over the JS grpc-dc bridge and resolves with a JSON
// summary. Callback-chained throughout — the browser
// thread cannot block. The page imports the Kotlin/Wasm
// module and calls runEchoClient(window.__grpcDcBridge).

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

private class EchoRun(
    bridge: GrpcdcJsBridge,
    private val resolve: (JsString) -> Unit,
    private val reject: (JsAny) -> Unit
) {
    private val client = EchoWasmGrpcDc.EchoClient(GrpcdcWasmBridge(bridge))
    private var unary = ""
    private val ticks = ArrayList<Int>()
    private var joined = ""
    private val echoed = ArrayList<String>()

    private fun fail(status: StatusException) {
        reject("grpc status ${status.code}: ${status.message}".toJsString())
    }

    private fun fail(result: Result<*>): Boolean {
        val err = result.exceptionOrNull() ?: return false
        fail(StatusException.toStatus(err))
        return true
    }

    fun start() {
        client.Unary(EchoRequest("hello", 0)) { result ->
            if (!fail(result)) {
                unary = result.getOrThrow().message
                startServerStream()
            }
        }
    }

    private fun startServerStream() {
        client.ServerStream(EchoRequest("tick", 3), { resp ->
            ticks.add(resp.index)
        }) { err ->
            if (err != null) fail(err) else startClientStream()
        }
    }

    private fun startClientStream() {
        client.ClientStream(listOf(EchoRequest("a", 0), EchoRequest("b", 0))) { result ->
            if (!fail(result)) {
                joined = result.getOrThrow().message
                startBidi()
            }
        }
    }

    private fun startBidi() {
        client.Bidi(listOf(EchoRequest("x", 0), EchoRequest("y", 0)), { resp ->
            echoed.add(resp.message)
        }) { err ->
            if (err != null) fail(err) else finish()
        }
    }

    private fun finish() {
        val ticksText = ticks.joinToString(",")
        val echoedText = echoed.joinToString(",") { "\"" + jsonEscape(it) + "\"" }
        resolve(
            ("{\"unary\":\"" + jsonEscape(unary) + "\",\"ticks\":[" + ticksText +
                "],\"joined\":\"" + jsonEscape(joined) + "\",\"echoed\":[" +
                echoedText + "]}").toJsString()
        )
    }
}

@JsExport
@JsName("runEchoClient")
fun runEchoClient(bridge: GrpcdcJsBridge): Promise<JsString> =
    Promise { resolve, reject ->
        EchoRun(bridge, resolve, reject).start()
    }
