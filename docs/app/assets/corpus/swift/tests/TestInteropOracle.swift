import Foundation

#if canImport(Glibc)
import Glibc
#endif

/// Interop client grading: the generated Swift TestService client
/// runs the canonical grpc interop cases (generated table:
/// InteropCases) against the official grpc-go TestServiceServer,
/// through the bridge (dc-to-http2, stdio = DataChannel). Mirrors
/// the Java/C#/Kotlin/Scala/Dart interop oracle suites. Skips when
/// the oracle server binary is not built (Dockerfile.ci builds it).

private func interopPayload(_ size: Int) -> Payload {
    let p = Payload()
    p.body = [UInt8](repeating: 0, count: size)
    return p
}

private func interopStreamRequest(_ respSizes: [Int], _ payloadSize: Int) -> StreamingOutputCallRequest {
    let req = StreamingOutputCallRequest()
    req.payload = interopPayload(payloadSize)
    req.responseParameters = respSizes.map { size in
        let p = ResponseParameters()
        p.size = Int32(size)
        return p
    }
    return req
}

private func expectStatus(_ code: Int, _ message: String, _ what: String, _ call: () throws -> Void) throws {
    do {
        try call()
    } catch let e as StatusException {
        try Check(e.code == code, "\(what): code \(e.code) != \(code)")
        if !message.isEmpty {
            try Check(e.message == message, "\(what): message '\(e.message)' != '\(message)'")
        }
        return
    }
    throw TestFailure(message: "\(what): expected status \(code), call succeeded")
}

private func runInteropCases(_ channel: Channel, _ client: TestGrpcDc.TestServiceClient, _ unimpl: TestGrpcDc.UnimplementedServiceClient) throws {
    for row in InteropCases.Cases {
        let name = row.name
        let kind = row.kind
        switch kind {
        case "EMPTY":
            _ = try client.EmptyCall(Empty())
        case "LARGE_UNARY":
            let req = SimpleRequest()
            req.responseSize = Int32(row.respSizes[0])
            req.payload = interopPayload(row.reqSizes[0])
            let resp = try client.UnaryCall(req)
            try Check(resp.payload!.body.count == row.respSizes[0], "\(name): body \(resp.payload!.body.count)")
        case "CLIENT_STREAMING":
            let reqs = row.reqSizes.map { size -> StreamingInputCallRequest in
                let r = StreamingInputCallRequest()
                r.payload = interopPayload(size)
                return r
            }
            let resp = try client.StreamingInputCall(reqs)
            let total = row.reqSizes.reduce(0, +)
            try Check(resp.aggregatedPayloadSize == Int32(total), "\(name): aggregated \(resp.aggregatedPayloadSize) != \(total)")
        case "SERVER_STREAMING":
            let stream = try client.StreamingOutputCall(interopStreamRequest(row.respSizes, 0))
            for size in row.respSizes {
                let resp = try stream.Recv()
                try Check(resp.payload!.body.count == size, "\(name): body \(resp.payload!.body.count) != \(size)")
            }
            do {
                _ = try stream.Recv()
                throw TestFailure(message: "\(name): expected EOF")
            } catch let e as TestFailure {
                throw e
            } catch {
                // end of stream (EOF from Recv)
            }
            stream.Close()
        case "PING_PONG":
            let reqs = row.respSizes.indices.map { interopStreamRequest([row.respSizes[$0]], row.reqSizes[$0]) }
            let stream = try client.FullDuplexCall(reqs)
            for size in row.respSizes {
                let resp = try stream.Recv()
                try Check(resp.payload!.body.count == size, "\(name): body \(resp.payload!.body.count) != \(size)")
            }
            stream.Close()
        case "EMPTY_STREAM":
            let stream = try client.FullDuplexCall([])
            do {
                _ = try stream.Recv()
                throw TestFailure(message: "\(name): expected EOF")
            } catch let e as TestFailure {
                throw e
            } catch {
                // end of stream
            }
            stream.Close()
        case "CUSTOM_METADATA":
            // Upstream custom_metadata, duplex leg (mirrors the Java runner).
            let trailingBin = Data([0x0a, 0x0b, 0x0a, 0x0b, 0x0a, 0x0b]).base64EncodedString()
            let md = [
                "x-grpc-test-echo-initial": "test_initial_metadata_value",
                "x-grpc-test-echo-trailing-bin": trailingBin,
            ]
            let stream = try client.FullDuplexCall([interopStreamRequest([1], 1)], md)
            let resp = try stream.Recv()
            try Check(resp.payload!.body.count == 1, "\(name): body")
            do {
                _ = try stream.Recv()
                throw TestFailure(message: "\(name): expected EOF")
            } catch let e as TestFailure {
                throw e
            } catch {
                // end of stream: trailers now readable
            }
            try Check(stream.Headers?["x-grpc-test-echo-initial"] == "test_initial_metadata_value",
                      "\(name): initial \(String(describing: stream.Headers))")
            try Check(stream.Trailers?["x-grpc-test-echo-trailing-bin"] == trailingBin,
                      "\(name): trailing \(String(describing: stream.Trailers))")
            stream.Close()
        case "STATUS_UNARY":
            let req = SimpleRequest()
            req.responseStatus = EchoStatus(Int32(row.statusCode), row.statusMessage)
            try expectStatus(row.statusCode, row.statusMessage, name) { _ = try client.UnaryCall(req) }
        case "STATUS_DUPLEX":
            let req = interopStreamRequest([0], 0)
            req.responseStatus = EchoStatus(Int32(row.statusCode), row.statusMessage)
            try expectStatus(row.statusCode, row.statusMessage, name) {
                let stream = try client.FullDuplexCall([req])
                _ = try stream.Recv()
            }
        case "SPECIAL_STATUS":
            let req = SimpleRequest()
            req.responseStatus = EchoStatus(Int32(row.statusCode), row.statusMessage)
            try expectStatus(row.statusCode, row.statusMessage, name) { _ = try client.UnaryCall(req) }
        case "CANCEL_AFTER_BEGIN":
            // Begin a client-streaming call and cancel it before
            // sending any request: the pending Recv must report
            // CANCELLED.
            let stream = try channel.OpenStream("/grpc.testing.TestService/StreamingInputCall")
            stream.Cancel()
            try expectStatus(row.statusCode, "", name) { try stream.Recv(StreamingInputCallResponse()) }
        case "CANCEL_AFTER_FIRST":
            // Duplex call (no half-close): the server answers the
            // one request, then waits for more input, so the cancel
            // deterministically lands mid-call (same shape as the
            // Python/JS suites).
            let stream = try channel.OpenStream("/grpc.testing.TestService/FullDuplexCall")
            try stream.Send(interopStreamRequest([row.respSizes[0]], 1))
            let resp = StreamingOutputCallResponse()
            try stream.Recv(resp)
            try Check(resp.payload!.body.count == row.respSizes[0], "\(name): body \(resp.payload!.body.count)")
            stream.Cancel()
            try expectStatus(row.statusCode, "", name) { try stream.Recv(StreamingOutputCallResponse()) }
        case "TIMEOUT_SLEEPING":
            let req = StreamingOutputCallRequest()
            req.payload = interopPayload(0)
            req.responseParameters = row.respSizes.map { size in
                let p = ResponseParameters()
                p.size = Int32(size)
                p.intervalUs = 1000000
                return p
            }
            try expectStatus(row.statusCode, "", name) {
                let stream = try client.StreamingOutputCall(req, nil, 0.1)
                _ = try stream.Recv()
            }
        case "UNIMPLEMENTED_METHOD":
            try expectStatus(row.statusCode, "", name) { _ = try client.UnimplementedCall(Empty()) }
        case "UNIMPLEMENTED_SERVICE":
            try expectStatus(row.statusCode, "", name) { _ = try unimpl.UnimplementedCall(Empty()) }
        default:
            throw TestFailure(message: "unknown interop kind \(kind)")
        }
        print("interop case ok: \(name)")
    }
}

// Compression rows (upstream client_compressed_unary,
// client_compressed_streaming, server_compressed_unary,
// server_compressed_streaming): the DataChannel wire is
// compression-free; the client declares grpc-encoding: gzip
// and the bridge gzips request messages on the HTTP/2 hop,
// decompressing responses the same way.
private func runCompressionCases(_ client: TestGrpcDc.TestServiceClient) throws {
    let gzip = ["grpc-encoding": "gzip"]
    do {
        let req = SimpleRequest()
        req.responseSize = 31415
        req.payload = interopPayload(271828)
        req.expectCompressed = BoolValue(true)
        let resp = try client.UnaryCall(req, gzip)
        try Check(resp.payload!.body.count == 31415, "client_compressed_unary: body")
        print("interop case ok: client_compressed_unary")
    }
    do {
        let sizes = [27182, 8, 1828, 45904]
        let reqs = sizes.map { size -> StreamingInputCallRequest in
            let r = StreamingInputCallRequest()
            r.payload = interopPayload(size)
            r.expectCompressed = BoolValue(true)
            return r
        }
        let resp = try client.StreamingInputCall(reqs, gzip)
        try Check(resp.aggregatedPayloadSize == Int32(sizes.reduce(0, +)),
                  "client_compressed_streaming: aggregated \(resp.aggregatedPayloadSize)")
        print("interop case ok: client_compressed_streaming")
    }
    do {
        let req = SimpleRequest()
        req.responseSize = 31415
        req.payload = interopPayload(271828)
        req.responseCompressed = BoolValue(true)
        let resp = try client.UnaryCall(req)
        try Check(resp.payload!.body.count == 31415, "server_compressed_unary: body")
        print("interop case ok: server_compressed_unary")
    }
    do {
        let sizes = [31415, 9, 2653, 58979]
        let req = StreamingOutputCallRequest()
        req.payload = interopPayload(0)
        req.responseParameters = sizes.map { size in
            let p = ResponseParameters()
            p.size = Int32(size)
            p.compressed = BoolValue(true)
            return p
        }
        let stream = try client.StreamingOutputCall(req)
        for size in sizes {
            let resp = try stream.Recv()
            try Check(resp.payload!.body.count == size,
                      "server_compressed_streaming: body \(resp.payload!.body.count)")
        }
        stream.Close()
        print("interop case ok: server_compressed_streaming")
    }
}

// ORCA rows (upstream orca_per_rpc / orca_oob): per-RPC the
// report returns as the serialized OrcaLoadReport in the
// endpoint-load-metrics-bin trailer (base64 -bin value); OOB the
// value fed through FullDuplexCall comes back on the
// OpenRcaService StreamCoreMetrics stream.
private func runOrcaCases(_ channel: Channel, _ client: TestGrpcDc.TestServiceClient) throws {
    let req = SimpleRequest()
    req.orcaPerQueryReport = TestOrcaReport(0.8210, 0.5847, ["cost": 3456.32], ["util": 0.30499])
    let stream = try channel.ServerStream("/grpc.testing.TestService/UnaryCall", req)
    let resp = SimpleResponse()
    try stream.Recv(resp)
    do {
        try stream.Recv(SimpleResponse())
        throw TestFailure(message: "orca_per_rpc: expected EOF")
    } catch is EndOfStreamError {
        // end of stream: trailers now readable
    }
    let encoded = stream.trailers?["endpoint-load-metrics-bin"]
    try Check(encoded != nil, "orca_per_rpc: no endpoint-load-metrics-bin trailer")
    var b64 = encoded!
    while b64.count % 4 != 0 { b64 += "=" }
    let data = Data(base64Encoded: b64)!
    let report = OrcaLoadReport()
    report.UnmarshalDc([UInt8](data))
    try Check(report.cpuUtilization == 0.8210 && report.memUtilization == 0.5847
        && report.requestCost["cost"] == 3456.32 && report.utilization["util"] == 0.30499,
        "orca_per_rpc: report \(report.cpuUtilization)/\(report.memUtilization)")
    stream.Close()
    print("interop case ok: orca_per_rpc")

    let feedReq = StreamingOutputCallRequest()
    feedReq.orcaOobReport = TestOrcaReport(0.9, 0.85, [:], ["util": 0.5])
    let feed = try client.FullDuplexCall([feedReq])
    do {
        while true { _ = try feed.Recv() }
    } catch is EndOfStreamError {
        // feed call completed
    }
    feed.Close()
    let orca = OrcaGrpcDc.OpenRcaServiceClient(channel)
    let metrics = try orca.StreamCoreMetrics(OrcaLoadReportRequest())
    var matched = false
    let deadline = Date().addingTimeInterval(30)
    while !matched && Date() < deadline {
        let got = try metrics.Recv()
        matched = got.cpuUtilization == 0.9 && got.memUtilization == 0.85
            && got.utilization["util"] == 0.5
    }
    metrics.Close()
    try Check(matched, "orca_oob: no matching OOB report within 30s")
    print("interop case ok: orca_oob")
}

func TestInteropOracle() throws {
    let root = Root()
    let serverBin = "\(root)/oracle/go-interop/interop-server"
    if !FileManager.default.isExecutableFile(atPath: serverBin) {
        print("TestInteropOracle SKIP (go interop server not built)")
        return
    }
    let port = try freePort()
    let server = Process()
    server.executableURL = URL(fileURLWithPath: serverBin)
    server.arguments = ["-port", "\(port)"]
    server.standardOutput = Pipe()
    server.standardError = Pipe()
    try server.run()
    defer { server.terminate() }

    // The Go server prints no readiness line; poll the port.
    let deadline = Date().addingTimeInterval(30)
    var ready = false
    while Date() < deadline {
        if tcpConnectable(port) {
            ready = true
            break
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
    try Check(ready, "go interop server did not start")

    let bridge = Process()
    bridge.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    bridge.arguments = ["node", "\(root)/oracle/bridge.mjs", "dc-to-http2", "--grpc", "127.0.0.1:\(port)"]
    let bridgeIn = Pipe()
    let bridgeOut = Pipe()
    bridge.standardInput = bridgeIn
    bridge.standardOutput = bridgeOut
    bridge.standardError = Pipe()
    try bridge.run()
    defer { bridge.terminate() }

    let transport = StdioTransport(
        writerFd: bridgeIn.fileHandleForWriting.fileDescriptor,
        readerFd: bridgeOut.fileHandleForReading.fileDescriptor)
    let channel = Channel(transport)
    let client = TestGrpcDc.TestServiceClient(channel)
    try runInteropCases(channel, client, TestGrpcDc.UnimplementedServiceClient(channel))
    try runCompressionCases(client)
    try runOrcaCases(channel, client)
    print("TestInteropOracle OK")
}

private func freePort() throws -> Int {
    let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    if fd < 0 { throw TestFailure(message: "socket() failed") }
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            Glibc.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    if bound != 0 { throw TestFailure(message: "bind() failed") }
    var actual = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &actual) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            Glibc.getsockname(fd, sa, &len)
        }
    }
    if named != 0 { throw TestFailure(message: "getsockname() failed") }
    return Int(in_port_t(bigEndian: actual.sin_port))
}

private func tcpConnectable(_ port: Int) -> Bool {
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(port).bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    if fd < 0 { return false }
    defer { close(fd) }
    let result = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            Glibc.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    return result == 0
}
