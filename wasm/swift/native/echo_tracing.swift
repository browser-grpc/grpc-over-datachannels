// Browser tracing entry point (native Swift/Wasm runtime):
// runs a nested call chain entirely in the worker — client ->
// front callee -> downstream service over in-memory transports —
// with a recording span observer, and reports the spans as JSON
// via on_result so the Playwright driver can assert the trace.
// The inline pump is single-threaded, so client transports poll
// their peer server endpoint on TryRecv (cooperative pumping).

private final class ByteQueue {
    var items: [[UInt8]] = []
}

private final class QueueTransport: Transport {
    private let inbox: ByteQueue
    private let outbox: ByteQueue
    var pollPeer: () -> Void = {}

    init(inbox: ByteQueue, outbox: ByteQueue) {
        self.inbox = inbox
        self.outbox = outbox
    }

    func Send(_ data: [UInt8]) throws {
        outbox.items.append(data)
    }

    func Recv() throws -> [UInt8] {
        while true {
            if !inbox.items.isEmpty { return inbox.items.removeFirst() }
            pollPeer()
        }
    }

    func Close() {}

    var HasTryRecv: Bool { true }

    func TryRecv() -> TryRecvResult {
        pollPeer()
        if inbox.items.isEmpty { return .wouldBlock }
        return .message(inbox.items.removeFirst())
    }
}

private func queuePair() -> (QueueTransport, QueueTransport) {
    let aToB = ByteQueue()
    let bToA = ByteQueue()
    return (QueueTransport(inbox: bToA, outbox: aToB),
            QueueTransport(inbox: aToB, outbox: bToA))
}

private struct StartRec {
    let kind: String
    let traceId: String
    let spanId: String
    let parentSpanId: String
}

private final class Recorder: Tracing.Tracer {
    var starts: [StartRec] = []
    var endKinds: [String] = []

    func OnStart(_ kind: String, _ method: String, _ traceId: String, _ spanId: String, _ parentSpanId: String) {
        starts.append(StartRec(kind: kind, traceId: traceId, spanId: spanId, parentSpanId: parentSpanId))
    }

    func OnEnd(_ kind: String, _ method: String, _ traceId: String, _ spanId: String, _ status: String, _ durationMs: Double) {
        // Embedded Swift (wasm) recurses formatting Int/Double values
        // into strings, so ends are reported as kind strings only;
        // durations are covered by the native Swift tracing suite.
        endKinds.append(kind)
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
        let r = try bound.Unary(EchoRequest("nested", 0))
        return r
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

private func reportTracing(_ text: String) {
    let bytes = [UInt8](text.utf8)
    let safe = bytes.isEmpty ? [0] : bytes
    safe.withUnsafeBufferPointer { b in
        onResult(b.baseAddress!, bytes.count)
    }
}

@_cdecl("run_echo_tracing")
public func run_echo_tracing() {
    let recorder = Recorder()
    Tracing.SetTracer(recorder)
    defer { Tracing.SetTracer(nil) }

    let (a2, b2) = queuePair()
    let back = Server()
    EchoGrpcDc.RegisterEchoServer(back, EchoServiceImpl())
    let backEp = back.ServeTransport(b2)
    a2.pollPeer = { backEp.PollOnce() }
    let downstreamChannel = Channel(a2)

    let front = Front(downstreamChannel)
    let (a, b) = queuePair()
    let frontServer = Server()
    EchoGrpcDc.RegisterEchoServer(frontServer, front)
    let frontEp = frontServer.ServeTransport(b)
    a.pollPeer = { frontEp.PollOnce() }
    let client = EchoGrpcDc.EchoClient(Channel(a))

    do {
        let resp = try client.Unary(EchoRequest("hello", 0))
        let startsJson = recorder.starts
            .map { "[\"\($0.kind)\",\"\($0.traceId)\",\"\($0.spanId)\",\"\($0.parentSpanId)\"]" }
            .joined(separator: ",")
        let endsJson = recorder.endKinds
            .map { "\"\($0)\"" }
            .joined(separator: ",")
        reportTracing("{\"message\":\"\(resp.message)\",\"seenSpan\":\"\(front.seenSpan ?? "")\",\"starts\":[\(startsJson)],\"ends\":[\(endsJson)]}")
    } catch {
        reportTracing("{\"error\":\"\(error)\"}")
    }
}
