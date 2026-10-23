import Foundation

private func WaitReady(_ reader: LineReader, _ needle: String) -> Bool {
    while let line = reader.ReadLine() {
        if line.contains(needle) { return true }
    }
    return false
}

/// Oracle: official grpc-java, bridged over TCP<->DataChannel by
/// oracle/bridge.mjs, must agree with the Swift runtime on every case
/// of the generated scenario driver. Skips when the Java oracle or
/// Node bridge are unavailable (Dockerfile.ci provides both).
func TestOracle() throws {
    let root = Root()
    guard let cp = JavaClasspath(root) else {
        print("TestOracle SKIP (java oracle not built)")
        return
    }

    // Direction A: this client -> bridge -> official server.
    let port = FreePort()
    let server = try Proc(["java", "-cp", cp, "dc.oracle.OracleServer", String(port)])
    defer { server.Kill() }
    guard WaitReady(LineReader(server.stderrFd), "READY") else {
        print("TestOracle SKIP (oracle server did not start)")
        return
    }
    do {
        let bridge = try Proc(["node", "\(root)/oracle/bridge.mjs", "dc-to-http2", "--grpc", "127.0.0.1:\(port)"],
                              pipeStderr: false)
        defer { bridge.Kill() }
        let transport = StdioTransport(writerFd: bridge.stdinFd, readerFd: bridge.stdoutFd)
        let client = EchoGrpcDc.EchoClient(Channel(transport))
        try RunScenarios(client)
    }

    // Direction B: official client -> bridge -> this runtime's server.
    let serverBin = "\(root)/swift/build/echo_server_stdio"
    guard FileExists(serverBin) else {
        print("TestOracle SKIP (swift server not built)")
        return
    }
    let portB = FreePort()
    let bridge = try Proc(["node", "\(root)/oracle/bridge.mjs", "http2-to-dc", "--port", String(portB),
                           "--target-cmd", serverBin])
    defer { bridge.Kill() }
    guard WaitReady(LineReader(bridge.stderrFd), "listening") else {
        print("TestOracle SKIP (bridge did not start)")
        return
    }
    let clientProc = try Proc(["java", "-cp", cp, "dc.oracle.OracleClient", String(portB),
                               "\(root)/fixtures/oracle_scenarios.txt"])
    defer { clientProc.Kill() }
    let stdoutReader = LineReader(clientProc.stdoutFd)
    let output = stdoutReader.ReadAll()
    let exitCode = clientProc.WaitForExit(seconds: 120)
    let errOutput = LineReader(clientProc.stderrFd).ReadAll()
    try Check(exitCode == 0, "oracle client failed:\n\(output)\(errOutput)")
    try Check(output.contains("ORACLE CLIENT: ALL OK"), "oracle client output:\n\(output)\(errOutput)")
    print("TestOracle OK")
}
