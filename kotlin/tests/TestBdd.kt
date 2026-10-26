package tests

import echo.EchoGrpcDc
import echo.EchoRequest
import echo.EchoResponse
import echo.EchoServiceImpl
import grpcdc.Channel
import grpcdc.Endpoint
import grpcdc.MemoryTransport
import grpcdc.Server
import grpcdc.StatusException
import java.io.EOFException
import java.util.concurrent.atomic.AtomicInteger

private fun req(message: String, count: Int) = EchoRequest(message, count)

/** Counting service for the stream-break scenario. */
private class BddCountingEchoService(private val produced: AtomicInteger) : EchoGrpcDc.EchoServer {
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

/** BDD: interprets the generated behavior scenarios (BddScenarios,
 * generated from the BDD specification; prose in BDD.md) against a
 * loopback client+server — the executable examples. */
fun testBdd() {
    val (a, b) = MemoryTransport.pair()
    val server = Server()
    EchoGrpcDc.registerEchoServer(server, EchoServiceImpl())
    server.serveTransport(b)
    val channel = Channel(a)
    val client = EchoGrpcDc.EchoClient(channel)

    for (c in BddScenarios.Cases) {
        when (c.kind) {
            "unary-trailer" -> {
                val stream = channel.serverStream(
                    "/echo.Echo/Unary", req(c.messages[0], 0),
                    mapOf("x-echo-trailer" to c.metadata))
                val resp = EchoResponse()
                stream.recv(resp)
                check(resp.message == c.expectMessage && resp.index == c.expectNum,
                    "${c.name}: $resp")
                try {
                    stream.recv(EchoResponse())
                    check(false, "${c.name}: expected EOF")
                } catch (e: EOFException) {
                    // expected: trailers end the stream
                }
                check(stream.trailers?.get("x-echo-trailer") == c.metadata,
                    "${c.name}: trailer ${stream.trailers}")
            }
            "unary" -> {
                val md = if (c.metadata.isEmpty()) null else mapOf("x-echo" to c.metadata)
                try {
                    val resp = client.Unary(req(c.messages[0], 0), md)
                    check(c.expectStatus < 0, "${c.name}: expected failure, got $resp")
                    check(resp.message == c.expectMessage && resp.index == c.expectNum,
                        "${c.name}: $resp")
                } catch (e: StatusException) {
                    check(c.expectStatus >= 0 && e.code == c.expectStatus,
                        "${c.name}: status $e, want ${c.expectStatus}")
                }
            }
            "server-stream" -> {
                val stream = client.ServerStream(req(c.messages[0], c.count))
                var got = 0
                while (true) {
                    try {
                        val resp = stream.recv()
                        check(resp.message == c.expectMessage && resp.index == got,
                            "${c.name}: $resp at $got")
                        got++
                    } catch (e: EOFException) {
                        break
                    }
                }
                check(got == c.expectNum, "${c.name}: got $got, want ${c.expectNum}")
            }
            "client-stream" -> {
                val resp = client.ClientStream(c.messages.map { req(it, 0) })
                check(resp.message == c.expectMessage && resp.index == c.expectNum,
                    "${c.name}: $resp")
            }
            "bidi" -> {
                val stream = client.Bidi(c.messages.map { req(it, 0) })
                var got = 0
                while (true) {
                    try {
                        val resp = stream.recv()
                        check(got < c.messages.size && resp.message == c.messages[got]
                                && resp.index == got,
                            "${c.name}: $resp at $got")
                        got++
                    } catch (e: EOFException) {
                        break
                    }
                }
                check(got == c.expectNum, "${c.name}: got $got, want ${c.expectNum}")
            }
            "server-stream-fail" -> {
                val stream = client.ServerStream(req(c.messages[0], c.count))
                try {
                    while (true) stream.recv()
                } catch (e: StatusException) {
                    check(e.code == c.expectStatus,
                        "${c.name}: status $e, want ${c.expectStatus}")
                } catch (e: EOFException) {
                    check(false, "${c.name}: expected failure, stream ended OK")
                }
            }
            "bidi-fail" -> {
                val stream = client.Bidi(c.messages.map { req(it, 0) })
                try {
                    while (true) stream.recv()
                } catch (e: StatusException) {
                    check(e.code == c.expectStatus,
                        "${c.name}: status $e, want ${c.expectStatus}")
                } catch (e: EOFException) {
                    check(false, "${c.name}: expected failure, stream ended OK")
                }
            }
            "deadline" -> {
                try {
                    client.Unary(EchoRequest(c.messages[0], 0, c.count), null,
                        java.time.Duration.ofMillis(100))
                    check(false, "${c.name}: expected deadline failure")
                } catch (e: StatusException) {
                    check(e.code == c.expectStatus,
                        "${c.name}: status $e, want ${c.expectStatus}")
                }
            }
            "cancel" -> {
                val stream = channel.serverStream("/echo.Echo/ServerStream",
                    req(c.messages[0], c.count), null)
                val first = EchoResponse()
                stream.recv(first)
                check(first.message == c.messages[0], "${c.name}: first $first")
                stream.cancel()
                var terminated = false
                try {
                    for (i in 0 until c.count + 2) {
                        if (terminated) break
                        stream.recv(EchoResponse())
                    }
                } catch (e: Exception) {
                    terminated = true
                }
                check(terminated, "${c.name}: stream did not terminate after cancel")
            }
            "stream-break" -> {
                // Dedicated counting server (like the Go BDD
                // runner): reading one response and then abandoning
                // the stream by closing it (no explicit cancel) must
                // RST the call so the server stops producing.
                val produced = AtomicInteger(0)
                val (ba, bb) = MemoryTransport.pair()
                val bserver = Server()
                EchoGrpcDc.registerEchoServer(bserver, BddCountingEchoService(produced))
                bserver.serveTransport(bb)
                val bclient = EchoGrpcDc.EchoClient(Channel(ba))
                val stream = bclient.ServerStream(req(c.messages[0], c.count))
                val first = stream.recv()
                check(first.message == c.messages[0], "${c.name}: first $first")
                stream.close()
                Thread.sleep(150)
                val settled = produced.get()
                Thread.sleep(150)
                check(produced.get() == settled,
                    "${c.name}: server kept producing: $settled -> ${produced.get()}")
                check(settled < 50, "${c.name}: server produced too many: $settled")
            }
            "raw-unary" -> {
                try {
                    channel.unary(c.path, req(c.messages[0], 0), EchoResponse())
                    check(false, "${c.name}: expected failure")
                } catch (e: StatusException) {
                    check(e.code == c.expectStatus,
                        "${c.name}: status $e, want ${c.expectStatus}")
                }
            }
            else -> check(false, "unknown bdd kind: ${c.kind}")
        }
    }
    println("TestBdd OK")
}
