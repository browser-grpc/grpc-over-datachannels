package tests

import echo.{EchoGrpcDc, EchoRequest, EchoResponse, EchoServiceImpl}
import grpcdc.{Channel, Endpoint, MemoryTransport, Server, StatusException}
import java.io.EOFException
import scala.concurrent.{Await, Future}
import scala.concurrent.duration.Duration

private def echoReq(message: String, count: Int): EchoRequest = EchoRequest(message, count)

private def setupEcho(): EchoGrpcDc.EchoClient = {
  val (a, b) = MemoryTransport.pair()
  val server = new Server()
  EchoGrpcDc.registerEchoServer(server, new EchoServiceImpl())
  server.serveTransport(b)
  new EchoGrpcDc.EchoClient(new Channel(a))
}

/** Async implementation used to test registerEchoServerAsync. */
private class AsyncEchoService extends EchoGrpcDc.EchoServerAsync {
  private val inner = new EchoServiceImpl()

  def UnaryAsync(ctx: Endpoint#CallContext, req: EchoRequest): Future[EchoResponse] = {
    Future.successful(inner.Unary(ctx, req))
  }

  def ServerStreamAsync(req: EchoRequest, stream: EchoGrpcDc.EchoServerStreamServer): Future[Unit] = {
    Future.successful(inner.ServerStream(req, stream))
  }

  def ClientStreamAsync(stream: EchoGrpcDc.EchoClientStreamServer): Future[Unit] = {
    Future.successful(inner.ClientStream(stream))
  }

  def BidiAsync(stream: EchoGrpcDc.EchoBidiServer): Future[Unit] = {
    Future.successful(inner.Bidi(stream))
  }
}

def testEcho(): Unit = {
  val client = setupEcho()

  val unary = client.Unary(echoReq("hello", 0))
  check(unary.message == "echo: hello" && unary.index == 0, s"unary: $unary")

  val ticks = scala.collection.mutable.ListBuffer[Int]()
  val stream = client.ServerStream(echoReq("tick", 3))
  var done = false
  while (!done) {
    try {
      ticks += stream.recv().index
    } catch {
      case e: EOFException => done = true
    }
  }
  check(ticks.toList == List(0, 1, 2), s"ticks: $ticks")

  val joined = client.ClientStream(List(echoReq("a", 0), echoReq("b", 0), echoReq("c", 0)))
  check(joined.message == "a+b+c" && joined.index == 3, s"joined: $joined")

  val echoed = scala.collection.mutable.ListBuffer[String]()
  val bidi = client.Bidi(List(echoReq("x", 0), echoReq("y", 0)))
  done = false
  while (!done) {
    try {
      echoed += bidi.recv().message
    } catch {
      case e: EOFException => done = true
    }
  }
  check(echoed.toList == List("x", "y"), s"bidi: $echoed")

  try {
    client.Unary(echoReq("fail", 0))
    check(false, "expected failure")
  } catch {
    case e: StatusException => check(e.code == 3, s"fail code: ${e.code}")
  }

  val md = client.Unary(echoReq("hello", 0), Map("x-echo" -> "meta"))
  check(md.message == "echo: hello [meta]", s"metadata: $md")

  // Future client surface against the sync loopback server.
  val asyncUnary = Await.result(client.UnaryFuture(echoReq("hello", 0)), Duration.Inf)
  check(asyncUnary.message == "echo: hello", s"future unary: $asyncUnary")
  val asyncTicks = Await.result(client.ServerStreamFuture(echoReq("tick", 3)), Duration.Inf)
  check(asyncTicks.map(_.index) == List(0, 1, 2), s"future ticks: $asyncTicks")

  // Async (Future) server surface.
  val (a2, b2) = MemoryTransport.pair()
  val server2 = new Server()
  EchoGrpcDc.registerEchoServerAsync(server2, new AsyncEchoService())
  server2.serveTransport(b2)
  val client2 = new EchoGrpcDc.EchoClient(new Channel(a2))
  val asyncResp = client2.Unary(echoReq("hello", 0))
  check(asyncResp.message == "echo: hello", s"async server unary: $asyncResp")
  val asyncJoined = client2.ClientStream(List(echoReq("a", 0), echoReq("b", 0)))
  check(asyncJoined.message == "a+b", s"async server joined: $asyncJoined")

  println("TestEcho OK")
}
