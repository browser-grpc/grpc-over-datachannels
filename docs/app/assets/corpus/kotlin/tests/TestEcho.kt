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
    println("TestEcho OK")
}
