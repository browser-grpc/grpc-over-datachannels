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
 * stamped from racket/bdd-spec.rkt; prose in BDD.md) against a
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
