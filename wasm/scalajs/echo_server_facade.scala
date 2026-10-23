// Browser test entry points for the Scala.js facade servers:
// the pages call registerScalaJsEchoServer /
// registerScalaJsEchoStreamServer with the JS server bridge
// (createGrpcDcServerBridge). Mirrors wasm/kotlin/echo_server_facade.kt.

package echo

import grpcdcscalajs.GrpcdcScalaJsServerBridge
import scala.scalajs.js
import scala.scalajs.js.annotation.JSExportTopLevel

object ScalaJsEchoServerFacade {
  @JSExportTopLevel("registerScalaJsEchoServer")
  def register(serverBridge: js.Dynamic): Unit = {
    EchoScalaJsGrpcDc.registerEchoServer(
      new GrpcdcScalaJsServerBridge(serverBridge), new EchoServerImpl())
  }
}

object ScalaJsEchoStreamServerFacade {
  @JSExportTopLevel("registerScalaJsEchoStreamServer")
  def register(serverBridge: js.Dynamic): Unit = {
    val bridge = new GrpcdcScalaJsServerBridge(serverBridge)
    EchoScalaJsGrpcDc.registerEchoStreamServer(bridge, new EchoStreamServerImpl())
    bridge.start("echo.Echo")
  }
}
