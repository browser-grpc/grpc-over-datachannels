@file:OptIn(kotlin.js.ExperimentalJsExport::class)

// Browser tracing entry point (native Kotlin/Wasm runtime):
// runs a nested call chain entirely in the worker — client ->
// front callee -> downstream service over memory transports —
// with a recording span observer, and returns the spans as JSON
// so the Playwright driver can assert the trace. The inline
// pump is single-threaded, so client transports poll their peer
// server endpoint on tryRecv (cooperative pumping).

package echo

import grpcdc.Channel
import grpcdc.Endpoint
import grpcdc.Server
import grpcdc.Tracing
import grpcdc.Transport
import grpcdc.TryRecvResult
import kotlin.js.JsExport

private data class StartRec(
    val kind: String,
    val traceId: String,
    val spanId: String,
    val parentSpanId: String,
)

private class Recorder : Tracing.Tracer {
    val starts = mutableListOf<StartRec>()
    val endDurations = mutableListOf<Double>()

    override fun onStart(kind: String, method: String, traceId: String, spanId: String, parentSpanId: String) {
        starts.add(StartRec(kind, traceId, spanId, parentSpanId))
    }

    override fun onEnd(kind: String, method: String, traceId: String, spanId: String, status: String, durationMs: Double) {
        endDurations.add(durationMs)
    }
}

/** Inline-pump memory transport (the runtime's MemoryTransport
 *  has no tryRecv, so it cannot drive a single-threaded nested
 *  chain). tryRecv polls the peer server endpoint first. */
private class QueueTransport(
    private val inbox: ArrayDeque<Any>,
    private val outbox: ArrayDeque<Any>,
    private val pollPeer: () -> Unit,
) : Transport {
    override fun send(data: ByteArray) {
        outbox.addLast(data.copyOf())
    }

    override fun recv(): ByteArray {
        while (true) {
            val item = inbox.removeFirstOrNull()
            if (item != null) return item as ByteArray
            pollPeer()
        }
    }

    override val hasTryRecv: Boolean get() = true

    override fun tryRecv(): TryRecvResult {
        pollPeer()
        val item = inbox.removeFirstOrNull() ?: return TryRecvResult.WouldBlock
        return TryRecvResult.Message(item as ByteArray)
    }
}

private fun queuePair(pollA: () -> Unit, pollB: () -> Unit): Pair<Transport, Transport> {
    val aToB = ArrayDeque<Any>()
    val bToA = ArrayDeque<Any>()
    return Pair(
        QueueTransport(bToA, aToB, pollA),
        QueueTransport(aToB, bToA, pollB),
    )
}

private class BackImpl : EchoGrpcDc.EchoServer {
    override fun Unary(ctx: Endpoint.CallContext, req: EchoRequest): EchoResponse =
        EchoResponse("echo: ${req.message}", 0)

    override fun ServerStream(req: EchoRequest, stream: EchoGrpcDc.EchoServerStreamServer) {
        for (i in 0 until maxOf(0, req.count)) stream.send(EchoResponse(req.message, i))
    }

    override fun ClientStream(stream: EchoGrpcDc.EchoClientStreamServer) {
        val parts = mutableListOf<String>()
        while (true) {
            try {
                parts.add(stream.recv().message)
            } catch (e: Exception) {
                break
            }
        }
        stream.sendAndClose(EchoResponse(parts.joinToString("+"), parts.size))
    }

    override fun Bidi(stream: EchoGrpcDc.EchoBidiServer) {
        var index = 0
        while (true) {
            val req = try {
                stream.recv()
            } catch (e: Exception) {
                return
            }
            stream.send(EchoResponse(req.message, index++))
        }
    }
}

private class FrontImpl(private val downstreamChannel: Channel) : EchoGrpcDc.EchoServer {
    var seenSpan: String? = null

    override fun Unary(ctx: Endpoint.CallContext, req: EchoRequest): EchoResponse {
        seenSpan = ctx.traceContext?.spanId
        val bound = EchoGrpcDc.EchoClient(downstreamChannel.withTraceContext(ctx.traceContext))
        return bound.Unary(EchoRequest("nested", 0))
    }

    override fun ServerStream(req: EchoRequest, stream: EchoGrpcDc.EchoServerStreamServer) {
        for (i in 0 until maxOf(0, req.count)) stream.send(EchoResponse(req.message, i))
    }

    override fun ClientStream(stream: EchoGrpcDc.EchoClientStreamServer) {
        val parts = mutableListOf<String>()
        while (true) {
            try {
                parts.add(stream.recv().message)
            } catch (e: Exception) {
                break
            }
        }
        stream.sendAndClose(EchoResponse(parts.joinToString("+"), parts.size))
    }

    override fun Bidi(stream: EchoGrpcDc.EchoBidiServer) {
        var index = 0
        while (true) {
            val req = try {
                stream.recv()
            } catch (e: Exception) {
                return
            }
            stream.send(EchoResponse(req.message, index++))
        }
    }
}

@JsExport
fun runEchoTracingNative(): String {
    val recorder = Recorder()
    Tracing.setTracer(recorder)
    try {
        var backEp: Endpoint? = null
        var frontEp: Endpoint? = null
        val (a2, b2) = queuePair({ backEp?.pollOnce() }, { })
        val back = Server()
        EchoGrpcDc.registerEchoServer(back, BackImpl())
        backEp = back.serveTransport(b2)
        val downstreamChannel = Channel(a2)

        val front = FrontImpl(downstreamChannel)
        val (a, b) = queuePair({ frontEp?.pollOnce() }, { })
        val frontServer = Server()
        EchoGrpcDc.registerEchoServer(frontServer, front)
        frontEp = frontServer.serveTransport(b)
        val client = EchoGrpcDc.EchoClient(Channel(a))

        val resp = client.Unary(EchoRequest("hello", 0))
        val startsJson = recorder.starts.joinToString(",") { s ->
            "[\"${s.kind}\",\"${s.traceId}\",\"${s.spanId}\",\"${s.parentSpanId}\"]"
        }
        val durationsJson = recorder.endDurations.joinToString(",")
        return "{\"message\":\"${resp.message}\",\"seenSpan\":\"${front.seenSpan}\"," +
            "\"starts\":[$startsJson],\"endDurations\":[$durationsJson]}"
    } finally {
        Tracing.setTracer(null)
    }
}
