@file:OptIn(kotlin.js.ExperimentalJsExport::class)

// Browser test entry point (facade server role): registers
// the generated Kotlin/Wasm facade server (EchoWasmGrpcDc)
// over the JS server bridge (createGrpcDcServerBridge). The
// JS grpc-dc implementation owns the wire; the typed Echo
// handlers below run in Kotlin/Wasm. The Node test's JS
// client drives the four call shapes plus a deadline the
// slow handler must miss. Mirrors the native server entries
// (wasm/kotlin/native/echo_server.kt).

package echo

import grpcdcwasm.GrpcdcJsServerBridge
import grpcdcwasm.GrpcdcWasmServerBridge
import grpcdcwasm.StatusException
import kotlin.js.JsExport
import kotlin.js.js
import kotlin.math.max

private fun nowMs(): Double = js("performance.now()")

private class SlowEcho : EchoWasmGrpcDc.EchoServer {
    private fun delay(req: EchoRequest) {
        if (req.delayMs > 0) {
            val until = nowMs() + req.delayMs.toDouble()
            while (nowMs() < until) {
            }
        }
    }

    override fun Unary(req: EchoRequest, metadata: Map<String, String>): EchoResponse {
        if (req.message == "fail") {
            // INVALID_ARGUMENT (the facade has no Wire enum).
            throw StatusException(3, "asked to fail")
        }
        delay(req)
        val marker = metadata["x-echo"]
        val suffix = if (marker.isNullOrEmpty()) "" else " [$marker]"
        return EchoResponse("echo: ${req.message}$suffix", 0)
    }

    override fun ServerStream(req: EchoRequest, metadata: Map<String, String>, sink: (EchoResponse) -> Unit) {
        if (req.message == "fail") {
            throw StatusException(3, "asked to fail")
        }
        for (i in 0 until max(0, req.count)) {
            sink(EchoResponse(req.message, i))
        }
    }

    override fun ClientStream(reqs: List<EchoRequest>, metadata: Map<String, String>): EchoResponse {
        if (reqs.any { it.message == "fail" }) {
            throw StatusException(3, "asked to fail")
        }
        val parts = reqs.map { it.message }
        return EchoResponse(parts.joinToString("+"), parts.size)
    }

    override fun Bidi(reqs: List<EchoRequest>, metadata: Map<String, String>, sink: (EchoResponse) -> Unit) {
        var index = 0
        for (req in reqs) {
            if (req.message == "fail") {
                throw StatusException(3, "asked to fail")
            }
            sink(EchoResponse(req.message, index))
            index++
        }
    }
}

@JsExport
fun registerEchoFacadeServer(bridge: GrpcdcJsServerBridge) {
    EchoWasmGrpcDc.registerEchoServer(GrpcdcWasmServerBridge(bridge), SlowEcho())
}

private class SlowEchoStream : EchoWasmGrpcDc.EchoStreamServer {
    // Invokes fail outside the pull-loop lambda: calling the
    // captured fail callback from inside source.next's lambda
    // trips a Kotlin/Wasm illegal-cast fault.
    private fun failIfFail(req: EchoRequest, fail: (StatusException) -> Unit): Boolean {
        if (req.message != "fail") return false
        fail(StatusException(3, "asked to fail"))
        return true
    }

    override fun ClientStream(
        source: EchoWasmGrpcDc.EchoRequestSource,
        metadata: Map<String, String>,
        respond: (EchoResponse) -> Unit,
        fail: (StatusException) -> Unit
    ) {
        val parts = ArrayList<String>()
        fun step() {
            source.next({ req ->
                if (req == null) {
                    respond(EchoResponse(parts.joinToString("+"), parts.size))
                } else if (!failIfFail(req, fail)) {
                    parts.add(req.message)
                    step()
                }
            }, fail)
        }
        step()
    }

    override fun Bidi(
        source: EchoWasmGrpcDc.EchoRequestSource,
        metadata: Map<String, String>,
        sink: (EchoResponse) -> Unit,
        done: () -> Unit,
        fail: (StatusException) -> Unit
    ) {
        var index = 0
        fun step() {
            source.next({ req ->
                if (req == null) {
                    done()
                } else if (!failIfFail(req, fail)) {
                    sink(EchoResponse(req.message, index))
                    index++
                    step()
                }
            }, fail)
        }
        step()
    }
}

@JsExport
fun registerEchoStreamFacadeServer(bridge: GrpcdcJsServerBridge) {
    val serverBridge = GrpcdcWasmServerBridge(bridge)
    EchoWasmGrpcDc.registerEchoStreamServer(serverBridge, SlowEchoStream())
    serverBridge.start("echo.Echo")
}
