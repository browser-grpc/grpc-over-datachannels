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

private func runInteropCases(_ client: TestGrpcDc.TestServiceClient, _ unimpl: TestGrpcDc.UnimplementedServiceClient) throws {
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
    try runInteropCases(TestGrpcDc.TestServiceClient(channel), TestGrpcDc.UnimplementedServiceClient(channel))
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
