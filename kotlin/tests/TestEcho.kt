package tests

import echo.EchoGrpcDc
import echo.EchoRequest
import echo.EchoResponse
import echo.EchoServiceImpl
import grpcdc.AsyncPump
import grpcdc.Channel
import grpcdc.Endpoint
import grpcdc.MemoryTransport
import grpcdc.Server
import grpcdc.StatusException
import java.io.EOFException
import java.util.concurrent.atomic.AtomicInteger

private fun req(message: String, count: Int) = EchoRequest(message, count)

private fun setup(): EchoGrpcDc.EchoClient {
    val (a, b) = MemoryTransport.pair()
    val server = Server()
    EchoGrpcDc.registerEchoServer(server, EchoServiceImpl())
    server.serveTransport(b)
    return EchoGrpcDc.EchoClient(Channel(a))
}

/** Async implementation used to test registerEchoServerAsync. */
private class AsyncEchoService : EchoGrpcDc.EchoServerAsync {
    private val inner = EchoServiceImpl()

    override suspend fun UnaryAsync(ctx: Endpoint.CallContext, req: EchoRequest): EchoResponse {
        return inner.Unary(ctx, req)
    }

    override suspend fun ServerStreamAsync(req: EchoRequest, stream: EchoGrpcDc.EchoServerStreamServer) {
        inner.ServerStream(req, stream)
    }

    override suspend fun ClientStreamAsync(stream: EchoGrpcDc.EchoClientStreamServer) {
        inner.ClientStream(stream)
    }

    override suspend fun BidiAsync(stream: EchoGrpcDc.EchoBidiServer) {
        inner.Bidi(stream)
    }
}

private fun runAsync() {
    // Async client surface against the sync loopback server.
    val client = setup()

    val unary = AsyncPump.runSuspend { client.UnaryAsync(req("hello", 0)) }
    check(unary.message == "echo: hello", "async unary: $unary")

    val unaryFuture = client.UnaryFuture(req("hello", 0)).get()
    check(unaryFuture.message == "echo: hello", "future unary: $unaryFuture")

    val streamed = AsyncPump.runSuspend { client.ServerStreamAsync(req("tick", 3)) }
    check(streamed.size == 3 && streamed[0].index == 0 && streamed[2].index == 2, "async server stream: $streamed")

    val joined = AsyncPump.runSuspend { client.ClientStreamAsync(listOf(req("a", 0), req("b", 0))) }
    check(joined.message == "a+b", "async client stream: $joined")

    val echoed = AsyncPump.runSuspend { client.BidiAsync(listOf(req("x", 0), req("y", 0))) }
    check(echoed.size == 2 && echoed[1].message == "y", "async bidi: $echoed")

    // Async server registration: async impl served over loopback.
    val (a, b) = MemoryTransport.pair()
    val server = Server()
    EchoGrpcDc.registerEchoServerAsync(server, AsyncEchoService())
    server.serveTransport(b)
    val client2 = EchoGrpcDc.EchoClient(Channel(a))
    val resp = client2.Unary(req("hello", 0))
    check(resp.message == "echo: hello", "async server unary: $resp")
}

/** Loopback end-to-end: all four shapes, error status, metadata. */
fun testEcho() {
    val client = setup()

    val unary = client.Unary(req("hello", 0))
    check(unary.message == "echo: hello" && unary.index == 0, "unary: $unary")

    val stream = client.ServerStream(req("tick", 3))
    val indexes = ArrayList<Int>()
    while (true) {
        try {
            val resp = stream.recv()
            check(resp.message == "tick", "stream message: $resp")
            indexes.add(resp.index)
        } catch (e: EOFException) {
            break
        }
    }
    check(indexes == listOf(0, 1, 2), "stream indexes: $indexes")

    val joined = client.ClientStream(listOf(req("a", 0), req("b", 0), req("c", 0)))
    check(joined.message == "a+b+c" && joined.index == 3, "client stream: $joined")

    val bidi = client.Bidi(listOf(req("x", 0), req("y", 0)))
    val echoed = ArrayList<String>()
    while (true) {
        try {
            echoed.add(bidi.recv().message)
        } catch (e: EOFException) {
            break
        }
    }
    check(echoed == listOf("x", "y"), "bidi: $echoed")

    try {
        client.Unary(req("fail", 0))
        check(false, "fail call should throw")
    } catch (e: StatusException) {
        check(e.code == 3, "fail status: $e")
    }

    val withMd = client.Unary(req("hello", 0), mapOf("x-echo" to "meta"))
    check(withMd.message == "echo: hello [meta]", "metadata: $withMd")

    runAsync()
    testCancellingCollectionStopsServer()
    println("TestEcho OK")
}

/** Counting service for the stream-break regression test. */
private class CountingEchoService(private val produced: AtomicInteger) : EchoGrpcDc.EchoServer {
    override fun Unary(ctx: Endpoint.CallContext, req: EchoRequest): EchoResponse {
        return EchoResponse("echo: ${req.message}", 0)
    }

    override fun ServerStream(req: EchoRequest, stream: EchoGrpcDc.EchoServerStreamServer) {
        for (i in 0 until maxOf(0, req.count)) {
            produced.incrementAndGet()
            stream.send(EchoResponse(req.message, i))
            Thread.sleep(10)
        }
    }

    override fun ClientStream(stream: EchoGrpcDc.EchoClientStreamServer) {
        val parts = ArrayList<String>()
        while (true) {
            try {
                parts.add(stream.recv().message)
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
            stream.send(EchoResponse(req.message, index))
            index++
        }
    }
}

// Cancelling the collecting future (the coroutine collection of
// a server stream) must RST the call: the producing handler's
// next send fails with CANCELLED and production settles.
private fun testCancellingCollectionStopsServer() {
    val produced = AtomicInteger(0)
    val (a, b) = MemoryTransport.pair()
    val server = Server()
    EchoGrpcDc.registerEchoServer(server, CountingEchoService(produced))
    server.serveTransport(b)
    val client = EchoGrpcDc.EchoClient(Channel(a))

    val future = client.ServerStreamFuture(req("tick", 1000))
    val start = System.currentTimeMillis()
    while (produced.get() < 1 && System.currentTimeMillis() - start < 5000) {
        Thread.sleep(5)
    }
    check(produced.get() >= 1, "server never produced")
    future.cancel(true)
    check(future.isCancelled, "future not cancelled")

    Thread.sleep(100)
    val settled = produced.get()
    Thread.sleep(100)
    check(produced.get() == settled,
        "server kept producing after cancel: $settled -> ${produced.get()}")
    check(settled < 100, "server produced too many responses: $settled")
}
