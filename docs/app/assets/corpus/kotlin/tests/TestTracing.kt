package tests

import echo.EchoGrpcDc
import echo.EchoRequest
import echo.EchoResponse
import echo.EchoServiceImpl
import grpcdc.Channel
import grpcdc.Endpoint
import grpcdc.MemoryTransport
import grpcdc.Server
import grpcdc.Tracing

private data class Start(
    val kind: String,
    val method: String,
    val traceId: String,
    val spanId: String,
    val parentSpanId: String,
)

private class Recorder : Tracing.Tracer {
    val starts = mutableListOf<Start>()
    val endDurations = mutableListOf<Double>()

    override fun onStart(kind: String, method: String, traceId: String, spanId: String, parentSpanId: String) {
        synchronized(starts) { starts.add(Start(kind, method, traceId, spanId, parentSpanId)) }
    }

    override fun onEnd(kind: String, method: String, traceId: String, spanId: String, status: String, durationMs: Double) {
        synchronized(endDurations) { endDurations.add(durationMs) }
    }
}

private class Front(private val downstreamChannel: Channel) : EchoGrpcDc.EchoServer {
    private val inner = EchoServiceImpl()
    var seenSpan: String? = null

    override fun Unary(ctx: Endpoint.CallContext, req: EchoRequest): EchoResponse {
        seenSpan = ctx.traceContext?.spanId
        val bound = EchoGrpcDc.EchoClient(downstreamChannel.withTraceContext(ctx.traceContext))
        return bound.Unary(EchoRequest("nested", 0, 0))
    }

    override fun ServerStream(req: EchoRequest, stream: EchoGrpcDc.EchoServerStreamServer) =
        inner.ServerStream(req, stream)

    override fun ClientStream(stream: EchoGrpcDc.EchoClientStreamServer) = inner.ClientStream(stream)

    override fun Bidi(stream: EchoGrpcDc.EchoBidiServer) = inner.Bidi(stream)
}

fun testTracing() {
    val rec = Recorder()
    Tracing.setTracer(rec)
    try {
        val (a2, b2) = MemoryTransport.pair()
        val back = Server()
        EchoGrpcDc.registerEchoServer(back, EchoServiceImpl())
        back.serveTransport(b2)
        val downstreamChannel = Channel(a2)

        val front = Front(downstreamChannel)
        val (a, b) = MemoryTransport.pair()
        val frontServer = Server()
        EchoGrpcDc.registerEchoServer(frontServer, front)
        frontServer.serveTransport(b)
        val client = EchoGrpcDc.EchoClient(Channel(a))

        val resp = client.Unary(EchoRequest("hello", 0, 0))
        check(resp.message == "echo: nested", "resp ${resp.message}")

        val starts = synchronized(rec.starts) { rec.starts.toList() }
        check(starts.size == 4, "starts $starts")
        check(starts.map { it.kind } == listOf("client", "server", "client", "server"), "kinds $starts")
        check(starts.all { it.traceId == starts[0].traceId }, "trace ids $starts")
        check(starts[1].parentSpanId == starts[0].spanId, "server parent")
        check(starts[2].parentSpanId == starts[1].spanId, "inner client parent")
        check(starts[3].parentSpanId == starts[2].spanId, "inner server parent")
        check(front.seenSpan == starts[1].spanId, "ctx span")
        val durations = synchronized(rec.endDurations) { rec.endDurations.toList() }
        check(durations.size == 4 && durations.all { it >= 0 }, "durations $durations")
        println("TestTracing OK")
    } finally {
        Tracing.setTracer(null)
    }
}
