package echo

import grpcdc.Server
import java.io.FileInputStream
import java.io.FileDescriptor
import kotlin.system.exitProcess

// Interop harness: the Kotlin echo server over stdio. Other
// languages' tests spawn this jar and drive it with their clients,
// proving the runtimes interoperate on the same frames.
fun main() {
    val transport = StdioTransport(System.out, FileInputStream(FileDescriptor.`in`))
    // Exit when the driver closes our stdin.
    transport.onEof = { exitProcess(0) }
    val server = Server()
    EchoGrpcDc.registerEchoServer(server, EchoServiceImpl())
    server.serveTransport(transport)
    // Serve until stdin EOF (above) or the driver kills us.
    Object().apply {
        synchronized(this) { wait() }
    }
    exitProcess(0)
}
