@file:OptIn(kotlin.js.ExperimentalJsExport::class)

package echo

import grpcdcwasm.GrpcdcJsBridge
import grpcdcwasm.GrpcdcWasmBridge
import grpcdcwasm.StatusException
import grpcdcwasm.toByteArray
import grpcdcwasm.toJsUint8Array
import kotlin.js.JsAny
import kotlin.js.JsExport
import kotlin.js.JsName
import kotlin.js.JsString
import kotlin.js.Promise
import kotlin.js.js
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

private fun jsErrorCode(e: JsAny): Int = js("e.code")

private fun jsOptions(json: String): JsAny = js("JSON.parse(json)")

private class EchoRun(
    private val bridge: GrpcdcJsBridge,
    private val resolve: (JsString) -> Unit,
    private val reject: (JsAny) -> Unit
) {
    private val client = EchoWasmGrpcDc.EchoClient(GrpcdcWasmBridge(bridge))
    private var unary = ""
    private val ticks = ArrayList<Int>()
    private var joined = ""
    private val echoed = ArrayList<String>()
    private var unaryFailureCode = 0
    private var metadataMessage = ""
    private var serverStreamFailureCode = 0
    private var bidiFailureCode = 0
    private var unknownMethodCode = 0
    private var cancelTerminated = false
    private var deadlineCode = 0

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
            if (err != null) fail(err) else startUnaryFailure()
        }
    }

    // BDD deepening: failure, metadata, unknown-method, cancel,
    // and deadline scenarios executed by this module. Failure
    // shapes go through the generated stub; per-call options
    // (metadata, timeout, cancelAfter) and raw paths go through
    // the JS bridge directly.
    private fun startUnaryFailure() {
        client.Unary(EchoRequest("fail", 0)) { result ->
            val err = result.exceptionOrNull()
            unaryFailureCode = if (err == null) 0 else StatusException.toStatus(err).code
            startServerStreamFailure()
        }
    }

    private fun startServerStreamFailure() {
        client.ServerStream(EchoRequest("fail", 3), { }) { err ->
            serverStreamFailureCode = err?.code ?: 0
            startBidiFailure()
        }
    }

    private fun startBidiFailure() {
        client.Bidi(listOf(EchoRequest("fail", 0)), { }) { err ->
            bidiFailureCode = err?.code ?: 0
            startMetadata()
        }
    }

    private fun startMetadata() {
        bridge.unary(
            "/echo.Echo/Unary",
            EchoRequest("hello", 0).marshalDc().toJsUint8Array(),
            jsOptions("{\"metadata\":{\"x-echo\":\"meta\"}}")
        ).then(
            { bytes ->
                val resp = EchoResponse()
                resp.unmarshalDc(bytes.toByteArray())
                metadataMessage = resp.message
                startDeadline()
                null
            },
            { err ->
                fail(StatusException(jsErrorCode(err), "metadata call failed"))
                null
            }
        )
    }

    private fun startDeadline() {
        bridge.unary(
            "/echo.Echo/Unary",
            EchoRequest("slow", 0, 600).marshalDc().toJsUint8Array(),
            jsOptions("{\"timeout\":100}")
        ).then(
            {
                deadlineCode = 0
                startRaw()
                null
            },
            { err ->
                deadlineCode = jsErrorCode(err)
                startRaw()
                null
            }
        )
    }

    private fun startRaw() {
        bridge.unary(
            "/echo.Echo/Nope",
            EchoRequest("hello", 0).marshalDc().toJsUint8Array()
        ).then(
            {
                unknownMethodCode = 0
                startCancel()
                null
            },
            { err ->
                unknownMethodCode = jsErrorCode(err)
                startCancel()
                null
            }
        )
    }

    private fun startCancel() {
        var seen = 0
        bridge.serverStream(
            "/echo.Echo/ServerStream",
            EchoRequest("tick", 5).marshalDc().toJsUint8Array(),
            { seen++ },
            jsOptions("{\"cancelAfter\":1}")
        ).then(
            {
                cancelTerminated = seen == 1
                finish()
                null
            },
            { err ->
                fail(StatusException(jsErrorCode(err), "cancel call failed"))
                null
            }
        )
    }

    private fun finish() {
        val ticksText = ticks.joinToString(",")
        val echoedText = echoed.joinToString(",") { "\"" + jsonEscape(it) + "\"" }
        resolve(
            ("{\"unary\":\"" + jsonEscape(unary) + "\",\"ticks\":[" + ticksText +
                "],\"joined\":\"" + jsonEscape(joined) + "\",\"echoed\":[" +
                echoedText + "],\"unaryFailureCode\":" + unaryFailureCode +
                ",\"metadataMessage\":\"" + jsonEscape(metadataMessage) + "\"" +
                ",\"serverStreamFailureCode\":" + serverStreamFailureCode +
                ",\"bidiFailureCode\":" + bidiFailureCode +
                ",\"unknownMethodCode\":" + unknownMethodCode +
                ",\"cancelTerminated\":" + cancelTerminated +
                ",\"deadlineCode\":" + deadlineCode + "}").toJsString()
        )
    }
}

@JsExport
@JsName("runEchoClient")
fun runEchoClient(bridge: GrpcdcJsBridge): Promise<JsString> =
    Promise { resolve, reject ->
        EchoRun(bridge, resolve, reject).start()
    }
