package tests

import echo.{EchoGrpcDc, EchoRequest, EchoResponse, EchoServiceImpl}
import grpcdc.{Channel, Endpoint, MemoryTransport, Server, Tracing}
import scala.collection.mutable.ListBuffer

private case class Start(kind: String, method: String, traceId: String, spanId: String, parentSpanId: String)

private class TracingRecorder extends Tracing.Tracer {
  val starts: ListBuffer[Start] = ListBuffer.empty
  val endDurations: ListBuffer[Double] = ListBuffer.empty

  def onStart(kind: String, method: String, traceId: String, spanId: String, parentSpanId: String): Unit =
    starts.synchronized { starts += Start(kind, method, traceId, spanId, parentSpanId) }

  def onEnd(kind: String, method: String, traceId: String, spanId: String, status: String, durationMs: Double): Unit =
    endDurations.synchronized { endDurations += durationMs }
}

private class TracingFront(downstreamChannel: Channel) extends EchoGrpcDc.EchoServer {
  private val inner = new EchoServiceImpl()
  var seenSpan: String = null

  def Unary(ctx: Endpoint#CallContext, req: EchoRequest): EchoResponse = {
    seenSpan = if (ctx.traceContext == null) null else ctx.traceContext.spanId
    val bound = new EchoGrpcDc.EchoClient(downstreamChannel.withTraceContext(ctx.traceContext))
    bound.Unary(EchoRequest("nested", 0))
  }

  def ServerStream(req: EchoRequest, stream: EchoGrpcDc.EchoServerStreamServer): Unit =
    inner.ServerStream(req, stream)

  def ClientStream(stream: EchoGrpcDc.EchoClientStreamServer): Unit = inner.ClientStream(stream)

  def Bidi(stream: EchoGrpcDc.EchoBidiServer): Unit = inner.Bidi(stream)
}

def testTracing(): Unit = {
  val rec = new TracingRecorder()
  Tracing.setTracer(rec)
  try {
    val (a2, b2) = MemoryTransport.pair()
    val back = new Server()
    EchoGrpcDc.registerEchoServer(back, new EchoServiceImpl())
    back.serveTransport(b2)
    val downstreamChannel = new Channel(a2)

    val front = new TracingFront(downstreamChannel)
    val (a, b) = MemoryTransport.pair()
    val frontServer = new Server()
    EchoGrpcDc.registerEchoServer(frontServer, front)
    frontServer.serveTransport(b)
    val client = new EchoGrpcDc.EchoClient(new Channel(a))

    val resp = client.Unary(EchoRequest("hello", 0))
    check(resp.message == "echo: nested", s"resp ${resp.message}")

    val starts = rec.starts.synchronized { rec.starts.toList }
    check(starts.size == 4, s"starts $starts")
    check(starts.map(_.kind) == List("client", "server", "client", "server"), s"kinds $starts")
    check(starts.forall(_.traceId == starts(0).traceId), s"trace ids $starts")
    check(starts(1).parentSpanId == starts(0).spanId, "server parent")
    check(starts(2).parentSpanId == starts(1).spanId, "inner client parent")
    check(starts(3).parentSpanId == starts(2).spanId, "inner server parent")
    val durations = rec.endDurations.synchronized { rec.endDurations.toList }
    check(durations.size == 4 && durations.forall(_ >= 0), s"durations $durations")
    println("TestTracing OK")
  } finally {
    Tracing.setTracer(null)
  }
}
