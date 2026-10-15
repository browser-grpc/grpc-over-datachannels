package echo

import grpcdc.Dynamic
import grpcdc.Server
import java.io.File
import java.io.FileInputStream
import java.io.FileDescriptor
import kotlin.system.exitProcess

// Interop harness: the dynamic (descriptor-driven) Kotlin echo
// server over stdio. Loads fixtures/echo_descriptor_set.bin at
// runtime — no generated stubs involved. Used by the oracle tests.
fun main() {
    val model = Dynamic.parseDescriptorSet(File(locateFixtures()).readBytes())
    val transport = StdioTransport(System.out, FileInputStream(FileDescriptor.`in`))
    // Exit when the driver closes our stdin.
    transport.onEof = { exitProcess(0) }
    val server = Server()
    Dynamic.registerDynamicService(server, model, "echo.Echo", DynamicEchoService())
    server.serveTransport(transport)
    // Serve until stdin EOF (above) or the driver kills us.
    Object().apply {
        synchronized(this) { wait() }
    }
    exitProcess(0)
}

private fun locateFixtures(): String {
    var dir: File? = File("").absoluteFile
    repeat(8) {
        val current = dir ?: return@repeat
        val direct = File(current, "fixtures/echo_descriptor_set.bin")
        if (direct.exists()) {
            return direct.path
        }
        val nested = File(current, "grpc-over-datachannels/fixtures/echo_descriptor_set.bin")
        if (nested.exists()) {
            return nested.path
        }
        dir = current.parentFile
    }
    System.err.println("fixtures/echo_descriptor_set.bin not found")
    exitProcess(1)
}
