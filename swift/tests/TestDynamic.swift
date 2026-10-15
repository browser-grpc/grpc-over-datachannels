import Foundation

private func WaitReady(_ reader: LineReader, _ needle: String) -> Bool {
    while let line = reader.ReadLine() {
        if line.contains(needle) { return true }
    }
    return false
}

private func LoadModel(_ root: String) -> Dynamic.FileModel? {
    let path = "\(root)/fixtures/echo_descriptor_set.bin"
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
    return try? Dynamic.ParseDescriptorSet([UInt8](data))
}

/// Dynamic (descriptor-driven) runtime: schemas consumed as data at
/// runtime, no generated stubs. Loopback plus the official grpc-java
/// oracle in both directions (the oracle is the runtime test bed).
func TestDynamic() throws {
    let root = Root()
    guard let model = LoadModel(root) else {
        print("TestDynamic SKIP (descriptor fixture missing)")
        return
    }

    // Generic codec + unknown-field retention round trip.
    let requestType = try model.Message(".echo.EchoRequest")
    let payload: [UInt8] = [0x0a, 0x02, 0x68, 0x69, 0x10, 0x02,
                            0x98, 0x06, 0x2a, 0xa2, 0x06, 0x01, 0x78]
    let decoded = try Dynamic.DecodeGeneric(requestType, payload, model)
    try Check(decoded.unknown.count == 2, "unknown retained: \(decoded.unknown.count)")
    try Check(try Dynamic.EncodeGeneric(requestType, decoded, model) == payload, "unknown round trip")

    // Loopback: dynamic client against dynamic server.
    do {
        let (a, b) = MemoryTransport.Pair()
        let server = Server()
        try Dynamic.RegisterDynamicService(server, model, "echo.Echo", DynamicEchoService())
        server.ServeTransport(b)
        try RunDynamicScenarios(Dynamic.DynamicClient(Channel(a), model), model)
    }

    guard let cp = JavaClasspath(root) else {
        print("TestDynamic OK (loopback; oracle skipped)")
        return
    }

    // Direction A: dynamic client -> bridge -> official server.
    let port = FreePort()
    let server = try Proc(["java", "-cp", cp, "dc.oracle.OracleServer", String(port)])
    defer { server.Kill() }
    guard WaitReady(LineReader(server.stderrFd), "READY") else {
        print("TestDynamic SKIP (oracle server did not start)")
        return
    }
    do {
        let bridge = try Proc(["node", "\(root)/oracle/bridge.mjs", "dc-to-http2", "--grpc", "127.0.0.1:\(port)"],
                              pipeStderr: false)
        defer { bridge.Kill() }
        let transport = StdioTransport(writerFd: bridge.stdinFd, readerFd: bridge.stdoutFd)
        try RunDynamicScenarios(Dynamic.DynamicClient(Channel(transport), model), model)
    }

    // Direction B: official client -> bridge -> dynamic server.
    let serverBin = "\(root)/swift/build/dynamic_echo_server_stdio"
    guard FileExists(serverBin) else {
        print("TestDynamic SKIP (swift dynamic server not built)")
        return
    }
    let portB = FreePort()
    let bridge = try Proc(["node", "\(root)/oracle/bridge.mjs", "http2-to-dc", "--port", String(portB),
                           "--target-cmd", serverBin])
    defer { bridge.Kill() }
    guard WaitReady(LineReader(bridge.stderrFd), "listening") else {
        print("TestDynamic SKIP (bridge did not start)")
        return
    }
    let clientProc = try Proc(["java", "-cp", cp, "dc.oracle.OracleClient", String(portB),
                               "\(root)/fixtures/oracle_scenarios.txt"])
    defer { clientProc.Kill() }
    let output = LineReader(clientProc.stdoutFd).ReadAll()
    let exitCode = clientProc.WaitForExit(seconds: 120)
    let errOutput = LineReader(clientProc.stderrFd).ReadAll()
    try Check(exitCode == 0, "oracle client failed:\n\(output)\(errOutput)")
    try Check(output.contains("ORACLE CLIENT: ALL OK"), "oracle client output:\n\(output)\(errOutput)")
    print("TestDynamic OK")
}
