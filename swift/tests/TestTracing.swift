import Foundation

// Tracing: nested callee call joins the trace via the bound channel.

private struct StartRec {
    let kind: String
    let method: String
    let traceId: String
    let spanId: String
    let parentSpanId: String
}

private final class Recorder: Tracing.Tracer {
    var starts: [StartRec] = []
    var endDurations: [Double] = []

    func OnStart(_ kind: String, _ method: String, _ traceId: String, _ spanId: String, _ parentSpanId: String) {
        starts.append(StartRec(kind: kind, method: method, traceId: traceId, spanId: spanId, parentSpanId: parentSpanId))
    }

    func OnEnd(_ kind: String, _ method: String, _ traceId: String, _ spanId: String, _ status: String, _ durationMs: Double) {
        endDurations.append(durationMs)
    }
}

private final class Front: EchoGrpcDc.EchoServer {
    private let inner = EchoServiceImpl()
    private let downstreamChannel: Channel
    var seenSpan: String?

    init(_ downstreamChannel: Channel) {
        self.downstreamChannel = downstreamChannel
    }

    func Unary(_ ctx: Endpoint.CallContext, _ req: EchoRequest) throws -> EchoResponse {
        seenSpan = ctx.traceContext?.spanId
        let bound = EchoGrpcDc.EchoClient(downstreamChannel.WithTraceContext(ctx.traceContext))
        return try bound.Unary(EchoRequest("nested", 0))
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

func TestTracing() throws {
    let rec = Recorder()
    Tracing.SetTracer(rec)
    defer { Tracing.SetTracer(nil) }

    let backPair = MemoryTransport.Pair()
    let back = Server()
    EchoGrpcDc.RegisterEchoServer(back, EchoServiceImpl())
    back.ServeTransport(backPair.1)
    let downstreamChannel = Channel(backPair.0)

    let front = Front(downstreamChannel)
    let pair = MemoryTransport.Pair()
    let frontServer = Server()
    EchoGrpcDc.RegisterEchoServer(frontServer, front)
    frontServer.ServeTransport(pair.1)
    let client = EchoGrpcDc.EchoClient(Channel(pair.0))

    let resp = try client.Unary(EchoRequest("hello", 0))
    try Check(resp.message == "echo: nested", "resp \(resp.message)")

    let starts = rec.starts
    try Check(starts.count == 4, "starts \(starts.count)")
    try Check(starts.map { $0.kind } == ["client", "server", "client", "server"], "kinds")
    try Check(starts.allSatisfy { $0.traceId == starts[0].traceId }, "trace ids")
    try Check(starts[1].parentSpanId == starts[0].spanId, "server parent")
    try Check(starts[2].parentSpanId == starts[1].spanId, "inner client parent")
    try Check(starts[3].parentSpanId == starts[2].spanId, "inner server parent")
    try Check(front.seenSpan == starts[1].spanId, "ctx span")
    try Check(rec.endDurations.count == 4 && rec.endDurations.allSatisfy { $0 >= 0 }, "durations")
    print("TestTracing OK")
}
