package echo

import grpcdc.{Dynamic, Server}
import java.io.{FileDescriptor, FileInputStream}
import java.nio.file.{Files, Paths}

// Interop harness: the dynamic (descriptor-driven) Scala echo
// server over stdio. Loads fixtures/echo_descriptor_set.bin at
// runtime — no generated stubs involved. Used by the oracle tests.
object DynamicEchoServerStdio {
  def main(args: Array[String]): Unit = {
    val root = Paths.get("").toAbsolutePath
    val model = Dynamic.parseDescriptorSet(
      Files.readAllBytes(root.resolve("fixtures/echo_descriptor_set.bin")))
    val transport = new StdioTransport(System.out, new FileInputStream(FileDescriptor.in))
    transport.onEof = () => System.exit(0)
    val server = new Server()
    Dynamic.registerDynamicService(server, model, "echo.Echo", new DynamicEchoService())
    server.serveTransport(transport)
    val lock = new Object()
    lock.synchronized { lock.wait() }
    System.exit(0)
  }
}
