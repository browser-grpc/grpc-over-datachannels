@file:OptIn(kotlin.js.ExperimentalJsExport::class)

// Browser test entry point (native runtime, server role):
// runs the generated Kotlin Echo server (wasm/kotlin/native
// EchoGrpcDc.kt) over the real grpcdc runtime on a
// DataChannel transport, in a Web Worker. The endpoint runs
// in inline pump mode (tryRecv transport), so this loop
// drives dispatch; handler stream waits re-enter pollOnce.
// The JS client in the Node test drives the four call shapes
// plus a deadline the slow handler must miss. Mirrors
// wasm/swift/native/echo_server.swift.

package echo

import grpcdc.EOFException
import grpcdc.Endpoint
import grpcdc.Server
import grpcdc.StatusException
import grpcdc.Wire
import grpcdc.grpcdcNowNanos
import kotlin.js.JsAny
import kotlin.js.JsExport
import kotlin.math.max

private class SlowEcho : EchoGrpcDc.EchoServer {
    private fun delay(req: EchoRequest) {
        if (req.delayMs > 0) {
            // No sleep in Kotlin/Wasm: busy-wait on the
            // monotonic runtime clock.
            val until = grpcdcNowNanos() + req.delayMs.toLong() * 1_000_000L
            while (grpcdcNowNanos() < until) {
            }
        }
    }

    override fun Unary(ctx: Endpoint.CallContext, req: EchoRequest): EchoResponse {
        if (req.message == "fail") {
            throw StatusException(Wire.CODE_INVALID_ARGUMENT, "asked to fail")
        }
        delay(req)
        val marker = ctx.metadata["x-echo"]
        val suffix = if (marker.isNullOrEmpty()) "" else " [$marker]"
        return EchoResponse("echo: ${req.message}$suffix", 0)
    }

    override fun ServerStream(req: EchoRequest, stream: EchoGrpcDc.EchoServerStreamServer) {
        if (req.message == "fail") {
            throw StatusException(Wire.CODE_INVALID_ARGUMENT, "asked to fail")
        }
        for (i in 0 until max(0, req.count)) {
            stream.send(EchoResponse(req.message, i))
        }
    }

    override fun ClientStream(stream: EchoGrpcDc.EchoClientStreamServer) {
        val parts = ArrayList<String>()
        while (true) {
            try {
                val req = stream.recv()
                if (req.message == "fail") {
                    throw StatusException(Wire.CODE_INVALID_ARGUMENT, "asked to fail")
                }
                parts.add(req.message)
            } catch (e: EOFException) {
                break
            }
        }
        stream.sendAndClose(EchoResponse(parts.joinToString("+"), parts.size))
    }

    override fun Bidi(stream: EchoGrpcDc.EchoBidiServer) {
        var index = 0
        while (true) {
            val req: EchoRequest
            try {
                req = stream.recv()
            } catch (e: EOFException) {
                return
            }
            if (req.message == "fail") {
                throw StatusException(Wire.CODE_INVALID_ARGUMENT, "asked to fail")
            }
            stream.send(EchoResponse(req.message, index))
            index++
        }
    }
}

@JsExport
fun runEchoServerNative(sab: JsAny) {
    val transport = DcTransport(sab)
    val server = Server()
    EchoGrpcDc.registerEchoServer(server, SlowEcho())
    val endpoint = server.serveTransport(transport)
    while (true) {
        endpoint.pollOnce()
        transport.waitBriefly()
    }
}
