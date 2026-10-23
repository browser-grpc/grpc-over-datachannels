package echo

import grpcdc.{Endpoint, StatusException, Wire}
import java.io.EOFException
import scala.math.max

/** Reference Echo implementation (mirrors the other language demos):
 * "fail" is rejected, everything else echoes. */
class EchoServiceImpl extends EchoGrpcDc.EchoServer {
  def Unary(ctx: Endpoint#CallContext, req: EchoRequest): EchoResponse = {
    if (req.message == "fail") {
      throw StatusException(Wire.CODE_INVALID_ARGUMENT, "asked to fail")
    }
    if (req.delayMs > 0) {
      Thread.sleep(req.delayMs.toLong)
    }
    val marker = ctx.metadata.getOrElse("x-echo", null)
    val suffix = if (marker == null || marker.isEmpty) "" else s" [$marker]"
    EchoResponse(s"echo: ${req.message}$suffix", 0)
  }

  def ServerStream(req: EchoRequest, stream: EchoGrpcDc.EchoServerStreamServer): Unit = {
    if (req.message == "fail") {
      throw StatusException(Wire.CODE_INVALID_ARGUMENT, "asked to fail")
    }
    for (i <- 0 until max(0, req.count)) {
      stream.send(EchoResponse(req.message, i))
    }
  }

  def ClientStream(stream: EchoGrpcDc.EchoClientStreamServer): Unit = {
    val parts = scala.collection.mutable.ListBuffer[String]()
    var done = false
    while (!done) {
      try {
        parts += stream.recv().message
      } catch {
        case e: EOFException => done = true
      }
    }
    stream.sendAndClose(EchoResponse(parts.mkString("+"), parts.size))
  }

  def Bidi(stream: EchoGrpcDc.EchoBidiServer): Unit = {
    var index = 0
    var done = false
    while (!done) {
      try {
        val req = stream.recv()
        if (req.message == "fail") {
          throw StatusException(Wire.CODE_INVALID_ARGUMENT, "asked to fail")
        }
        stream.send(EchoResponse(req.message, index))
        index += 1
      } catch {
        case e: EOFException => done = true
      }
    }
  }
}
