package tests

import echo.EchoGrpcDc
import echo.EchoRequest
import grpcdc.{Channel, Http2Transport}
import java.io.{File, FileInputStream}
import java.security.KeyStore
import java.security.cert.{CertificateFactory, X509Certificate}
import javax.net.ssl.{SSLContext, TrustManagerFactory}

/**
 * HTTP/2 oracle: the generated grpcdc.Http2Transport dials the
 * official grpc-java OracleServer directly over TCP (no bridge) —
 * the Scala end of the generated HTTP/2 client support. Plus a
 * TLS leg against the Node fixture (js/test/http2_tls_fixture.mjs,
 * ALPN h2). Skips when the oracle or fixtures are unavailable.
 * Mirrors java/tests/TestHttp2Oracle.java.
 */
def testHttp2Oracle(): Unit = {
  val rootPath = root()
  val cp = javaClasspath(rootPath)
  if (cp == null) {
    println("TestHttp2Oracle SKIP (oracle not built)")
    return
  }
  val port = freePort()
  val server = new ProcessBuilder("java", "-cp", cp, "dc.oracle.OracleServer", port.toString)
    .redirectOutput(ProcessBuilder.Redirect.PIPE)
    .start()
  try {
    check(waitReady(bufferedReader(server), "READY"), "java oracle did not start")
    val transport = Http2Transport.dial(s"127.0.0.1:$port")
    try {
      val client = new EchoGrpcDc.EchoClient(new Channel(transport))
      runScenarios(client)
      // Echoed initial metadata proves HEADERS metadata
      // made the round trip.
      val md = client.Unary(new EchoRequest("hello", 0, 0), Map("x-echo" -> "mval"))
      check(md.message == "echo: hello [mval]", s"metadata echo: ${md.message}")
      // 200 responses x 1500-byte payloads: comfortably past
      // several 64KiB flow-control windows, so the call only
      // completes if stream/connection WINDOW_UPDATE
      // accounting replenishes.
      val big = "y" * 1500
      val stream = client.ServerStream(new EchoRequest(big, 200, 0))
      var got = 0
      try {
        var done = false
        while (!done) {
          try {
            val resp = stream.recv()
            check(resp.message == big && resp.index == got, s"flow: $got")
            got += 1
          } catch {
            case _: java.io.EOFException => done = true
          }
        }
      } finally {
        stream.close()
      }
      check(got == 200, s"flow: got $got, want 200")
    } finally {
      transport.close()
    }
  } finally {
    kill(server)
  }
  tlsLeg(rootPath)
  println("TestHttp2Oracle OK")
}

private def tlsLeg(rootPath: String): Unit = {
  val fixture = new File(rootPath, "js/test/http2_tls_fixture.mjs")
  if (!fixture.exists()) {
    println("TestHttp2Oracle TLS SKIP (fixture missing)")
    return
  }
  val proc = new ProcessBuilder("node", fixture.getPath)
    .redirectErrorStream(false)
    .start()
  try {
    val reader = new java.io.BufferedReader(new java.io.InputStreamReader(proc.getInputStream))
    val line = reader.readLine()
    if (line == null || !line.startsWith("READY")) {
      println("TestHttp2Oracle TLS SKIP (fixture did not start)")
      return
    }
    val fields = line.trim.split("\\s+")
    val port = fields(1).toInt
    val certPath = fields(2)
    val cf = CertificateFactory.getInstance("X.509")
    val cert = scala.util.Using.resource(new FileInputStream(certPath)) {
      cf.generateCertificate(_).asInstanceOf[X509Certificate]
    }
    val ks = KeyStore.getInstance(KeyStore.getDefaultType())
    ks.load(null, null)
    ks.setCertificateEntry("fixture", cert)
    val tmf = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm())
    tmf.init(ks)
    val context = SSLContext.getInstance("TLS")
    context.init(null, tmf.getTrustManagers, null)
    val transport = Http2Transport.dialTls(s"localhost:$port", context, "localhost")
    try {
      val client = new EchoGrpcDc.EchoClient(new Channel(transport))
      val resp = client.Unary(new EchoRequest("hello", 0, 0))
      check(resp.message == "echo: hello", s"tls unary: ${resp.message}")
    } finally {
      transport.close()
    }
  } finally {
    kill(proc)
  }
}
