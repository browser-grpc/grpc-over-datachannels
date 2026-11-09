// Browser test entry point (native runtime, server role):
// runs the generated Swift Echo server (swift/examples
// EchoGrpcDc.swift + EchoServiceImpl) over the real grpcdc
// runtime on a DataChannel transport, in a Web Worker. The
// endpoint runs in inline pump mode (TryRecv transport), so
// this loop drives dispatch; handler stream waits re-enter
// PollOnce. The JS client in the Node test drives the four
// call shapes plus a deadline the slow handler must miss.
// Mirrors wasm/swift/native/echo_client.swift.

private final class SlowEcho: EchoGrpcDc.EchoServer {
    private let inner = EchoServiceImpl()

    private func delay(_ req: EchoRequest) {
        if req.delayMs > 0 {
            // No sleep under Embedded Swift: busy-wait on the
            // monotonic runtime clock (GrpcTime.NowMs).
            let until = GrpcTime.NowMs() + Double(req.delayMs)
            while GrpcTime.NowMs() < until {}
        }
    }

    func Unary(_ ctx: Endpoint.CallContext, _ req: EchoRequest) throws -> EchoResponse {
        delay(req)
        return try inner.Unary(ctx, req)
    }

    func ServerStream(_ req: EchoRequest, _ stream: EchoGrpcDc.EchoServerStreamServer) throws {
        try inner.ServerStream(req, stream)
    }

    func ClientStream(_ stream: EchoGrpcDc.EchoClientStreamServer) throws {
        try inner.ClientStream(stream)
    }

    func Bidi(_ stream: EchoGrpcDc.EchoBidiServer) throws {
        try inner.Bidi(stream)
    }
}

@_cdecl("run_echo_server")
public func run_echo_server() {
    let server = Server()
    EchoGrpcDc.RegisterEchoServer(server, SlowEcho())
    let endpoint = server.ServeTransport(DcTransport())
    // PollOnce returns promptly when closed; the worker lives
    // for the page's lifetime, so pump forever.
    while true {
        endpoint.PollOnce()
    }
}

// Matrix tracing entry: same server with a recording span
// observer; every span start/end re-reports the cumulative
// spans via on_result so the page can expose them to the
// matrix driver (window.__spans) while the pump keeps running.
private struct MatrixServerStartRec {
    let kind: String
    let traceId: String
    let spanId: String
    let parentSpanId: String
}

private final class MatrixServerRecorder: Tracing.Tracer {
    var starts: [MatrixServerStartRec] = []
    var endKinds: [String] = []

    func OnStart(_ kind: String, _ method: String, _ traceId: String, _ spanId: String, _ parentSpanId: String) {
        starts.append(MatrixServerStartRec(kind: kind, traceId: traceId, spanId: spanId, parentSpanId: parentSpanId))
        report()
    }

    func OnEnd(_ kind: String, _ method: String, _ traceId: String, _ spanId: String, _ status: String, _ durationMs: Double) {
        // Embedded Swift (wasm) recurses formatting Int/Double
        // into strings, so ends are reported as kind strings only.
        endKinds.append(kind)
        report()
    }

    private func report() {
        let startsJson = starts
            .map { "[\"\($0.kind)\",\"\($0.traceId)\",\"\($0.spanId)\",\"\($0.parentSpanId)\"]" }
            .joined(separator: ",")
        let endsJson = endKinds
            .map { "\"\($0)\"" }
            .joined(separator: ",")
        let bytes = [UInt8]("{\"starts\":[\(startsJson)],\"ends\":[\(endsJson)]}".utf8)
        let safe = bytes.isEmpty ? [0] : bytes
        safe.withUnsafeBufferPointer { b in
            onResult(b.baseAddress!, bytes.count)
        }
    }
}

@_cdecl("run_echo_server_tracing")
public func run_echo_server_tracing() {
    Tracing.SetTracer(MatrixServerRecorder())
    let server = Server()
    EchoGrpcDc.RegisterEchoServer(server, SlowEcho())
    let endpoint = server.ServeTransport(DcTransport())
    while true {
        endpoint.PollOnce()
    }
}
