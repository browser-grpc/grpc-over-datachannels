package tests

import echo.{EchoGrpcDc, StdioTransport}
import grpcdc.Channel
import java.io.File
import java.util.concurrent.TimeUnit

/**
 * Oracle: official grpc-java, bridged over TCP<->DataChannel by
 * oracle/bridge.mjs, must agree with the Scala runtime on every
 * case of the generated scenario driver. Skips when the Java oracle
 * or Node bridge are unavailable (Dockerfile.ci provides both).
 */
def testOracle(): Unit = {
  val rootPath = root()
  val cp = javaClasspath(rootPath)
  if (cp == null) {
    println("TestOracle SKIP (java oracle not built)")
    return
  }

  // Direction A: this client -> bridge -> official server.
  val port = freePort()
  val server = new ProcessBuilder("java", "-cp", cp, "dc.oracle.OracleServer", port.toString)
    .redirectOutput(ProcessBuilder.Redirect.PIPE)
    .start()
  try {
    if (!waitReady(bufferedReader(server), "READY")) {
      println("TestOracle SKIP (oracle server did not start)")
      return
    }
    val bridge = new ProcessBuilder("node", s"$rootPath/oracle/bridge.mjs", "dc-to-http2", "--grpc", s"127.0.0.1:$port")
      .redirectInput(ProcessBuilder.Redirect.PIPE)
      .redirectOutput(ProcessBuilder.Redirect.PIPE)
      .redirectError(ProcessBuilder.Redirect.INHERIT)
      .start()
    try {
      val transport = new StdioTransport(bridge.getOutputStream, bridge.getInputStream)
      val client = new EchoGrpcDc.EchoClient(new Channel(transport))
      runScenarios(client)
    } finally {
      kill(bridge)
    }
  } finally {
    kill(server)
  }

  // Direction B: official client -> bridge -> this runtime's server.
  val scalaHome = sys.env.getOrElse("SCALA3_HOME", "/usr/local/scala3")
  val serverJar = s"$rootPath/scala/build/echo_server_stdio.jar"
  if (!new File(serverJar).exists()) {
    println("TestOracle SKIP (scala server not built)")
    return
  }
  val serverCmd = s"java -cp $serverJar:$scalaHome/lib/scala3-library_3-3.3.6.jar:$scalaHome/lib/scala-library-2.13.16.jar echo.EchoServerStdio"
  val portB = freePort()
  val bridge = new ProcessBuilder(
    "node", s"$rootPath/oracle/bridge.mjs", "http2-to-dc", "--port", portB.toString,
    "--target-cmd", serverCmd
  ).redirectError(ProcessBuilder.Redirect.PIPE).start()
  try {
    if (!waitReady(bufferedReader(bridge), "listening")) {
      println("TestOracle SKIP (bridge did not start)")
      return
    }
    val client = new ProcessBuilder(
      "java", "-cp", cp, "dc.oracle.OracleClient", portB.toString,
      s"$rootPath/fixtures/oracle_scenarios.txt"
    ).redirectOutput(ProcessBuilder.Redirect.PIPE).redirectError(ProcessBuilder.Redirect.PIPE).start()
    val output = readAll(client.getInputStream)
    val errOutput = readAll(client.getErrorStream)
    val finished = client.waitFor(120, TimeUnit.SECONDS)
    check(finished, "oracle client timed out")
    check(client.exitValue() == 0, s"oracle client failed:\n$output$errOutput")
    check(output.contains("ORACLE CLIENT: ALL OK"), s"oracle client output:\n$output$errOutput")
    kill(client)
  } finally {
    kill(bridge)
  }
  println("TestOracle OK")
}
