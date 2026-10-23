package tests

import echo.EchoGrpcDc
import echo.EchoRequest
import echo.EchoResponse
import echo.EchoServiceImpl
import grpcdc.Channel
import grpcdc.Endpoint
import grpcdc.EndOfStream
import grpcdc.Server
import grpcdc.StatusException
import grpcdc.Transport
import grpcdc.TryRecvResult
import grpcdc.Wire
import java.time.Duration
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

// Single-threaded inline pump mode: an endpoint whose transport
// offers tryRecv runs without read/dispatch threads — stream
// waits pump the transport themselves. This is the mode the
// native Kotlin/Wasm client uses. The client-inline half talks
// to an ordinary threaded server; the server-inline half is
// driven by explicit pollOnce calls while a threaded client
// call runs in the background.

private fun req(message: String, count: Int) = EchoRequest(message, count)

private class QueueTransport(
    private val inbox: LinkedBlockingQueue<Any>,
    private val outbox: LinkedBlockingQueue<Any>,
    private val inline: Boolean
) : Transport {
    @Volatile
    private var closedFlag = false

    override fun send(data: ByteArray) {
        if (closedFlag) throw EndOfStream("transport closed")
        outbox.offer(data.clone())
    }

    override fun recv(): ByteArray {
        val item = inbox.take()
        if (item === CLOSED) throw EndOfStream("transport closed")
        return item as ByteArray
    }

    override fun close() {
        closedFlag = true
        inbox.offer(CLOSED)
    }

    override val hasTryRecv: Boolean
        get() = inline

    override fun tryRecv(): TryRecvResult {
        // Bounded wait so an inline pump loop re-checks
        // deadlines instead of busy-spinning.
        val item = inbox.poll(2, TimeUnit.MILLISECONDS)
            ?: return if (closedFlag) TryRecvResult.Closed else TryRecvResult.WouldBlock
        if (item === CLOSED) return TryRecvResult.Closed
        return TryRecvResult.Message(item as ByteArray)
    }

    companion object {
        private val CLOSED = Any()
    }
}

private fun queuePair(clientInline: Boolean, serverInline: Boolean): Pair<Transport, Transport> {
    val aToB = LinkedBlockingQueue<Any>()
    val bToA = LinkedBlockingQueue<Any>()
    return Pair(QueueTransport(bToA, aToB, clientInline),
        QueueTransport(aToB, bToA, serverInline))
}

private class InlineSlowEcho : EchoGrpcDc.EchoServer {
    private val inner = EchoServiceImpl()

    override fun Unary(ctx: Endpoint.CallContext, req: EchoRequest): EchoResponse {
        Thread.sleep(400)
        return inner.Unary(ctx, req)
    }

    override fun ServerStream(req: EchoRequest, stream: EchoGrpcDc.EchoServerStreamServer) =
        inner.ServerStream(req, stream)

    override fun ClientStream(stream: EchoGrpcDc.EchoClientStreamServer) =
        inner.ClientStream(stream)

    override fun Bidi(stream: EchoGrpcDc.EchoBidiServer) = inner.Bidi(stream)
}

private fun runClientInline() {
    val (a, b) = queuePair(clientInline = true, serverInline = false)
    val server = Server()
    EchoGrpcDc.registerEchoServer(server, InlineSlowEcho())
    server.serveTransport(b)
    val channel = Channel(a)
    check(channel.endpoint.isInlinePump(), "client endpoint is inline")
    val client = EchoGrpcDc.EchoClient(channel)

    val unary = client.Unary(req("hello", 0), null, Duration.ofSeconds(5))
    check(unary.message == "echo: hello", "inline unary: $unary")

    val stream = client.ServerStream(req("tick", 3))
    val indexes = ArrayList<Int>()
    while (true) {
        try {
            indexes.add(stream.recv().index)
        } catch (e: java.io.EOFException) {
            break
        }
    }
    check(indexes == listOf(0, 1, 2), "inline server stream")

    val joined = client.ClientStream(listOf(req("a", 0), req("b", 0)))
    check(joined.message == "a+b", "inline client stream: $joined")

    val bidi = client.Bidi(listOf(req("x", 0), req("y", 0)))
    val echoed = ArrayList<String>()
    while (true) {
        try {
            echoed.add(bidi.recv().message)
        } catch (e: java.io.EOFException) {
            break
        }
    }
    check(echoed == listOf("x", "y"), "inline bidi")

    val start = System.nanoTime()
    try {
        client.Unary(req("hello", 0), null, Duration.ofMillis(50))
        check(false, "expected inline deadline")
    } catch (e: StatusException) {
        check(e.code == Wire.CODE_DEADLINE_EXCEEDED, "inline deadline code ${e.code}")
    }
    check(System.nanoTime() - start < Duration.ofMillis(350).toNanos(), "inline deadline fast")
}

private fun runServerInline() {
    val (a, b) = queuePair(clientInline = false, serverInline = true)
    val server = Server()
    EchoGrpcDc.registerEchoServer(server, EchoServiceImpl())
    val serverEndpoint = server.serveTransport(b)
    check(serverEndpoint.isInlinePump(), "server endpoint is inline")
    val client = EchoGrpcDc.EchoClient(Channel(a))

    val unaryResult = AtomicReference<EchoResponse?>()
    val unaryThread = Thread {
        unaryResult.set(client.Unary(req("hello", 0), null, Duration.ofSeconds(5)))
    }
    unaryThread.isDaemon = true
    unaryThread.start()
    while (unaryThread.isAlive) {
        serverEndpoint.pollOnce()
        Thread.sleep(1)
    }
    check(unaryResult.get()?.message == "echo: hello", "inline server unary")

    val joinedResult = AtomicReference<EchoResponse?>()
    val joinedThread = Thread {
        joinedResult.set(
            client.ClientStream(listOf(req("a", 0), req("b", 0)), null, Duration.ofSeconds(5)))
    }
    joinedThread.isDaemon = true
    joinedThread.start()
    while (joinedThread.isAlive) {
        serverEndpoint.pollOnce()
        Thread.sleep(1)
    }
    check(joinedResult.get()?.message == "a+b", "inline server client stream")
}

fun testInlinePump() {
    runClientInline()
    runServerInline()
}
