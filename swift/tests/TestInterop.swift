import Foundation

#if canImport(Glibc)
import Glibc
#endif

private func BuildGo(_ root: String, _ output: String, _ pkg: String) -> Bool {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    proc.arguments = ["go", "build", "-o", output, pkg]
    proc.currentDirectoryURL = URL(fileURLWithPath: "\(root)/go")
    proc.standardOutput = FileHandle.nullDevice
    proc.standardError = FileHandle.nullDevice
    do {
        try proc.run()
    } catch {
        return false
    }
    proc.waitUntilExit()
    return proc.terminationStatus == 0
}

/// Pump raw bytes between two fds until EOF (raw IO: stdio reads
/// would block trying to fill a large buffer on a pipe).
private func Pump(_ fromFd: Int32, _ toFd: Int32) {
    var buf = [UInt8](repeating: 0, count: 65536)
    let bufCount = buf.count
    while true {
        let n = buf.withUnsafeMutableBytes { Glibc.read(fromFd, $0.baseAddress!, bufCount) }
        if n <= 0 { break }
        var written = 0
        var failed = false
        while written < n {
            let w = buf.withUnsafeBytes { Glibc.write(toFd, $0.baseAddress! + written, n - written) }
            if w <= 0 {
                failed = true
                break
            }
            written += w
        }
        if failed { break }
    }
}

/// Interop: the Swift runtime against the Go stdio harnesses (cross-
/// language wire compatibility). Skips when Go is unavailable.
/// Mirrors python/tests/test_interop.py.
func TestInterop() throws {
    signal(SIGPIPE, SIG_IGN)
    let root = Root()
    let tmp = "/tmp/grpcdc_swift_interop"
    try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    let serverBin = "\(tmp)/echo_server_stdio"
    guard BuildGo(root, serverBin, "./examples/echo_server_stdio") else {
        print("TestInterop SKIP (no go)")
        return
    }

    do {
        let server = try Proc([serverBin], pipeStderr: false)
        defer { server.Kill() }
        let transport = StdioTransport(writerFd: server.stdinFd, readerFd: server.stdoutFd)
        let client = EchoGrpcDc.EchoClient(Channel(transport))

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
        try Check(indexes == [0, 1, 2], "server stream: \(indexes)")

        let joined = try client.ClientStream([EchoRequest("a", 0), EchoRequest("b", 0), EchoRequest("c", 0)])
        try Check(joined.message == "a+b+c", "client stream: \(joined)")

        let bidi = try client.Bidi([EchoRequest("x", 0), EchoRequest("y", 0)])
        var echoed: [String] = []
        while true {
            do {
                echoed.append(try bidi.Recv().message)
            } catch is EndOfStreamError {
                break
            }
        }
        try Check(echoed == ["x", "y"], "bidi: \(echoed)")

        do {
            _ = try client.Unary(EchoRequest("fail", 0))
            try Check(false, "fail should throw")
        } catch let e as StatusException {
            try Check(e.code == 3, "fail status: \(e)")
        }
    }

    // Reverse: Go client harness against the Swift stdio server.
    let clientBin = "\(tmp)/echo_client_stdio"
    guard BuildGo(root, clientBin, "./examples/echo_client_stdio") else {
        print("TestInterop partial SKIP (client build)")
        return
    }
    let swiftServer = "\(root)/swift/build/echo_server_stdio"
    guard FileExists(swiftServer) else {
        print("TestInterop partial SKIP (swift server not built)")
        return
    }
    let swift = try Proc([swiftServer], pipeStderr: false)
    defer { swift.Kill() }
    let goClient = try Proc([clientBin])
    defer { goClient.Kill() }
    let queue = DispatchQueue.global()
    let group = DispatchGroup()
    group.enter()
    queue.async {
        Pump(goClient.stdoutFd, swift.stdinFd)
        group.leave()
    }
    group.enter()
    queue.async {
        Pump(swift.stdoutFd, goClient.stdinFd)
        group.leave()
    }
    let exitCode = goClient.WaitForExit(seconds: 60)
    try Check(exitCode == 0, "go client harness exit: \(exitCode)")
    swift.Kill()
    _ = group.wait(timeout: .now() + 10)
    let stderrText = LineReader(goClient.stderrFd).ReadAll()
    try Check(stderrText.contains("unary=echo: hello"), "go client unary: \(stderrText)")
    try Check(stderrText.contains("server_stream=tick#0,tick#1,tick#2"), "go client stream: \(stderrText)")
    try Check(stderrText.contains("client_stream=a+b+c"), "go client client-stream: \(stderrText)")
    try Check(stderrText.contains("bidi=x,y"), "go client bidi: \(stderrText)")
    print("TestInterop OK")
}
