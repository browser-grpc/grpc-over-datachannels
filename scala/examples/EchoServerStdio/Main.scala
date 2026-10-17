package echo

import grpcdc.Server
import java.io.{FileDescriptor, FileInputStream}

// Interop harness: the Scala echo server over stdio. Other
// languages' tests spawn this jar and drive it with their clients,
// proving the runtimes interoperate on the same frames.
object EchoServerStdio {
  def main(args: Array[String]): Unit = {
    val transport = new StdioTransport(System.out, new FileInputStream(FileDescriptor.in))
    // Exit when the driver closes our stdin.
    transport.onEof = () => System.exit(0)
    val server = new Server()
    EchoGrpcDc.registerEchoServer(server, new EchoServiceImpl())
    server.serveTransport(transport)
    // Serve until stdin EOF (above) or the driver kills us.
    val lock = new Object()
    lock.synchronized { lock.wait() }
    System.exit(0)
  }
}
