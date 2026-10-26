import Foundation

// Interop harness: the generated Swift TestService server over
// stdio. Direction-B oracle tests spawn this binary and drive
// it with the official grpc-java / grpc-go interop clients
// through the bridge (oracle/bridge.mjs http2-to-dc).
let transport = StdioTransport(writerFd: 1, readerFd: 0)
let server = Server()
let impl = InteropServiceImpl()
TestGrpcDc.RegisterTestServiceServer(server, impl)
OrcaGrpcDc.RegisterOpenRcaServiceServer(server, impl)
server.ServeTransport(transport)
// Exit when the driver closes our stdin (EOF), like the other
// languages' stdio harnesses.
while true {
    Thread.sleep(forTimeInterval: 0.05)
    if feof(stdin) != 0 || ferror(stdin) != 0 {
        exit(0)
    }
}
