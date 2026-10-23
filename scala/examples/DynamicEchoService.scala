package echo

import grpcdc.{Dynamic, Endpoint, StatusException, Wire}
import java.io.EOFException

/** Dynamic Echo implementation: the reference Echo semantics built
 * purely on the descriptor-driven runtime (no generated stubs).
 * Field numbers come from proto/echo.proto: EchoRequest{message=1,
 * count=2}, EchoResponse{message=1, index=2}. */
class DynamicEchoService extends Dynamic.DynamicHandler {
  private def response(method: Dynamic.MethodModel, message: String, index: Long): Dynamic.GenericMessage = {
    new Dynamic.GenericMessage(method.output).set(1, message).set(2, index)
  }

  def unary(ctx: Endpoint#CallContext, method: Dynamic.MethodModel, req: Dynamic.GenericMessage): Dynamic.GenericMessage = {
    val message = req.getString(1)
    if (message == "fail") {
      throw StatusException(Wire.CODE_INVALID_ARGUMENT, "asked to fail")
    }
    val marker = ctx.metadata.getOrElse("x-echo", null)
    val suffix = if (marker == null || marker.isEmpty) "" else s" [$marker]"
    response(method, s"echo: $message$suffix", 0)
  }

  def serverStream(ctx: Endpoint#CallContext, method: Dynamic.MethodModel, req: Dynamic.GenericMessage, send: Dynamic.SendFn): Unit = {
    val count = req.getInt(2)
    var i = 0L
    while (i < count) {
      send.send(response(method, req.getString(1), i))
      i += 1
    }
  }

  def clientStream(ctx: Endpoint#CallContext, method: Dynamic.MethodModel, recv: Dynamic.RecvFn): Dynamic.GenericMessage = {
    val parts = scala.collection.mutable.ListBuffer[String]()
    var done = false
    while (!done) {
      try {
        parts += recv.recv().getString(1)
      } catch {
        case e: EOFException => done = true
      }
    }
    response(method, parts.mkString("+"), parts.size.toLong)
  }

  def bidi(ctx: Endpoint#CallContext, method: Dynamic.MethodModel, recv: Dynamic.RecvFn, send: Dynamic.SendFn): Unit = {
    var index = 0L
    var done = false
    while (!done) {
      try {
        val req = recv.recv()
        send.send(response(method, req.getString(1), index))
        index += 1
      } catch {
        case e: EOFException => done = true
      }
    }
  }
}
