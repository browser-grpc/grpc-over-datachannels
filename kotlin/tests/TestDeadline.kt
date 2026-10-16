package tests

import echo.EchoGrpcDc
import echo.EchoRequest
import echo.EchoResponse
import echo.EchoServiceImpl
import grpcdc.Channel
import grpcdc.Codec
import grpcdc.Endpoint
import grpcdc.MemoryTransport
import grpcdc.Server
import grpcdc.StatusException
import grpcdc.Wire
import java.time.Duration

private fun req(message: String, count: Int) = EchoRequest(message, count)

private class SlowEcho : EchoGrpcDc.EchoServer {
    private val inner = EchoServiceImpl()
    var seenCtx: Endpoint.CallContext? = null

    override fun Unary(ctx: Endpoint.CallContext, req: EchoRequest): EchoResponse {
        seenCtx = ctx
        Thread.sleep(400)
        return inner.Unary(ctx, req)
    }

    override fun ServerStream(req: EchoRequest, stream: EchoGrpcDc.EchoServerStreamServer) {
        for (i in 0 until maxOf(0, req.count)) {
            if (i > 0) Thread.sleep(300)
            stream.send(EchoResponse(req.message, i))
        }
    }

    override fun ClientStream(stream: EchoGrpcDc.EchoClientStreamServer) = inner.ClientStream(stream)

    override fun Bidi(stream: EchoGrpcDc.EchoBidiServer) = inner.Bidi(stream)
}

fun testDeadline() {
    check(Codec.parseTimeout(Codec.encodeTimeout(Duration.ofMillis(250)))?.equals(Duration.ofMillis(250)) == true,
        "timeout round trip")
    check(Codec.parseTimeout("10x") == null, "junk timeout")

    val (a, b) = MemoryTransport.pair()
    val server = Server()
    val slow = SlowEcho()
    EchoGrpcDc.registerEchoServer(server, slow)
    server.serveTransport(b)
    val client = EchoGrpcDc.EchoClient(Channel(a))

    val start = System.nanoTime()
    try {
        client.Unary(req("hello", 0), null, Duration.ofMillis(50))
        check(false, "expected deadline")
    } catch (e: StatusException) {
        check(e.code == Wire.CODE_DEADLINE_EXCEEDED, "code ${e.code}")
    }
    check(System.nanoTime() - start < Duration.ofMillis(350).toNanos(), "deadline fast")
    check(slow.seenCtx != null, "handler ran")
    check(slow.seenCtx!!.metadata.containsKey("grpc-timeout"), "grpc-timeout metadata")
    check(slow.seenCtx!!.deadlineNanos >= 0, "ctx deadline")
    check(slow.seenCtx!!.timeRemaining() != null, "ctx remaining")

    val stream = client.ServerStream(req("tick", 5), null, Duration.ofMillis(150))
    check(stream.recv().index == 0, "stream first")
    try {
        stream.recv()
        check(false, "expected stream deadline")
    } catch (e: StatusException) {
        check(e.code == Wire.CODE_DEADLINE_EXCEEDED, "stream code ${e.code}")
    }

    val joined = client.ClientStream(listOf(req("a", 0), req("b", 0)), null, Duration.ofSeconds(5))
    check(joined.message == "a+b", "generous timeout: $joined")
}
