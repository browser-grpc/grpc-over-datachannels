package tests

import java.io.BufferedReader
import java.io.File
import java.io.InputStreamReader
import java.nio.charset.StandardCharsets
import java.util.concurrent.TimeUnit

/**
 * Interop oracle, Direction B: the OFFICIAL interop clients
 * (grpc-java TestServiceClient, grpc-go interop-client) run the
 * canonical cases against the generated Scala TestService
 * server (examples/InteropServerStdio), reached over HTTP/2
 * through oracle/bridge.mjs http2-to-dc. Skips when an oracle
 * binary or Node is unavailable. Mirrors
 * java/tests/TestInteropServerOracle.java.
 */
private val interopBCases = List(
  "empty_unary",
  "large_unary",
  "client_streaming",
  "server_streaming",
  "ping_pong",
  "empty_stream",
  "custom_metadata",
  "status_code_and_message",
  "special_status_message",
  "unimplemented_method",
  "unimplemented_service",
  "cancel_after_begin",
  "cancel_after_first_response",
  "timeout_on_sleeping_server")

private val interopBJavaOnly = List(
  "cacheable_unary",
  "client_compressed_unary",
  "client_compressed_streaming",
  "server_compressed_unary",
  "server_compressed_streaming")

private val interopBGoOnly = List("orca_per_rpc", "orca_oob")

private def runClientB(argv: List[String]): String = {
  val proc = new ProcessBuilder(argv: _*).redirectErrorStream(true).start()
  val out = new StringBuilder
  val drain = new Thread(() => {
    try {
      val reader = new BufferedReader(new InputStreamReader(proc.getInputStream, StandardCharsets.UTF_8))
      var line = reader.readLine()
      while (line != null) {
        out.synchronized { out.append(line).append('\n') }
        line = reader.readLine()
      }
      reader.close()
    } catch {
      case _: Exception => // process gone
    }
  })
  drain.setDaemon(true)
  drain.start()
  if (!proc.waitFor(120, TimeUnit.SECONDS)) {
    proc.destroyForcibly()
    throw new AssertionError(s"client timed out: $argv")
  }
  drain.join(5000)
  check(proc.exitValue() == 0, s"client exit ${proc.exitValue()}: $argv\n$out")
  out.synchronized { out.toString }
}

def testInteropServerOracle(): Unit = {
  val rootPath = root()
  val cp = javaClasspath(rootPath)
  if (cp == null) {
    println("TestInteropServerOracle SKIP (oracle not built)")
    return
  }
  val serverJar = new File(s"$rootPath/scala/build/interop_server_stdio.jar")
  if (!serverJar.exists()) {
    println("TestInteropServerOracle SKIP (scala server not built)")
    return
  }
  val port = freePort()
  val scalaHome = sys.env.getOrElse("SCALA3_HOME", "/usr/local/scala3")
  val serverCmd = s"java -cp ${serverJar.getPath}:$scalaHome/lib/scala3-library_3-3.3.6.jar:$scalaHome/lib/scala-library-2.13.16.jar grpc.testing.InteropServerStdio"
  val bridge = new ProcessBuilder(
    "node", s"$rootPath/oracle/bridge.mjs", "http2-to-dc",
    "--port", port.toString,
    "--target-cmd", serverCmd)
    .redirectError(ProcessBuilder.Redirect.PIPE).start()
  try {
    if (!waitReady(bufferedReader(bridge), "listening")) {
      println("TestInteropServerOracle SKIP (bridge did not start)")
      return
    }
    for (testCase <- interopBCases ++ interopBJavaOnly) {
      val out = runClientB(List(
        "java", "-cp", cp, "io.grpc.testing.integration.TestServiceClient",
        "--server_host=127.0.0.1", s"--server_port=$port",
        s"--test_case=$testCase", "--use_tls=false"))
      check(out.contains("Test completed."), s"java case $testCase: unexpected output: $out")
      println(s"interop B case ok: $testCase (java client)")
    }
    val goClient = new File(s"$rootPath/oracle/go-interop/interop-client")
    if (!goClient.exists()) {
      println("TestInteropServerOracle GO SKIP (go client not built)")
    } else {
      for (testCase <- interopBCases ++ interopBGoOnly) {
        var argv = List(
          goClient.getPath,
          "-server_host", "127.0.0.1",
          "-server_port", port.toString,
          "-test_case", testCase)
        if (testCase.startsWith("orca")) {
          argv = argv ++ List(
            "-service_config_json",
            "{ \"loadBalancingConfig\": [{ \"test_backend_metrics_load_balancer\": {} }]}")
        }
        runClientB(argv)
        println(s"interop B case ok: $testCase (go client)")
      }
    }
  } finally {
    kill(bridge)
  }
  println("TestInteropServerOracle OK")
}
