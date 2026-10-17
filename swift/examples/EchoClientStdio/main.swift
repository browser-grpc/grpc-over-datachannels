import Foundation

// Interop harness: the Swift echo client over stdio. Prints one line
// per call shape to stderr (stdout carries frames) and exits non-zero
// on any failure. Mirrors go/examples/echo_client_stdio.
func Req(_ message: String, _ count: Int32) -> EchoRequest {
    EchoRequest(message, count)
}

func Run() throws {
    let transport = StdioTransport(writerFd: 1, readerFd: 0)
    let client = EchoGrpcDc.EchoClient(Channel(transport))

    let unary = try client.Unary(Req("hello", 0))
    FileHandle.standardError.write("unary=\(unary.message)\n".data(using: .utf8)!)

    let stream = try client.ServerStream(Req("tick", 3))
    var ticks: [String] = []
    while true {
        do {
            let resp = try stream.Recv()
            ticks.append("\(resp.message)#\(resp.index)")
        } catch is EndOfStreamError {
            break
        }
    }
    FileHandle.standardError.write("server_stream=\(ticks.joined(separator: ","))\n".data(using: .utf8)!)

    let joined = try client.ClientStream([Req("a", 0), Req("b", 0), Req("c", 0)])
    FileHandle.standardError.write("client_stream=\(joined.message)\n".data(using: .utf8)!)

    let bidi = try client.Bidi([Req("x", 0), Req("y", 0)])
    var echoed: [String] = []
    while true {
        do {
            echoed.append(try bidi.Recv().message)
        } catch is EndOfStreamError {
            break
        }
    }
    FileHandle.standardError.write("bidi=\(echoed.joined(separator: ","))\n".data(using: .utf8)!)

    let mdResp = try client.Unary(Req("hello", 0), ["x-echo": "meta"])
    FileHandle.standardError.write("metadata=\(mdResp.message)\n".data(using: .utf8)!)

    do {
        let slowReq = Req("slow", 0)
        slowReq.delayMs = 400
        _ = try client.Unary(slowReq, nil, 0.05)
        FileHandle.standardError.write("deadline=no error\n".data(using: .utf8)!)
    } catch let e as StatusException {
        FileHandle.standardError.write("deadline=\(e.code)\n".data(using: .utf8)!)
    }

    do {
        _ = try client.Unary(Req("fail", 0))
        FileHandle.standardError.write("error_case=no error\n".data(using: .utf8)!)
        exit(1)
    } catch let e as StatusException {
        FileHandle.standardError.write("error_case=\(e)\n".data(using: .utf8)!)
    }
}

do {
    try Run()
} catch {
    FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
    exit(1)
}
