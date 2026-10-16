// Browser test entry point: runs the four Echo call shapes
// through the generated Swift WASM facade (EchoWasmGrpcDc)
// over the JS grpc-dc bridge, then reports a JSON summary via
// the on_result import. Callback-chained throughout —
// Embedded Swift on the browser thread cannot block.

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

private final class EchoRun {
    static let shared = EchoRun()
    let client = EchoWasmGrpcDc.EchoClient()
    var unary = ""
    var ticks: [Int32] = []
    var joined = ""
    var echoed: [String] = []

    func fail(_ status: StatusException) {
        report("grpc status \(status.code): \(status.message)", error: true)
    }

    func req(_ message: String, _ count: Int32) -> EchoRequest {
        EchoRequest(message, count)
    }

    func start() {
        client.Unary(req("hello", 0)) { result in
            switch result {
            case .failure(let status):
                self.fail(status)
            case .success(let resp):
                self.unary = resp.message
                self.startServerStream()
            }
        }
    }

    func startServerStream() {
        client.ServerStream(req("tick", 3), { resp in
            self.ticks.append(resp.index)
        }, { status in
            if let status {
                self.fail(status)
            } else {
                self.startClientStream()
            }
        })
    }

    func startClientStream() {
        client.ClientStream([req("a", 0), req("b", 0)]) { result in
            switch result {
            case .failure(let status):
                self.fail(status)
            case .success(let resp):
                self.joined = resp.message
                self.startBidi()
            }
        }
    }

    func startBidi() {
        client.Bidi([req("x", 0), req("y", 0)], { resp in
            self.echoed.append(resp.message)
        }, { status in
            if let status {
                self.fail(status)
            } else {
                self.finish()
            }
        })
    }

    func finish() {
        let ticksText = ticks.map { String($0) }.joined(separator: ",")
        let echoedText = echoed.map { "\"" + jsonEscape($0) + "\"" }.joined(separator: ",")
        report("{\"unary\":\"\(jsonEscape(unary))\",\"ticks\":[\(ticksText)],\"joined\":\"\(jsonEscape(joined))\",\"echoed\":[\(echoedText)]}",
               error: false)
    }
}

@_cdecl("run_echo_client")
public func run_echo_client() {
    EchoRun.shared.start()
}
