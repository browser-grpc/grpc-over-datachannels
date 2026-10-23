package tests

import echo.EchoGrpcDc
import echo.EchoRequest
import grpcdc.Dynamic
import grpcdc.StatusException
import java.io.EOFException

/** Shared oracle-scenario runner for the typed stub client
 * (TestOracle) and the dynamic client (TestDynamic). */
fun unmsg(token: String): String = if (token == "-") "" else token

fun runScenarios(client: EchoGrpcDc.EchoClient) {
    for (c in OracleScenarios.Cases) {
        val messages = c.messages.map { unmsg(it) }
        val line = "${c.kind} ${c.messages.joinToString(" ")}"
        when (c.kind) {
            "UNARY" -> {
                try {
                    val resp = client.Unary(EchoRequest(messages[0], 0))
                    check(c.expectStatus < 0, "$line: expected failure, got $resp")
                    check(resp.message == "echo: ${messages[0]}" && resp.index == 0, "$line: $resp")
                } catch (e: StatusException) {
                    check(c.expectStatus >= 0 && e.code == c.expectStatus, "$line: status $e, want ${c.expectStatus}")
                }
            }
            "SERVER_STREAM" -> {
                val stream = client.ServerStream(EchoRequest(messages[0], c.count))
                var got = 0
                while (true) {
                    try {
                        val resp = stream.recv()
                        check(resp.message == messages[0] && resp.index == got, "$line: $resp at $got")
                        got++
                    } catch (e: EOFException) {
                        break
                    }
                }
                check(got == c.count, "$line: got $got, want ${c.count}")
            }
            "CLIENT_STREAM" -> {
                val resp = client.ClientStream(messages.map { EchoRequest(it, 0) })
                check(resp.message == messages.joinToString("+") && resp.index == messages.size, "$line: $resp")
            }
            "BIDI" -> {
                val stream = client.Bidi(messages.map { EchoRequest(it, 0) })
                var got = 0
                while (true) {
                    try {
                        val resp = stream.recv()
                        check(got < messages.size && resp.message == messages[got] && resp.index == got, "$line: $resp at $got")
                        got++
                    } catch (e: EOFException) {
                        break
                    }
                }
                check(got == messages.size, "$line: got $got")
            }
            else -> throw AssertionError("unknown scenario kind: ${c.kind}")
        }
    }
}

fun runDynamicScenarios(client: Dynamic.DynamicClient, model: Dynamic.FileModel) {
    fun req(message: String, count: Long): Dynamic.GenericMessage {
        return Dynamic.GenericMessage(model.message(".echo.EchoRequest")).set(1, message).set(2, count)
    }
    fun reqs(messages: List<String>): List<Dynamic.GenericMessage> = messages.map { req(it, 0) }
    val service = "echo.Echo"
    for (c in OracleScenarios.Cases) {
        val messages = c.messages.map { unmsg(it) }
        val line = "${c.kind} ${c.messages.joinToString(" ")}"
        when (c.kind) {
            "UNARY" -> {
                try {
                    val resp = client.unary(service, "Unary", req(messages[0], 0))
                    check(c.expectStatus < 0, "$line: expected failure, got ${resp.values}")
                    check(resp.getString(1) == "echo: ${messages[0]}" && resp.getInt(2) == 0L, "$line: ${resp.values}")
                } catch (e: StatusException) {
                    check(c.expectStatus >= 0 && e.code == c.expectStatus, "$line: status $e, want ${c.expectStatus}")
                }
            }
            "SERVER_STREAM" -> {
                val stream = client.serverStream(service, "ServerStream", req(messages[0], c.count.toLong()))
                var got = 0L
                while (true) {
                    try {
                        val resp = stream.recv()
                        check(resp.getString(1) == messages[0] && resp.getInt(2) == got, "$line: at $got")
                        got++
                    } catch (e: EOFException) {
                        break
                    }
                }
                check(got == c.count.toLong(), "$line: got $got, want ${c.count}")
            }
            "CLIENT_STREAM" -> {
                val resp = client.clientStream(service, "ClientStream", reqs(messages))
                check(resp.getString(1) == messages.joinToString("+") && resp.getInt(2) == messages.size.toLong(), "$line: ${resp.values}")
            }
            "BIDI" -> {
                val stream = client.bidi(service, "Bidi", reqs(messages))
                var got = 0L
                while (true) {
                    try {
                        val resp = stream.recv()
                        check(got < messages.size && resp.getString(1) == messages[got.toInt()] && resp.getInt(2) == got, "$line: at $got")
                        got++
                    } catch (e: EOFException) {
                        break
                    }
                }
                check(got == messages.size.toLong(), "$line: got $got")
            }
            else -> throw AssertionError("unknown scenario kind: ${c.kind}")
        }
    }
}
