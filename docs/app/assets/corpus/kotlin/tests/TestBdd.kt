package tests

import echo.EchoGrpcDc
import echo.EchoRequest
import echo.EchoResponse
import echo.EchoServiceImpl
import grpcdc.Channel
import grpcdc.MemoryTransport
import grpcdc.Server
import grpcdc.StatusException
import java.io.EOFException

private fun req(message: String, count: Int) = EchoRequest(message, count)

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
