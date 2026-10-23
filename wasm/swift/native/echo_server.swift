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
