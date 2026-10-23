import Foundation

// Deadlines: grpc-timeout propagation + DEADLINE_EXCEEDED
// enforcement; CallContext carries the remaining budget.

private final class SlowEcho: EchoGrpcDc.EchoServer {
    private let inner = EchoServiceImpl()
    var seenCtx: Endpoint.CallContext?

    func Unary(_ ctx: Endpoint.CallContext, _ req: EchoRequest) throws -> EchoResponse {
        seenCtx = ctx
        Thread.sleep(forTimeInterval: 0.4)
        return try inner.Unary(ctx, req)
    }

    func ServerStream(_ req: EchoRequest, _ stream: EchoGrpcDc.EchoServerStreamServer) throws {
        for i in 0..<max(0, req.count) {
            if i > 0 { Thread.sleep(forTimeInterval: 0.3) }
            try stream.Send(EchoResponse(req.message, i))
        }
    }

    func ClientStream(_ stream: EchoGrpcDc.EchoClientStreamServer) throws {
        try inner.ClientStream(stream)
    }

    func Bidi(_ stream: EchoGrpcDc.EchoBidiServer) throws {
        try inner.Bidi(stream)
    }
}

private func Req(_ message: String, _ count: Int32) -> EchoRequest {
    EchoRequest(message, count)
}

func TestDeadline() throws {
    try Check(Codec.ParseTimeout(Codec.EncodeTimeout(0.25)) == 0.25, "timeout round trip")
    try Check(Codec.ParseTimeout("10x") == nil, "junk timeout")

    let (a, b) = MemoryTransport.Pair()
    let server = Server()
    let slow = SlowEcho()
    EchoGrpcDc.RegisterEchoServer(server, slow)
    server.ServeTransport(b)
    let client = EchoGrpcDc.EchoClient(Channel(a))

    let start = Date()
    do {
        _ = try client.Unary(Req("hello", 0), nil, 0.05)
        try Check(false, "expected deadline")
    } catch let e as StatusException {
        try Check(e.code == Wire.CodeDeadlineExceeded, "code \(e.code)")
    }
    try Check(Date().timeIntervalSince(start) < 0.35, "deadline fires fast")

    try Check(slow.seenCtx != nil, "handler ran")
    try Check(slow.seenCtx?.metadata["grpc-timeout"] != nil, "grpc-timeout metadata")
    try Check(slow.seenCtx?.deadlineMs != nil, "ctx deadline")
    try Check(slow.seenCtx?.TimeRemaining() != nil, "ctx remaining")

    let stream = try client.ServerStream(Req("tick", 5), nil, 0.15)
    try Check(try stream.Recv().index == 0, "stream first")
    do {
        _ = try stream.Recv()
        try Check(false, "expected stream deadline")
    } catch let e as StatusException {
        try Check(e.code == Wire.CodeDeadlineExceeded, "stream code \(e.code)")
    }

    let joined = try client.ClientStream([Req("a", 0), Req("b", 0)], nil, 5.0)
    try Check(joined.message == "a+b", "generous timeout: \(joined)")
}
