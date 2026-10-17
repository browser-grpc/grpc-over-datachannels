package tests

import echo.{EchoGrpcDc, EchoRequest}
import grpcdc.{Dynamic, StatusException}
import java.io.EOFException

/** Shared oracle-scenario runner for the typed stub client
 * (TestOracle) and the dynamic client (TestDynamic). */
def unmsg(token: String): String = if (token == "-") "" else token

def runScenarios(client: EchoGrpcDc.EchoClient): Unit = {
  for (c <- OracleScenarios.Cases) {
    val messages = c.messages.map(unmsg)
    val line = s"${c.kind} ${c.messages.mkString(" ")}"
    c.kind match {
      case "UNARY" =>
        try {
          val resp = client.Unary(EchoRequest(messages(0), 0))
          check(c.expectStatus < 0, s"$line: expected failure, got $resp")
          check(resp.message == s"echo: ${messages(0)}" && resp.index == 0, s"$line: $resp")
        } catch {
          case e: StatusException =>
            check(c.expectStatus >= 0 && e.code == c.expectStatus, s"$line: status $e, want ${c.expectStatus}")
        }
      case "SERVER_STREAM" =>
        val stream = client.ServerStream(EchoRequest(messages(0), c.count))
        var got = 0
        var done = false
        while (!done) {
          try {
            val resp = stream.recv()
            check(resp.message == messages(0) && resp.index == got, s"$line: $resp at $got")
            got += 1
          } catch {
            case e: EOFException => done = true
          }
        }
        check(got == c.count, s"$line: got $got, want ${c.count}")
      case "CLIENT_STREAM" =>
        val resp = client.ClientStream(messages.map(m => EchoRequest(m, 0)))
        check(resp.message == messages.mkString("+") && resp.index == messages.size, s"$line: $resp")
      case "BIDI" =>
        val stream = client.Bidi(messages.map(m => EchoRequest(m, 0)))
        var got = 0
        var done = false
        while (!done) {
          try {
            val resp = stream.recv()
            check(got < messages.size && resp.message == messages(got) && resp.index == got, s"$line: $resp at $got")
            got += 1
          } catch {
            case e: EOFException => done = true
          }
        }
        check(got == messages.size, s"$line: got $got")
      case other => throw new AssertionError(s"unknown scenario kind: $other")
    }
  }
}

def runDynamicScenarios(client: Dynamic.DynamicClient, model: Dynamic.FileModel): Unit = {
  def req(message: String, count: Long): Dynamic.GenericMessage = {
    new Dynamic.GenericMessage(model.message(".echo.EchoRequest")).set(1, message).set(2, count)
  }
  def reqs(messages: List[String]): List[Dynamic.GenericMessage] = messages.map(m => req(m, 0))
  val service = "echo.Echo"
  for (c <- OracleScenarios.Cases) {
    val messages = c.messages.map(unmsg)
    val line = s"${c.kind} ${c.messages.mkString(" ")}"
    c.kind match {
      case "UNARY" =>
        try {
          val resp = client.unary(service, "Unary", req(messages(0), 0))
          check(c.expectStatus < 0, s"$line: expected failure, got ${resp.values}")
          check(resp.getString(1) == s"echo: ${messages(0)}" && resp.getInt(2) == 0L, s"$line: ${resp.values}")
        } catch {
          case e: StatusException =>
            check(c.expectStatus >= 0 && e.code == c.expectStatus, s"$line: status $e, want ${c.expectStatus}")
        }
      case "SERVER_STREAM" =>
        val stream = client.serverStream(service, "ServerStream", req(messages(0), c.count.toLong))
        var got = 0L
        var done = false
        while (!done) {
          try {
            val resp = stream.recv()
            check(resp.getString(1) == messages(0) && resp.getInt(2) == got, s"$line: at $got")
            got += 1
          } catch {
            case e: EOFException => done = true
          }
        }
        check(got == c.count.toLong, s"$line: got $got, want ${c.count}")
      case "CLIENT_STREAM" =>
        val resp = client.clientStream(service, "ClientStream", reqs(messages))
        check(resp.getString(1) == messages.mkString("+") && resp.getInt(2) == messages.size.toLong, s"$line: ${resp.values}")
      case "BIDI" =>
        val stream = client.bidi(service, "Bidi", reqs(messages))
        var got = 0L
        var done = false
        while (!done) {
          try {
            val resp = stream.recv()
            check(got < messages.size && resp.getString(1) == messages(got.toInt) && resp.getInt(2) == got, s"$line: at $got")
            got += 1
          } catch {
            case e: EOFException => done = true
          }
        }
        check(got == messages.size.toLong, s"$line: got $got")
      case other => throw new AssertionError(s"unknown scenario kind: $other")
    }
  }
}
