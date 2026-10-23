package tests

import echo.{EchoGrpcDc, EchoRequest, EchoResponse, EchoServiceImpl}
import grpcdc.{Channel, Codec, Endpoint, MemoryTransport, Server, StatusException, Wire}
import java.time.Duration

private class DeadlineSlowEcho extends EchoGrpcDc.EchoServer {
  private val inner = new EchoServiceImpl()
  var seenCtx: Endpoint#CallContext = null

  def Unary(ctx: Endpoint#CallContext, req: EchoRequest): EchoResponse = {
    seenCtx = ctx
    Thread.sleep(400)
    inner.Unary(ctx, req)
  }

  def ServerStream(req: EchoRequest, stream: EchoGrpcDc.EchoServerStreamServer): Unit = {
    for (i <- 0 until math.max(0, req.count)) {
      if (i > 0) Thread.sleep(300)
      stream.send(EchoResponse(req.message, i))
    }
  }

  def ClientStream(stream: EchoGrpcDc.EchoClientStreamServer): Unit = inner.ClientStream(stream)

  def Bidi(stream: EchoGrpcDc.EchoBidiServer): Unit = inner.Bidi(stream)
}

def testDeadline(): Unit = {
  check(Codec.parseTimeout(Codec.encodeTimeout(Duration.ofMillis(250))) == Duration.ofMillis(250), "timeout round trip")
  check(Codec.parseTimeout("10x") == null, "junk timeout")

  val (a, b) = MemoryTransport.pair()
  val server = new Server()
  val slow = new DeadlineSlowEcho()
  EchoGrpcDc.registerEchoServer(server, slow)
  server.serveTransport(b)
  val client = new EchoGrpcDc.EchoClient(new Channel(a))

  val start = System.nanoTime()
  try {
    client.Unary(EchoRequest("hello", 0), null, Duration.ofMillis(50))
    check(false, "expected deadline")
  } catch {
    case e: StatusException => check(e.code == Wire.CODE_DEADLINE_EXCEEDED, s"code ${e.code}")
  }
  check(System.nanoTime() - start < Duration.ofMillis(350).toNanos, "deadline fast")
  check(slow.seenCtx != null, "handler ran")
  check(slow.seenCtx.metadata.contains("grpc-timeout"), "grpc-timeout metadata")
  check(slow.seenCtx.deadlineNanos >= 0, "ctx deadline")
  check(slow.seenCtx.timeRemaining() != null, "ctx remaining")

  val stream = client.ServerStream(EchoRequest("tick", 5), null, Duration.ofMillis(150))
  check(stream.recv().index == 0, "stream first")
  try {
    stream.recv()
    check(false, "expected stream deadline")
  } catch {
    case e: StatusException => check(e.code == Wire.CODE_DEADLINE_EXCEEDED, s"stream code ${e.code}")
  }

  val joined = client.ClientStream(List(EchoRequest("a", 0), EchoRequest("b", 0)), null, Duration.ofSeconds(5))
  check(joined.message == "a+b", s"generous timeout: $joined")
  println("TestDeadline OK")
}
