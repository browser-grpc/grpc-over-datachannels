import Foundation

private func Req(_ message: String, _ count: Int32) -> EchoRequest {
    EchoRequest(message, count)
}

private func Setup() -> EchoGrpcDc.EchoClient {
    let (a, b) = MemoryTransport.Pair()
    let server = Server()
    EchoGrpcDc.RegisterEchoServer(server, EchoServiceImpl())
    server.ServeTransport(b)
    return EchoGrpcDc.EchoClient(Channel(a))
}

/// Async implementation used to test RegisterEchoServerAsync.
private final class AsyncEchoService: EchoGrpcDc.EchoServerAsync {
    private let inner = EchoServiceImpl()

    func UnaryAsync(_ ctx: Endpoint.CallContext, _ req: EchoRequest) async throws -> EchoResponse {
        try await Task.sleep(nanoseconds: 1_000_000)
        return try inner.Unary(ctx, req)
    }
    func ServerStreamAsync(_ req: EchoRequest, _ stream: EchoGrpcDc.EchoServerStreamServer) async throws {
        try inner.ServerStream(req, stream)
    }
    func ClientStreamAsync(_ stream: EchoGrpcDc.EchoClientStreamServer) async throws {
        try inner.ClientStream(stream)
    }
    func BidiAsync(_ stream: EchoGrpcDc.EchoBidiServer) async throws {
        try inner.Bidi(stream)
    }
}

private func RunAsync() throws {
    // Async client surface against the sync loopback server.
    let client = Setup()

    let unary = try RunBlocking { try await client.UnaryAsync(Req("hello", 0)) }
    try Check(unary.message == "echo: hello", "async unary: \(unary)")

    var streamed: [EchoResponse] = []
    try RunBlocking {
        for try await resp in client.ServerStreamAsync(Req("tick", 3)) {
            streamed.append(resp)
        }
    }
    try Check(streamed.count == 3 && streamed[0].index == 0 && streamed[2].index == 2,
              "async server stream")

    let joined = try RunBlocking { try await client.ClientStreamAsync([Req("a", 0), Req("b", 0)]) }
    try Check(joined.message == "a+b", "async client stream: \(joined)")

    var echoed: [EchoResponse] = []
    try RunBlocking {
        for try await resp in client.BidiAsync([Req("x", 0), Req("y", 0)]) {
            echoed.append(resp)
        }
    }
    try Check(echoed.count == 2 && echoed[1].message == "y", "async bidi")

    // Async server registration: async impl served over loopback.
    let (a, b) = MemoryTransport.Pair()
    let server = Server()
    EchoGrpcDc.RegisterEchoServerAsync(server, AsyncEchoService())
    server.ServeTransport(b)
    let client2 = EchoGrpcDc.EchoClient(Channel(a))
    let resp = try client2.Unary(Req("hello", 0))
    try Check(resp.message == "echo: hello", "async server unary: \(resp)")
}

/// Loopback end-to-end: all four shapes, error status, metadata.
func TestEcho() throws {
    let client = Setup()

    let unary = try client.Unary(Req("hello", 0))
    try Check(unary.message == "echo: hello" && unary.index == 0, "unary: \(unary)")

    let stream = try client.ServerStream(Req("tick", 3))
    var indexes: [Int32] = []
    while true {
        do {
            let resp = try stream.Recv()
            try Check(resp.message == "tick", "stream message: \(resp)")
            indexes.append(resp.index)
        } catch is EndOfStreamError {
            break
        }
    }
    try Check(indexes == [0, 1, 2], "stream indexes: \(indexes)")

    let joined = try client.ClientStream([Req("a", 0), Req("b", 0), Req("c", 0)])
    try Check(joined.message == "a+b+c" && joined.index == 3, "client stream: \(joined)")

    let bidi = try client.Bidi([Req("x", 0), Req("y", 0)])
    var echoed: [String] = []
    while true {
        do {
            echoed.append(try bidi.Recv().message)
        } catch is EndOfStreamError {
            break
        }
    }
    try Check(echoed == ["x", "y"], "bidi: \(echoed)")

    do {
        _ = try client.Unary(Req("fail", 0))
        try Check(false, "fail call should throw")
    } catch let e as StatusException {
        try Check(e.code == 3, "fail status: \(e)")
    }

    let withMd = try client.Unary(Req("hello", 0), ["x-echo": "meta"])
    try Check(withMd.message == "echo: hello [meta]", "metadata: \(withMd)")

    try RunAsync()
    print("TestEcho OK")
}
