package tests

import echo.EchoGrpcDc
import echo.EchoRequest
import echo.EchoServiceImpl
import grpcdc.Channel
import grpcdc.Server
import grpcdc.SidecarTransport
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.ServerSocket
import java.nio.file.Files
import java.nio.file.Path

// gRPC over WebRTC-Direct via the Rust sidecar, Scala to Scala:
// two direct_sidecar processes own the WebRTC stack; the Scala
// server and client only speak length-prefixed TCP to their
// local sidecar (grpcdc.SidecarTransport).

object TestSidecar {
  private def sidecarBin(): String = {
    val root = List(Path.of("."), Path.of("..")).find(p => Files.exists(p.resolve("webrtc/rust/Cargo.toml"))).get.toAbsolutePath.normalize()
    val bin = root.resolve("webrtc/rust/target/debug/examples/direct_sidecar")
    if (!Files.isExecutable(bin)) {
      val build = new ProcessBuilder("cargo", "build", "--example", "direct_sidecar")
        .directory(root.resolve("webrtc/rust").toFile)
        .inheritIO()
        .start()
      if (build.waitFor() != 0) throw new AssertionError("cargo build direct_sidecar")
    }
    bin.toString
  }

  private def sidecarFreePort(): Int = {
    val s = new ServerSocket(0)
    val p = s.getLocalPort
    s.close()
    p
  }

  private def readLine(process: Process, needle: String): String = {
    val reader = new BufferedReader(new InputStreamReader(process.getInputStream))
    val deadline = System.currentTimeMillis() + 30000
    var line = reader.readLine()
    while (System.currentTimeMillis() < deadline && line != null) {
      if (line.contains(needle)) return line.trim
      line = reader.readLine()
    }
    throw new AssertionError(s"sidecar did not print $needle")
  }

  def run(): Unit = {
    val bin = sidecarBin()
    val langPort = sidecarFreePort()
    val serverSock = new ServerSocket(langPort)
    val server = new Server()
    EchoGrpcDc.registerEchoServer(server, new EchoServiceImpl())
    val acceptThread = new Thread(new Runnable {
      def run(): Unit = {
        val sock = serverSock.accept()
        server.serveTransport(new SidecarTransport(sock))
        ()
      }
    })
    acceptThread.setDaemon(true)
    acceptThread.start()

    val listen = new ProcessBuilder(bin, "listen", "--udp", "127.0.0.1:0", "--tcp", s"127.0.0.1:$langPort").start()
    val multiaddr = readLine(listen, "MULTIADDR").split(" ", 2)(1)
    if (!multiaddr.contains("/webrtc-direct/certhash/f")) throw new AssertionError(s"multiaddr: $multiaddr")

    val clientPort = sidecarFreePort()
    val dial = new ProcessBuilder(bin, "dial", "--multiaddr", multiaddr, "--tcp", s"127.0.0.1:$clientPort").start()
    readLine(dial, "TCP")

    try {
      val client = new EchoGrpcDc.EchoClient(new Channel(SidecarTransport.connect("127.0.0.1", clientPort)))
      val unary = client.Unary(new EchoRequest("hello", 0, 0))
      if (unary.message != "echo: hello") throw new AssertionError(s"unary: $unary")
      val stream = client.ServerStream(new EchoRequest("tick", 3, 0))
      val indexes = scala.collection.mutable.ListBuffer.empty[Int]
      try {
        var done = false
        while (!done) {
          val resp = stream.recv()
          if (resp == null) done = true else indexes += resp.index
        }
      } catch {
        case _: java.io.EOFException => ()
      }
      if (indexes.toList != List(0, 1, 2)) throw new AssertionError(s"stream indexes: $indexes")
      println("TestSidecar OK")
    } finally {
      dial.destroy()
      listen.destroy()
      serverSock.close()
    }
  }
}

// Entry used by tests.Main dispatch.
def testSidecar(): Unit = TestSidecar.run()
