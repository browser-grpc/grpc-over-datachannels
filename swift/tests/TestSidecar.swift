import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// gRPC over WebRTC-Direct via the Rust sidecar, Swift to Swift:
// two direct_sidecar processes own the WebRTC stack; the Swift
// server and client only speak length-prefixed TCP to their
// local sidecar (SidecarTransport). Sidecar stdout goes to temp
// files, which the test polls for MULTIADDR / TCP lines.

private func sidecarRoot() -> String {
    for start in [".", ".."] {
        if FileManager.default.fileExists(atPath: "\(start)/webrtc/rust/Cargo.toml") {
            return (start as NSString).standardizingPath
        }
    }
    fatalError("repo root not found")
}

private func sidecarBin() throws -> String {
    let root = sidecarRoot()
    let bin = "\(root)/webrtc/rust/target/debug/examples/direct_sidecar"
    if !FileManager.default.isExecutableFile(atPath: bin) {
        let build = Process()
        build.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        build.arguments = ["cargo", "build", "--example", "direct_sidecar"]
        build.currentDirectoryURL = URL(fileURLWithPath: "\(root)/webrtc/rust")
        try build.run()
        build.waitUntilExit()
        try Check(build.terminationStatus == 0, "cargo build direct_sidecar")
    }
    return bin
}

private func freePort() throws -> Int {
    let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let rc = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    try Check(rc == 0, "bind probe")
    var bound = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &bound) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            getsockname(fd, sa, &len)
        }
    }
    close(fd)
    return Int(UInt16(bigEndian: bound.sin_port))
}

private func startSidecar(_ bin: String, _ args: [String], _ tag: String) throws -> (Process, URL) {
    let logURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("grpcdc-sidecar-\(tag)-\(ProcessInfo.processInfo.processIdentifier).log")
    _ = FileManager.default.createFile(atPath: logURL.path, contents: nil)
    let handle = try FileHandle(forWritingTo: logURL)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: bin)
    process.arguments = args
    process.standardOutput = handle
    process.standardError = FileHandle.standardError
    try process.run()
    return (process, logURL)
}

private func waitLine(_ logURL: URL, _ needle: String) throws -> String {
    let deadline = Date().addingTimeInterval(30)
    while Date() < deadline {
        if let text = try? String(contentsOf: logURL, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                if line.contains(needle) {
                    return String(line).trimmingCharacters(in: .whitespaces)
                }
            }
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
    throw NSError(domain: "TestSidecar", code: 1, userInfo: [NSLocalizedDescriptionKey: "sidecar did not print \(needle)"])
}

func TestSidecar() throws {
    let bin = try sidecarBin()
    let langPort = try freePort()

    // Language server socket (POSIX, one accept).
    let listenFd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = UInt16(langPort).bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bindRc = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            bind(listenFd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    try Check(bindRc == 0, "bind lang port")
    try Check(listen(listenFd, 4) == 0, "listen lang port")

    let server = Server()
    EchoGrpcDc.RegisterEchoServer(server, EchoServiceImpl())
    let accepted = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        var peer = sockaddr()
        var peerLen = socklen_t(MemoryLayout<sockaddr>.size)
        let fd = accept(listenFd, &peer, &peerLen)
        server.ServeTransport(SidecarTransport(fd: fd))
        accepted.signal()
    }

    let (listenProc, listenLog) = try startSidecar(
        bin, ["listen", "--udp", "127.0.0.1:0", "--tcp", "127.0.0.1:\(langPort)"], "listen")
    let multiaddr = try waitLine(listenLog, "MULTIADDR").split(separator: " ", maxSplits: 1)[1]
    try Check(multiaddr.contains("/webrtc-direct/certhash/f"), "multiaddr: \(multiaddr)")

    let clientPort = try freePort()
    let (dialProc, dialLog) = try startSidecar(
        bin, ["dial", "--multiaddr", String(multiaddr), "--tcp", "127.0.0.1:\(clientPort)"], "dial")
    _ = try waitLine(dialLog, "TCP")

    defer {
        dialProc.terminate()
        listenProc.terminate()
        close(listenFd)
    }

    let client = EchoGrpcDc.EchoClient(Channel(try SidecarTransport.Connect("127.0.0.1", clientPort)))
    let unary = try client.Unary(EchoRequest("hello", 0))
    try Check(unary.message == "echo: hello", "unary: \(unary)")

    let stream = try client.ServerStream(EchoRequest("tick", 3))
    var indexes: [Int32] = []
    while true {
        do {
            indexes.append(try stream.Recv().index)
        } catch is EndOfStreamError {
            break
        }
    }
    try Check(indexes == [0, 1, 2], "stream indexes: \(indexes)")
    print("TestSidecar OK")
}
