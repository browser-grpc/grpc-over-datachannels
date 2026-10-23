import Foundation

// Interop harness: the dynamic (descriptor-driven) Swift echo server
// over stdio. Loads fixtures/echo_descriptor_set.bin at runtime —
// no generated stubs involved. Used by the oracle tests.
func LocateFixtures() -> String {
    var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    for _ in 0..<8 {
        let direct = dir.appendingPathComponent("fixtures/echo_descriptor_set.bin").path
        if FileManager.default.fileExists(atPath: direct) { return direct }
        let nested = dir.appendingPathComponent("grpc-over-datachannels/fixtures/echo_descriptor_set.bin").path
        if FileManager.default.fileExists(atPath: nested) { return nested }
        let parent = dir.deletingLastPathComponent()
        if parent.path == dir.path { break }
        dir = parent
    }
    FileHandle.standardError.write("fixtures/echo_descriptor_set.bin not found\n".data(using: .utf8)!)
    exit(1)
}

let model = try! Dynamic.ParseDescriptorSet([UInt8](try! Data(contentsOf: URL(fileURLWithPath: LocateFixtures()))))
let transport = StdioTransport(writerFd: 1, readerFd: 0)
let server = Server()
try! Dynamic.RegisterDynamicService(server, model, "echo.Echo", DynamicEchoService())
server.ServeTransport(transport)
while true {
    Thread.sleep(forTimeInterval: 0.05)
    if feof(stdin) != 0 || ferror(stdin) != 0 {
        exit(0)
    }
}
