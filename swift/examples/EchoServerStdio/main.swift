import Foundation

// Interop harness: the Swift echo server over stdio. Other languages'
// tests spawn this binary and drive it with their clients, proving
// the runtimes interoperate on the same frames.
let transport = StdioTransport(writerFd: 1, readerFd: 0)
let server = Server()
let impl = EchoServiceImpl()
EchoGrpcDc.RegisterEchoServer(server, impl)
server.ServeTransport(transport)
// Exit when the driver closes our stdin (EOF), like the other
// languages' stdio harnesses.
while true {
    Thread.sleep(forTimeInterval: 0.05)
    if feof(stdin) != 0 || ferror(stdin) != 0 {
        exit(0)
    }
}
