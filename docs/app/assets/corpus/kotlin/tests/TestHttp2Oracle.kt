package tests

import echo.EchoGrpcDc
import echo.EchoRequest
import grpcdc.Channel
import grpcdc.Http2Transport
import java.io.File
import java.io.FileInputStream
import java.security.KeyStore
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManagerFactory

/**
 * HTTP/2 oracle: the generated grpcdc.Http2Transport dials the
 * official grpc-java OracleServer directly over TCP (no bridge) —
 * the Kotlin end of the generated HTTP/2 client support. Plus a
 * TLS leg against the Node fixture (js/test/http2_tls_fixture.mjs,
 * ALPN h2). Skips when the oracle or fixtures are unavailable.
 * Mirrors java/tests/TestHttp2Oracle.java.
 */
fun testHttp2Oracle() {
    val root = root()
    val cp = javaClasspath(root)
    if (cp == null) {
        println("TestHttp2Oracle SKIP (oracle not built)")
        return
    }
    val port = freePort()
    val server = ProcessBuilder("java", "-cp", cp, "dc.oracle.OracleServer", port.toString())
        .redirectOutput(ProcessBuilder.Redirect.PIPE)
        .start()
    try {
        check(waitReady(bufferedReader(server), "READY"), "java oracle did not start")
        val transport = Http2Transport.dial("127.0.0.1:$port")
        try {
            val client = EchoGrpcDc.EchoClient(Channel(transport))
            runScenarios(client)
            // Echoed initial metadata proves HEADERS metadata
            // made the round trip.
            val md = client.Unary(EchoRequest("hello", 0, 0), mapOf("x-echo" to "mval"))
            check(md.message == "echo: hello [mval]", "metadata echo: ${md.message}")
            // 200 responses x 1500-byte payloads: comfortably
            // past several 64KiB flow-control windows, so the
            // call only completes if stream/connection
            // WINDOW_UPDATE accounting replenishes.
            val big = "y".repeat(1500)
            val stream = client.ServerStream(EchoRequest(big, 200, 0))
            var got = 0
            try {
                while (true) {
                    val resp = stream.recv()
                    check(resp.message == big && resp.index == got, "flow: $got")
                    got++
                }
            } catch (e: java.io.EOFException) {
                // end of stream
            }
            check(got == 200, "flow: got $got, want 200")
            stream.close()
        } finally {
            transport.close()
        }
    } finally {
        kill(server)
    }
    tlsLeg(root)
    println("TestHttp2Oracle OK")
}

private fun tlsLeg(root: String) {
    val fixture = File(root, "js/test/http2_tls_fixture.mjs")
    if (!fixture.exists()) {
        println("TestHttp2Oracle TLS SKIP (fixture missing)")
        return
    }
    val proc = ProcessBuilder("node", fixture.path)
        .redirectErrorStream(false)
        .start()
    try {
        // The fixture prints READY on stdout (the Java oracle
        // server uses stderr; bufferedReader(proc) reads that).
        val line = java.io.BufferedReader(
            java.io.InputStreamReader(proc.inputStream)).readLine()
        if (line == null || !line.startsWith("READY")) {
            println("TestHttp2Oracle TLS SKIP (fixture did not start)")
            return
        }
        val fields = line.trim().split(Regex("\\s+"))
        val port = fields[1].toInt()
        val certPath = fields[2]
        val cf = CertificateFactory.getInstance("X.509")
        val cert: X509Certificate = FileInputStream(certPath).use { cf.generateCertificate(it) as X509Certificate }
        val ks = KeyStore.getInstance(KeyStore.getDefaultType())
        ks.load(null, null)
        ks.setCertificateEntry("fixture", cert)
        val tmf = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm())
        tmf.init(ks)
        val context = SSLContext.getInstance("TLS")
        context.init(null, tmf.trustManagers, null)
        val transport = Http2Transport.dialTls("localhost:$port", context, "localhost")
        try {
            val client = EchoGrpcDc.EchoClient(Channel(transport))
            val resp = client.Unary(EchoRequest("hello", 0, 0))
            check(resp.message == "echo: hello", "tls unary: ${resp.message}")
        } finally {
            transport.close()
        }
    } finally {
        kill(proc)
    }
}
