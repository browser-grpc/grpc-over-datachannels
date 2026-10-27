package grpc.testing

import echo.StdioTransport
import grpcdc.Server
import java.io.{FileDescriptor, FileInputStream}

// Interop harness: the generated Scala TestService server over
// stdio. Direction-B oracle tests spawn this jar and drive it
// with the official grpc-java / grpc-go interop clients through
// the bridge (oracle/bridge.mjs http2-to-dc).
object InteropServerStdio {
  def main(args: Array[String]): Unit = {
    val transport = new StdioTransport(System.out, new FileInputStream(FileDescriptor.in))
    // Exit when the driver closes our stdin.
    transport.onEof = () => System.exit(0)
    val server = new Server()
    val impl = new InteropServiceImpl()
    TestGrpcDc.registerTestServiceServer(server, impl)
    xds.service.orca.v3.OrcaGrpcDc.registerOpenRcaServiceServer(server, impl)
    server.serveTransport(transport)
    // Serve until stdin EOF (above) or the driver kills us.
    val lock = new Object()
    lock.synchronized { lock.wait() }
    System.exit(0)
  }
}
