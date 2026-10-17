package tests

import echo.{EchoGrpcDc, EchoRequest, StdioTransport}
import grpcdc.{Channel, StatusException}
import java.io.{EOFException, File}
import java.util.concurrent.TimeUnit

private def buildGo(rootPath: String, output: String, pkg: String): Boolean = {
  val proc = new ProcessBuilder("go", "build", "-o", output, pkg)
    .directory(new File(rootPath, "go"))
    .redirectOutput(ProcessBuilder.Redirect.DISCARD)
    .redirectError(ProcessBuilder.Redirect.DISCARD)
    .start()
  proc.waitFor(120, TimeUnit.SECONDS) && proc.exitValue() == 0
}

/** Pump raw bytes between two streams until EOF. */
private def pumpRaw(from: java.io.InputStream, to: java.io.OutputStream): Unit = {
  val buf = new Array[Byte](65536)
  var n = from.read(buf, 0, buf.length)
  while (n >= 0) {
    to.write(buf, 0, n)
    to.flush()
    n = from.read(buf, 0, buf.length)
  }
}

/**
 * Interop: the Scala runtime against the Go stdio harnesses (cross-
 * language wire compatibility). Skips when Go is unavailable.
 * Mirrors kotlin/tests/TestInterop.kt.
 */
def testInterop(): Unit = {
  val rootPath = root()
  val tmp = "/tmp/grpcdc_scala_interop"
  new File(tmp).mkdirs()
  val serverBin = s"$tmp/echo_server_stdio"
  if (!buildGo(rootPath, serverBin, "./examples/echo_server_stdio")) {
    println("TestInterop SKIP (no go)")
    return
  }

  val server = new ProcessBuilder(serverBin)
    .redirectInput(ProcessBuilder.Redirect.PIPE)
    .redirectOutput(ProcessBuilder.Redirect.PIPE)
    .redirectError(ProcessBuilder.Redirect.INHERIT)
    .start()
  try {
    val transport = new StdioTransport(server.getOutputStream, server.getInputStream)
    val client = new EchoGrpcDc.EchoClient(new Channel(transport))

    val unary = client.Unary(EchoRequest("hello", 0))
    check(unary.message == "echo: hello", s"unary: $unary")

    val stream = client.ServerStream(EchoRequest("tick", 3))
    val indexes = scala.collection.mutable.ListBuffer[Int]()
    var done = false
    while (!done) {
      try {
        indexes += stream.recv().index
      } catch {
        case e: EOFException => done = true
      }
    }
    check(indexes.toList == List(0, 1, 2), s"server stream: $indexes")

    val joined = client.ClientStream(List(EchoRequest("a", 0), EchoRequest("b", 0), EchoRequest("c", 0)))
    check(joined.message == "a+b+c", s"client stream: $joined")

    val bidi = client.Bidi(List(EchoRequest("x", 0), EchoRequest("y", 0)))
    val echoed = scala.collection.mutable.ListBuffer[String]()
    done = false
    while (!done) {
      try {
        echoed += bidi.recv().message
      } catch {
        case e: EOFException => done = true
      }
    }
    check(echoed.toList == List("x", "y"), s"bidi: $echoed")

    try {
      client.Unary(EchoRequest("fail", 0))
      check(false, "expected failure")
    } catch {
      case e: StatusException => check(e.code == 3, s"fail code: ${e.code}")
    }
  } finally {
    kill(server)
  }

  // Go client -> Scala server.
  val clientBin = s"$tmp/echo_client_stdio"
  if (!buildGo(rootPath, clientBin, "./examples/echo_client_stdio")) {
    println("TestInterop SKIP (no go client)")
    return
  }
  val scalaHome = sys.env.getOrElse("SCALA3_HOME", "/usr/local/scala3")
  val serverJar = s"$rootPath/scala/build/echo_server_stdio.jar"
  check(new File(serverJar).exists(), "scala server jar missing (make test-scala builds it)")
  val scalaServer = new ProcessBuilder(
    "java", "-cp", s"$serverJar:$scalaHome/lib/scala3-library_3-3.3.6.jar:$scalaHome/lib/scala-library-2.13.16.jar", "echo.EchoServerStdio")
    .redirectInput(ProcessBuilder.Redirect.PIPE)
    .redirectOutput(ProcessBuilder.Redirect.PIPE)
    .redirectError(ProcessBuilder.Redirect.PIPE)
    .start()
  val goClient = new ProcessBuilder(clientBin)
    .redirectInput(ProcessBuilder.Redirect.PIPE)
    .redirectOutput(ProcessBuilder.Redirect.PIPE)
    .redirectError(ProcessBuilder.Redirect.PIPE)
    .start()
  try {
    val t1 = new Thread(() => {
      try {
        pumpRaw(goClient.getInputStream, scalaServer.getOutputStream)
      } catch {
        case e: Exception => ()
      }
    })
    val t2 = new Thread(() => {
      try {
        pumpRaw(scalaServer.getInputStream, goClient.getOutputStream)
      } catch {
        case e: Exception => ()
      }
    })
    t1.setDaemon(true)
    t2.setDaemon(true)
    t1.start()
    t2.start()
    val finished = goClient.waitFor(60, TimeUnit.SECONDS)
    check(finished, "go client timed out")
    val errText = readAll(goClient.getErrorStream)
    check(errText.contains("unary=echo: hello"), s"go client unary: $errText")
    check(errText.contains("server_stream=tick#0,tick#1,tick#2"), s"go client stream: $errText")
    check(errText.contains("client_stream=a+b+c"), s"go client joined: $errText")
    check(errText.contains("bidi=x,y"), s"go client bidi: $errText")
  } finally {
    kill(goClient)
    kill(scalaServer)
  }
  println("TestInterop OK")
}
