// Browser test entry point for the Scala.js facade client:
// the page calls runScalaJsEcho(window.__grpcDcBridge) and
// awaits the summary JSON. Mirrors wasm/kotlin/echo_client.kt.

package echo

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
    val client = new EchoScalaJsGrpcDc.EchoClient(new GrpcdcScalaJsBridge(bridge))

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
    val run: Future[String] = for {
      unary <- client.Unary(EchoRequest("hello", 0))
      ticks <- collect(() => tickStream.recvBytes())
      joined <- client.ClientStream(List(EchoRequest("a", 0), EchoRequest("b", 0)))
      echoed <- collect(() => bidiStream.recvBytes())
    } yield {
      val ticksText = ticks.map(_.index).mkString(",")
      val echoedText = echoed.map(r => "\"" + jsonEscape(r.message) + "\"").mkString(",")
      "{\"unary\":\"" + jsonEscape(unary.message) + "\",\"ticks\":[" + ticksText +
        "],\"joined\":\"" + jsonEscape(joined.message) + "\",\"echoed\":[" + echoedText + "]}"
    }
    run.toJSPromise
  }
}
