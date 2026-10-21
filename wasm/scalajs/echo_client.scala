// Browser test entry point for the Scala.js facade client:
// the page calls runScalaJsEcho(window.__grpcDcBridge) and
// awaits the summary JSON. Mirrors wasm/kotlin/echo_client.kt.

package echo

import grpcdc.StatusException
import grpcdcscalajs.{GrpcdcScalaJsBridge, ScalaJsBridge}
import scala.concurrent.{ExecutionContext, Future}
import scala.scalajs.js
import scala.scalajs.js.annotation.JSExportTopLevel

object ScalaJsEchoClientEntry {
  implicit val ec: ExecutionContext = ExecutionContext.global

  private def jsonEscape(s: String): String = {
    s.replace("\\", "\\\\").replace("\"", "\\\"")
  }

  @JSExportTopLevel("runScalaJsEcho")
  def runScalaJsEcho(bridge: js.Dynamic): js.Promise[String] = {
    import ScalaJsBridge.PromiseOps
    val jsb = new GrpcdcScalaJsBridge(bridge)
    val client = new EchoScalaJsGrpcDc.EchoClient(jsb)

    def statusCode(err: Throwable): Int = err match {
      case e: StatusException => e.code
      case e: js.JavaScriptException =>
        e.exception.asInstanceOf[js.Dynamic].selectDynamic("code").asInstanceOf[Int]
      case _ => -1
    }

    def codeOf(f: Future[_]): Future[Int] =
      f.map(_ => 0).recover { case e: Throwable => statusCode(e) }

    def collect(recv: () => Future[EchoResponse]): Future[List[EchoResponse]] = {
      def loop(acc: List[EchoResponse]): Future[List[EchoResponse]] = {
        recv().flatMap(resp => loop(acc :+ resp)).recoverWith {
          case _: java.io.EOFException => Future.successful(acc)
        }
      }
      loop(Nil)
    }

    val tickStream = client.ServerStream(EchoRequest("tick", 3))
    val bidiStream = client.Bidi(List(EchoRequest("x", 0), EchoRequest("y", 0)))
    var cancelSeen = 0
    val run: Future[String] = for {
      unary <- client.Unary(EchoRequest("hello", 0))
      ticks <- collect(() => tickStream.recvBytes())
      joined <- client.ClientStream(List(EchoRequest("a", 0), EchoRequest("b", 0)))
      echoed <- collect(() => bidiStream.recvBytes())
      // BDD deepening: failure, metadata, unknown-method,
      // cancel, and deadline scenarios in this module.
      unaryFailureCode <- codeOf(client.Unary(EchoRequest("fail", 0)))
      metadataBytes <- jsb.unaryWithOptions("/echo.Echo/Unary",
        EchoRequest("hello", 0).marshalDc(), Map("x-echo" -> "meta"), 0)
      failStream = client.ServerStream(EchoRequest("fail", 3))
      serverStreamFailureCode <- codeOf(
        collect(() => failStream.recvBytes()))
      failBidi = client.Bidi(List(EchoRequest("fail", 0)))
      bidiFailureCode <- codeOf(
        collect(() => failBidi.recvBytes()))
      unknownMethodCode <- codeOf(
        jsb.unary("/echo.Echo/Nope", EchoRequest("hello", 0).marshalDc()))
      _ <- jsb.serverStreamCancelAfter("/echo.Echo/ServerStream",
        EchoRequest("tick", 5).marshalDc(), 1, _ => cancelSeen += 1)
      deadlineCode <- codeOf(jsb.unaryWithOptions("/echo.Echo/Unary",
        EchoRequest("slow", 0, 600).marshalDc(), Map.empty, 100))
    } yield {
      val metadata = EchoResponse()
      metadata.unmarshalDc(metadataBytes)
      val ticksText = ticks.map(_.index).mkString(",")
      val echoedText = echoed.map(r => "\"" + jsonEscape(r.message) + "\"").mkString(",")
      "{\"unary\":\"" + jsonEscape(unary.message) + "\",\"ticks\":[" + ticksText +
        "],\"joined\":\"" + jsonEscape(joined.message) + "\",\"echoed\":[" + echoedText +
        "],\"unaryFailureCode\":" + unaryFailureCode +
        ",\"metadataMessage\":\"" + jsonEscape(metadata.message) + "\"" +
        ",\"serverStreamFailureCode\":" + serverStreamFailureCode +
        ",\"bidiFailureCode\":" + bidiFailureCode +
        ",\"unknownMethodCode\":" + unknownMethodCode +
        ",\"cancelTerminated\":" + (cancelSeen == 1) +
        ",\"deadlineCode\":" + deadlineCode + "}"
    }
    run.toJSPromise
  }
}
