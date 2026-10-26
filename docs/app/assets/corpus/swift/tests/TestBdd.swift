import Foundation

private func Req(_ message: String, _ count: Int32) -> EchoRequest {
    EchoRequest(message, count)
}

/// Thread-safe production counter for the stream-break scenario.
private final class BddProducedCounter {
    private let lock = NSLock()
    private var value = 0
    func inc() { lock.lock(); value += 1; lock.unlock() }
    func get() -> Int { lock.lock(); defer { lock.unlock() }; return value }
}

/// Slow counting handler for the stream-break scenario.
private final class BddCountingEchoService: EchoGrpcDc.EchoServer {
    private let counter: BddProducedCounter
    private let inner = EchoServiceImpl()
    init(_ counter: BddProducedCounter) { self.counter = counter }
    func Unary(_ ctx: Endpoint.CallContext, _ req: EchoRequest) throws -> EchoResponse {
        try inner.Unary(ctx, req)
    }
    func ServerStream(_ req: EchoRequest, _ stream: EchoGrpcDc.EchoServerStreamServer) throws {
        var i: Int32 = 0
        while i < req.count {
            counter.inc()
            try stream.Send(EchoResponse(req.message, i))
            i += 1
            Thread.sleep(forTimeInterval: 0.01)
        }
    }
    func ClientStream(_ stream: EchoGrpcDc.EchoClientStreamServer) throws {
        try inner.ClientStream(stream)
    }
    func Bidi(_ stream: EchoGrpcDc.EchoBidiServer) throws {
        try inner.Bidi(stream)
    }
}

/// BDD: interprets the generated behavior scenarios (BddScenarios,
/// generated from the BDD specification; prose in BDD.md) against a
/// loopback client+server — the executable examples.
func TestBdd() throws {
    let (a, b) = MemoryTransport.Pair()
    let server = Server()
    EchoGrpcDc.RegisterEchoServer(server, EchoServiceImpl())
    server.ServeTransport(b)
    let channel = Channel(a)
    let client = EchoGrpcDc.EchoClient(channel)

    for c in BddScenarios.Cases {
        switch c.kind {
        case "unary-trailer":
            let stream = try channel.ServerStream("/echo.Echo/Unary", Req(c.messages[0], 0),
                                                  ["x-echo-trailer": c.metadata])
            let resp = EchoResponse()
            try stream.Recv(resp)
            try Check(resp.message == c.expectMessage && resp.index == Int32(c.expectNum),
                      "\(c.name): \(resp)")
            var eof = false
            do {
                try stream.Recv(EchoResponse())
            } catch is EndOfStreamError {
                eof = true
            }
            try Check(eof, "\(c.name): expected EOF")
            try Check(stream.trailers?["x-echo-trailer"] == c.metadata,
                      "\(c.name): trailer \(String(describing: stream.trailers))")
        case "unary":
            let md: [String: String]? = c.metadata.isEmpty ? nil : ["x-echo": c.metadata]
            do {
                let resp = try client.Unary(Req(c.messages[0], 0), md)
                try Check(c.expectStatus < 0, "\(c.name): expected failure, got \(resp)")
                try Check(resp.message == c.expectMessage && resp.index == Int32(c.expectNum),
                          "\(c.name): \(resp)")
            } catch let e as StatusException {
                try Check(c.expectStatus >= 0 && e.code == Int32(c.expectStatus),
                          "\(c.name): status \(e), want \(c.expectStatus)")
            }
        case "server-stream":
            let stream = try client.ServerStream(Req(c.messages[0], Int32(c.count)))
            var got = 0
            while true {
                do {
                    let resp = try stream.Recv()
                    try Check(resp.message == c.expectMessage && resp.index == Int32(got),
                              "\(c.name): \(resp) at \(got)")
                    got += 1
                } catch is EndOfStreamError {
                    break
                }
            }
            try Check(got == c.expectNum, "\(c.name): got \(got), want \(c.expectNum)")
        case "client-stream":
            let resp = try client.ClientStream(c.messages.map { Req($0, 0) })
            try Check(resp.message == c.expectMessage && resp.index == Int32(c.expectNum),
                      "\(c.name): \(resp)")
        case "bidi":
            let stream = try client.Bidi(c.messages.map { Req($0, 0) })
            var got = 0
            while true {
                do {
                    let resp = try stream.Recv()
                    try Check(got < c.messages.count && resp.message == c.messages[got]
                                  && resp.index == Int32(got),
                              "\(c.name): \(resp) at \(got)")
                    got += 1
                } catch is EndOfStreamError {
                    break
                }
            }
            try Check(got == c.expectNum, "\(c.name): got \(got), want \(c.expectNum)")
        case "server-stream-fail":
            do {
                let stream = try client.ServerStream(Req(c.messages[0], Int32(c.count)))
                while true { _ = try stream.Recv() }
            } catch let e as StatusException {
                try Check(e.code == Int32(c.expectStatus),
                          "\(c.name): status \(e), want \(c.expectStatus)")
            } catch is EndOfStreamError {
                try Check(false, "\(c.name): expected failure, stream ended OK")
            }
        case "bidi-fail":
            do {
                let stream = try client.Bidi(c.messages.map { Req($0, 0) })
                while true { _ = try stream.Recv() }
            } catch let e as StatusException {
                try Check(e.code == Int32(c.expectStatus),
                          "\(c.name): status \(e), want \(c.expectStatus)")
            } catch is EndOfStreamError {
                try Check(false, "\(c.name): expected failure, stream ended OK")
            }
        case "deadline":
            do {
                _ = try client.Unary(EchoRequest(c.messages[0], 0, Int32(c.count)), nil, 0.1)
                try Check(false, "\(c.name): expected deadline failure")
            } catch let e as StatusException {
                try Check(e.code == Int32(c.expectStatus),
                          "\(c.name): status \(e), want \(c.expectStatus)")
            }
        case "cancel":
            let stream = try channel.ServerStream("/echo.Echo/ServerStream",
                                                  Req(c.messages[0], Int32(c.count)))
            let first = EchoResponse()
            try stream.Recv(first)
            try Check(first.message == c.messages[0], "\(c.name): first \(first)")
            stream.Cancel()
            var terminated = false
            do {
                for _ in 0..<(c.count + 2) {
                    try stream.Recv(EchoResponse())
                }
            } catch {
                terminated = true
            }
            try Check(terminated, "\(c.name): stream did not terminate after cancel")
        case "stream-break":
            // Dedicated counting server: breaking the async
            // iteration (no explicit cancel) must RST the call so
            // the server stops producing.
            let counter = BddProducedCounter()
            let (a2, b2) = MemoryTransport.Pair()
            let breakServer = Server()
            EchoGrpcDc.RegisterEchoServer(breakServer, BddCountingEchoService(counter))
            breakServer.ServeTransport(b2)
            let breakClient = EchoGrpcDc.EchoClient(Channel(a2))
            try RunBlocking {
                var seen = 0
                for try await resp in breakClient.ServerStreamAsync(Req(c.messages[0], Int32(c.count))) {
                    try Check(resp.message == c.messages[0], "\(c.name): first \(resp)")
                    seen += 1
                    break
                }
                try Check(seen == 1, "\(c.name): seen \(seen)")
            }
            Thread.sleep(forTimeInterval: 0.15)
            let settled = counter.get()
            Thread.sleep(forTimeInterval: 0.15)
            try Check(counter.get() == settled,
                      "\(c.name): kept producing: \(settled) -> \(counter.get())")
            try Check(settled < 50, "\(c.name): produced too many: \(settled)")
        case "raw-unary":
            do {
                let resp = EchoResponse()
                try channel.Unary(c.path, Req(c.messages[0], 0), resp)
                try Check(false, "\(c.name): expected failure")
            } catch let e as StatusException {
                try Check(e.code == Int32(c.expectStatus),
                          "\(c.name): status \(e), want \(c.expectStatus)")
            }
        default:
            try Check(false, "unknown bdd kind: \(c.kind)")
        }
    }
    print("TestBdd OK")
}
