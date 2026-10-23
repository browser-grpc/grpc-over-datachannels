import Foundation

// Single-threaded inline pump mode: an endpoint whose transport
// offers TryRecv runs without read/dispatch threads — stream
// waits pump the transport themselves. This is the mode the
// native Embedded Swift WASM client uses. The client-inline
// half talks to an ordinary threaded server; the server-inline
// half is driven by explicit PollOnce calls while a threaded
// client call runs in the background.

private final class QueueTransport: Transport {
    private let inbox: BlockingQueue<[UInt8]>
    private let outbox: BlockingQueue<[UInt8]>
    private let inline: Bool
    private var closedFlag = false

    init(inbox: BlockingQueue<[UInt8]>, outbox: BlockingQueue<[UInt8]>, inline: Bool) {
        self.inbox = inbox
        self.outbox = outbox
        self.inline = inline
    }

    func Send(_ data: [UInt8]) throws {
        if closedFlag { throw EndOfStreamError() }
        outbox.Add(data)
    }

    func Recv() throws -> [UInt8] {
        guard let data = inbox.Take() else { throw EndOfStreamError() }
        return data
    }

    func Close() {
        closedFlag = true
        inbox.Close()
    }

    var HasTryRecv: Bool { inline }

    func TryRecv() -> TryRecvResult {
        if !inline { return .wouldBlock }
        // Bounded wait so an inline pump loop re-checks
        // deadlines instead of busy-spinning.
        let result = inbox.Take(until: Date().addingTimeInterval(0.002))
        if let item = result.item { return .message(item) }
        return result.timedOut ? .wouldBlock : .closed
    }
}

private func QueuePair(clientInline: Bool, serverInline: Bool) -> (Transport, Transport) {
    let aToB = BlockingQueue<[UInt8]>()
    let bToA = BlockingQueue<[UInt8]>()
    return (QueueTransport(inbox: bToA, outbox: aToB, inline: clientInline),
            QueueTransport(inbox: aToB, outbox: bToA, inline: serverInline))
}

private func Req(_ message: String, _ count: Int32) -> EchoRequest {
    EchoRequest(message, count)
}

private final class SlowEcho: EchoGrpcDc.EchoServer {
    private let inner = EchoServiceImpl()

    func Unary(_ ctx: Endpoint.CallContext, _ req: EchoRequest) throws -> EchoResponse {
        Thread.sleep(forTimeInterval: 0.4)
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

private final class ResultBox<T> {
    private let lock = NSLock()
    private var value: T?
    private var done = false

    func Set(_ value: T) {
        lock.lock()
        self.value = value
        done = true
        lock.unlock()
    }

    var IsDone: Bool {
        lock.lock()
        defer { lock.unlock() }
        return done
    }

    func Get() -> T? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private func RunClientInline() throws {
    let (a, b) = QueuePair(clientInline: true, serverInline: false)
    let server = Server()
    EchoGrpcDc.RegisterEchoServer(server, SlowEcho())
    server.ServeTransport(b)
    let channel = Channel(a)
    try Check(channel.endpoint.IsInlinePump(), "client endpoint is inline")
    let client = EchoGrpcDc.EchoClient(channel)

    let unary = try client.Unary(Req("hello", 0), nil, 5.0)
    try Check(unary.message == "echo: hello", "inline unary: \(unary)")

    let stream = try client.ServerStream(Req("tick", 3))
    var indexes: [Int32] = []
    while true {
        do {
            indexes.append(try stream.Recv().index)
        } catch is EndOfStreamError {
            break
        }
    }
    try Check(indexes == [0, 1, 2], "inline server stream")

    let joined = try client.ClientStream([Req("a", 0), Req("b", 0)])
    try Check(joined.message == "a+b", "inline client stream: \(joined)")

    let bidi = try client.Bidi([Req("x", 0), Req("y", 0)])
    var echoed: [String] = []
    while true {
        do {
            echoed.append(try bidi.Recv().message)
        } catch is EndOfStreamError {
            break
        }
    }
    try Check(echoed == ["x", "y"], "inline bidi")

    let start = Date()
    do {
        _ = try client.Unary(Req("hello", 0), nil, 0.05)
        try Check(false, "expected inline deadline")
    } catch let e as StatusException {
        try Check(e.code == Wire.CodeDeadlineExceeded, "inline deadline code \(e.code)")
    }
    try Check(Date().timeIntervalSince(start) < 0.35, "inline deadline fires fast")
}

private func RunServerInline() throws {
    let (a, b) = QueuePair(clientInline: false, serverInline: true)
    let server = Server()
    EchoGrpcDc.RegisterEchoServer(server, EchoServiceImpl())
    let serverEndpoint = server.ServeTransport(b)
    try Check(serverEndpoint.IsInlinePump(), "server endpoint is inline")
    let client = EchoGrpcDc.EchoClient(Channel(a))

    let unaryBox = ResultBox<EchoResponse>()
    let unaryThread = Thread {
        if let resp = try? client.Unary(Req("hello", 0), nil, 5.0) {
            unaryBox.Set(resp)
        }
    }
    unaryThread.start()
    while !unaryBox.IsDone {
        serverEndpoint.PollOnce()
        Thread.sleep(forTimeInterval: 0.001)
    }
    try Check(unaryBox.Get()?.message == "echo: hello", "inline server unary")

    let joinedBox = ResultBox<EchoResponse>()
    let joinedThread = Thread {
        if let resp = try? client.ClientStream([Req("a", 0), Req("b", 0)], nil, 5.0) {
            joinedBox.Set(resp)
        }
    }
    joinedThread.start()
    while !joinedBox.IsDone {
        serverEndpoint.PollOnce()
        Thread.sleep(forTimeInterval: 0.001)
    }
    try Check(joinedBox.Get()?.message == "a+b", "inline server client stream")
}

func TestInlinePump() throws {
    try RunClientInline()
    try RunServerInline()
    print("TestInlinePump OK")
}
