// Browser test entry point (native runtime): runs the four
// Echo call shapes with the *native* generated Swift client
// (swift/examples/EchoGrpcDc.swift) over the real grpcdc
// channel/endpoint runtime on a DataChannel transport, in a
// Web Worker. The endpoint runs in inline pump mode (TryRecv
// transport), so the ordinary blocking client code below
// drives itself. Mirrors wasm/zig/native's echo client.

@_extern(c, "on_result")
func onResult(_ ptr: UnsafePointer<UInt8>, _ len: Int)

@_extern(c, "on_error")
func onError(_ ptr: UnsafePointer<UInt8>, _ len: Int)

private func report(_ text: String, error: Bool) {
    let bytes = [UInt8](text.utf8)
    let safe = bytes.isEmpty ? [0] : bytes
    safe.withUnsafeBufferPointer { b in
        if error {
            onError(b.baseAddress!, bytes.count)
        } else {
            onResult(b.baseAddress!, bytes.count)
        }
    }
}

private func jsonEscape(_ s: String) -> String {
    var out = ""
    for ch in s {
        switch ch {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default: out.append(ch)
        }
    }
    return out
}

private func codeOf(_ body: () throws -> Void) -> Int {
    do {
        try body()
        return 0
    } catch let e as StatusException {
        return e.code
    } catch {
        return -1
    }
}

private func run() throws {
    let channel = Channel(DcTransport())
    let client = EchoGrpcDc.EchoClient(channel)

    let unary = try client.Unary(EchoRequest("hello", 0))

    let stream = try client.ServerStream(EchoRequest("tick", 3))
    var ticks: [Int32] = []
    while true {
        do {
            ticks.append(try stream.Recv().index)
        } catch is EndOfStreamError {
            break
        }
    }

    let joined = try client.ClientStream([EchoRequest("a", 0), EchoRequest("b", 0)])

    let bidi = try client.Bidi([EchoRequest("x", 0), EchoRequest("y", 0)])
    var echoed: [String] = []
    while true {
        do {
            echoed.append(try bidi.Recv().message)
        } catch is EndOfStreamError {
            break
        }
    }

    // BDD deepening: failure, metadata, unknown-method, and
    // cancellation scenarios executed by this module.
    let unaryFailureCode = codeOf { _ = try client.Unary(EchoRequest("fail", 0)) }
    let metadataResp = try client.Unary(EchoRequest("hello", 0), ["x-echo": "meta"])
    let serverStreamFailureCode = codeOf {
        let s = try client.ServerStream(EchoRequest("fail", 3))
        while true { _ = try s.Recv() }
    }
    let bidiFailureCode = codeOf {
        let s = try client.Bidi([EchoRequest("fail", 0)])
        while true { _ = try s.Recv() }
    }
    let unknownMethodCode = codeOf {
        try channel.Unary("/echo.Echo/Nope", EchoRequest("hello", 0), EchoResponse())
    }
    var cancelTerminated = false
    do {
        let stream = try channel.ServerStream("/echo.Echo/ServerStream", EchoRequest("tick", 5))
        try stream.Recv(EchoResponse())
        stream.Cancel()
        do {
            for _ in 0..<7 {
                try stream.Recv(EchoResponse())
            }
        } catch {
            cancelTerminated = true
        }
    }

    let slow = EchoRequest("slow", 0)
    slow.delayMs = 400
    var deadlineCode = 0
    do {
        _ = try client.Unary(slow, nil, 0.05)
    } catch let e as StatusException {
        deadlineCode = e.code
    }

    let ticksText = ticks.map { String($0) }.joined(separator: ",")
    let echoedText = echoed.map { "\"" + jsonEscape($0) + "\"" }.joined(separator: ",")
    report("{\"unary\":\"\(jsonEscape(unary.message))\",\"ticks\":[\(ticksText)],\"joined\":\"\(jsonEscape(joined.message))\",\"echoed\":[\(echoedText)],\"deadlineCode\":\(deadlineCode),\"unaryFailureCode\":\(unaryFailureCode),\"metadataMessage\":\"\(jsonEscape(metadataResp.message))\",\"serverStreamFailureCode\":\(serverStreamFailureCode),\"bidiFailureCode\":\(bidiFailureCode),\"unknownMethodCode\":\(unknownMethodCode),\"cancelTerminated\":\(cancelTerminated)}",
           error: false)
}

@_cdecl("run_echo_client")
public func run_echo_client() {
    do {
        try run()
    } catch let e as StatusException {
        report("grpc status \(e.code): \(e.message)", error: true)
    } catch {
        report("error: \(error)", error: true)
    }
}
