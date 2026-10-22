// Reference Echo implementation for the Scala.js facade server
// tests (mirrors the other facade SlowEcho impls): "fail" is
// rejected, everything else echoes; delayMs busy-waits on
// js.Date (facade handlers run synchronously on the page).

package echo

import grpcdc.{StatusException, Wire}
import scala.concurrent.Future
import scala.scalajs.js

class EchoServerImpl extends EchoScalaJsGrpcDc.EchoServer {
  private def maybeDelay(req: EchoRequest): Unit = {
    if (req.delayMs > 0) {
      val until = js.Date.now() + req.delayMs.toDouble
      while (js.Date.now() < until) {}
    }
  }

  private def marker(metadata: Map[String, String]): String = {
    metadata.get("x-echo") match {
      case Some(m) if m.nonEmpty => s" [$m]"
      case _ => ""
    }
  }

  def Unary(req: EchoRequest, metadata: Map[String, String]): EchoResponse = {
    if (req.message == "fail") {
      throw StatusException(Wire.CODE_INVALID_ARGUMENT, "asked to fail")
    }
    maybeDelay(req)
    EchoResponse(s"echo: ${req.message}${marker(metadata)}", 0)
  }

  def ServerStream(req: EchoRequest, metadata: Map[String, String], sink: EchoScalaJsGrpcDc.EchoServerSink): Unit = {
    if (req.message == "fail") {
      throw StatusException(Wire.CODE_INVALID_ARGUMENT, "asked to fail")
    }
    maybeDelay(req)
    var i = 0
    while (i < math.max(0, req.count)) {
      sink(EchoResponse(req.message, i))
      i += 1
    }
  }

  def ClientStream(reqs: List[EchoRequest], metadata: Map[String, String]): EchoResponse = {
    for (req <- reqs) {
      if (req.message == "fail") {
        throw StatusException(Wire.CODE_INVALID_ARGUMENT, "asked to fail")
      }
    }
    EchoResponse(reqs.map(_.message).mkString("+"), reqs.size)
  }

  def Bidi(reqs: List[EchoRequest], metadata: Map[String, String], sink: EchoScalaJsGrpcDc.EchoServerSink): Unit = {
    for (req <- reqs) {
      if (req.message == "fail") {
        throw StatusException(Wire.CODE_INVALID_ARGUMENT, "asked to fail")
      }
    }
    var index = 0
    for (req <- reqs) {
      sink(EchoResponse(req.message, index))
      index += 1
    }
  }
}

class EchoStreamServerImpl extends EchoScalaJsGrpcDc.EchoStreamServer {
  import scala.concurrent.ExecutionContext.Implicits.global

  def ClientStream(source: EchoScalaJsGrpcDc.EchoRequestSource, metadata: Map[String, String]): Future[EchoResponse] = {
    def loop(parts: List[String]): Future[EchoResponse] = {
      source.next().flatMap {
        case None => Future.successful(EchoResponse(parts.mkString("+"), parts.size))
        case Some(req) if req.message == "fail" =>
          Future.failed(StatusException(Wire.CODE_INVALID_ARGUMENT, "asked to fail"))
        case Some(req) => loop(parts :+ req.message)
      }
    }
    loop(Nil)
  }

  def Bidi(source: EchoScalaJsGrpcDc.EchoRequestSource, metadata: Map[String, String], sink: EchoResponse => Unit): Future[Unit] = {
    def loop(index: Int): Future[Unit] = {
      source.next().flatMap {
        case None => Future.successful(())
        case Some(req) if req.message == "fail" =>
          Future.failed(StatusException(Wire.CODE_INVALID_ARGUMENT, "asked to fail"))
        case Some(req) =>
          sink(EchoResponse(req.message, index))
          loop(index + 1)
      }
    }
    loop(0)
  }
}
