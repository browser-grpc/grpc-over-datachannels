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
    // BDD deepening fields, filled by the deep chain below.
    var unaryFailureCode = -99
    var metadataMessage = ""
    var serverStreamFailureCode = -99
    var bidiFailureCode = -99
    var unknownMethodCode = -99
    var cancelSeen = 0
    var deadlineCode = -99

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
                self.startDeep()
            }
        })
    }

    // BDD deepening chain: failure, metadata, unknown-method,
    // cancel, and deadline scenarios run inside this module.
    func startDeep() {
        client.Unary(req("fail", 0)) { result in
            switch result {
            case .failure(let status): self.unaryFailureCode = Int(status.code)
            case .success: self.unaryFailureCode = 0
            }
            GrpcDcWasmBridge.shared.unaryWithOptions(
                "/echo.Echo/Unary", self.req("hello", 0).MarshalDc(),
                "{\"metadata\":{\"x-echo\":\"meta\"}}") { mresult in
                if case .success(let bytes) = mresult {
                    let resp = EchoResponse()
                    resp.UnmarshalDc(bytes)
                    self.metadataMessage = resp.message
                }
                self.client.ServerStream(self.req("fail", 3), { _ in }, { status in
                    self.serverStreamFailureCode = status.map { Int($0.code) } ?? 0
                    self.client.Bidi([self.req("fail", 0)], { _ in }, { bstatus in
                        self.bidiFailureCode = bstatus.map { Int($0.code) } ?? 0
                        GrpcDcWasmBridge.shared.unary(
                            "/echo.Echo/Nope", self.req("hello", 0).MarshalDc()) { uresult in
                            switch uresult {
                            case .failure(let status): self.unknownMethodCode = Int(status.code)
                            case .success: self.unknownMethodCode = 0
                            }
                            GrpcDcWasmBridge.shared.serverStreamCancelAfter(
                                "/echo.Echo/ServerStream", self.req("tick", 5).MarshalDc(), 1,
                                { _ in self.cancelSeen += 1 }, { _ in
                                    var slow = self.req("slow", 0)
                                    slow.delayMs = 600
                                    GrpcDcWasmBridge.shared.unaryWithOptions(
                                        "/echo.Echo/Unary", slow.MarshalDc(),
                                        "{\"timeout\":100}") { dresult in
                                        switch dresult {
                                        case .failure(let status): self.deadlineCode = Int(status.code)
                                        case .success: self.deadlineCode = 0
                                        }
                                        self.finish()
                                    }
                                })
                        }
                    })
                })
            }
        }
    }

    func finish() {
        let ticksText = ticks.map { String($0) }.joined(separator: ",")
        let echoedText = echoed.map { "\"" + jsonEscape($0) + "\"" }.joined(separator: ",")
        report("{\"unary\":\"\(jsonEscape(unary))\",\"ticks\":[\(ticksText)],\"joined\":\"\(jsonEscape(joined))\",\"echoed\":[\(echoedText)],\"unaryFailureCode\":\(unaryFailureCode),\"metadataMessage\":\"\(jsonEscape(metadataMessage))\",\"serverStreamFailureCode\":\(serverStreamFailureCode),\"bidiFailureCode\":\(bidiFailureCode),\"unknownMethodCode\":\(unknownMethodCode),\"cancelTerminated\":\(cancelSeen == 1),\"deadlineCode\":\(deadlineCode)}",
               error: false)
    }
}

@_cdecl("run_echo_client")
public func run_echo_client() {
    EchoRun.shared.start()
}
