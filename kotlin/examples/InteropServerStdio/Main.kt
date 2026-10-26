package grpc.testing

import echo.StdioTransport
import grpcdc.Server
import java.io.FileInputStream
import java.io.FileDescriptor
import kotlin.system.exitProcess

// Interop harness: the generated Kotlin TestService server over
// stdio. Direction-B oracle tests spawn this jar and drive it
// with the official grpc-java / grpc-go interop clients through
// the bridge (oracle/bridge.mjs http2-to-dc).
fun main() {
    val transport = StdioTransport(System.out, FileInputStream(FileDescriptor.`in`))
    // Exit when the driver closes our stdin.
    transport.onEof = { exitProcess(0) }
    val server = Server()
    val impl = InteropServiceImpl()
    TestGrpcDc.registerTestServiceServer(server, impl)
    xds.service.orca.v3.OrcaGrpcDc.registerOpenRcaServiceServer(server, impl)
    server.serveTransport(transport)
    // Serve until stdin EOF (above) or the driver kills us.
    Object().apply {
        synchronized(this) { wait() }
    }
    exitProcess(0)
}
