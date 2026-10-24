package tests

import echo.{EchoGrpcDc, EchoRequest, EchoResponse, EchoServiceImpl}
import grpcdc.{Channel, MemoryTransport, Server, StatusException}
import java.io.EOFException

/** BDD: interprets the generated behavior scenarios (BddScenarios,
 * generated from the BDD specification; prose in BDD.md) against a
 * loopback client+server — the executable examples. */
def testBdd(): Unit = {
  val (a, b) = MemoryTransport.pair()
  val server = new Server()
  EchoGrpcDc.registerEchoServer(server, new EchoServiceImpl())
  server.serveTransport(b)
  val channel = new Channel(a)
  val client = new EchoGrpcDc.EchoClient(channel)

  for (c <- BddScenarios.Cases) {
    c.kind match {
      case "unary" =>
        val md = if (c.metadata.isEmpty) null else Map("x-echo" -> c.metadata)
        try {
          val resp = client.Unary(EchoRequest(c.messages(0), 0), md)
          check(c.expectStatus < 0, s"${c.name}: expected failure, got $resp")
          check(resp.message == c.expectMessage && resp.index == c.expectNum, s"${c.name}: $resp")
        } catch {
          case e: StatusException =>
            check(c.expectStatus >= 0 && e.code == c.expectStatus, s"${c.name}: status $e, want ${c.expectStatus}")
        }
      case "server-stream" =>
        val stream = client.ServerStream(EchoRequest(c.messages(0), c.count))
        var got = 0
        var done = false
        while (!done) {
          try {
            val resp = stream.recv()
            check(resp.message == c.expectMessage && resp.index == got, s"${c.name}: $resp at $got")
            got += 1
          } catch {
            case e: EOFException => done = true
          }
        }
        check(got == c.expectNum, s"${c.name}: got $got, want ${c.expectNum}")
      case "client-stream" =>
        val resp = client.ClientStream(c.messages.map(m => EchoRequest(m, 0)))
        check(resp.message == c.expectMessage && resp.index == c.expectNum, s"${c.name}: $resp")
      case "bidi" =>
        val stream = client.Bidi(c.messages.map(m => EchoRequest(m, 0)))
        var got = 0
        var done = false
        while (!done) {
          try {
            val resp = stream.recv()
            check(got < c.messages.size && resp.message == c.messages(got) && resp.index == got, s"${c.name}: $resp at $got")
            got += 1
          } catch {
            case e: EOFException => done = true
          }
        }
        check(got == c.expectNum, s"${c.name}: got $got, want ${c.expectNum}")
      case "server-stream-fail" =>
        val stream = client.ServerStream(EchoRequest(c.messages(0), c.count))
        try {
          var streaming = true
          while (streaming) stream.recv()
        } catch {
          case e: StatusException =>
            check(e.code == c.expectStatus, s"${c.name}: status $e, want ${c.expectStatus}")
          case e: EOFException =>
            check(false, s"${c.name}: expected failure, stream ended OK")
        }
      case "bidi-fail" =>
        val stream = client.Bidi(c.messages.map(m => EchoRequest(m, 0)))
        try {
          var streaming = true
          while (streaming) stream.recv()
        } catch {
          case e: StatusException =>
            check(e.code == c.expectStatus, s"${c.name}: status $e, want ${c.expectStatus}")
          case e: EOFException =>
            check(false, s"${c.name}: expected failure, stream ended OK")
        }
      case "deadline" =>
        try {
          client.Unary(EchoRequest(c.messages(0), 0, c.count), null,
            java.time.Duration.ofMillis(100))
          check(false, s"${c.name}: expected deadline failure")
        } catch {
          case e: StatusException =>
            check(e.code == c.expectStatus, s"${c.name}: status $e, want ${c.expectStatus}")
        }
      case "cancel" =>
        val stream = channel.serverStream("/echo.Echo/ServerStream",
          EchoRequest(c.messages(0), c.count), null)
        val first = EchoResponse()
        stream.recv(first)
        check(first.message == c.messages(0), s"${c.name}: first $first")
        stream.cancel()
        var terminated = false
        try {
          var i = 0
          while (i < c.count + 2 && !terminated) {
            stream.recv(EchoResponse())
            i += 1
          }
        } catch {
          case e: Exception => terminated = true
        }
        check(terminated, s"${c.name}: stream did not terminate after cancel")
      case "raw-unary" =>
        try {
          channel.unary(c.path, EchoRequest(c.messages(0), 0), EchoResponse())
          check(false, s"${c.name}: expected failure")
        } catch {
          case e: StatusException =>
            check(e.code == c.expectStatus, s"${c.name}: status $e, want ${c.expectStatus}")
        }
      case other => check(false, s"unknown bdd kind: $other")
    }
  }
  println("TestBdd OK")
}
