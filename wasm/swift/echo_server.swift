// SlowEcho service implementation for the Swift/WASM facade
// server browser test (echo_server.wasm): registers the
// generated EchoServer implementation, whose serve_* exports
// the page glue invokes through the JS server bridge
// (createGrpcDcServerBridge). Delay busy-waits against the
// page's js_now_ms import; compliant clients enforce their
// own deadlines (e.g. a 400 ms budget against a 1500 ms
// delay), so the server only has to provide the lateness.

@_extern(c, "js_now_ms")
func facadeNowMs() -> Double

struct SlowEchoServer: EchoWasmGrpcDc.EchoServer {
    private func maybeDelay(_ req: EchoRequest) {
        if req.delayMs > 0 {
            let until = facadeNowMs() + Double(req.delayMs)
            while facadeNowMs() < until {}
        }
    }

    private func copy(_ req: EchoRequest, _ metadata: [(String, String)]) -> EchoResponse {
        let resp = EchoResponse()
        resp.message = "echo: " + req.message
        if let marker = MetadataGet(metadata, "x-echo") {
            resp.message += " [" + marker + "]"
        }
        return resp
    }

    func Unary(_ req: EchoRequest, _ metadata: [(String, String)]) -> Result<EchoResponse, StatusException> {
        if req.message == "fail" {
            return .failure(StatusException(3, "bad request"))
        }
        maybeDelay(req)
        return .success(copy(req, metadata))
    }

    func ServerStream(_ req: EchoRequest, _ metadata: [(String, String)], _ sink: EchoWasmGrpcDc.EchoServerSink) -> StatusException? {
        if req.message == "fail" {
            return StatusException(3, "bad request")
        }
        maybeDelay(req)
        for i in 0..<Int(req.count) {
            let resp = EchoResponse()
            resp.message = req.message
            resp.index = Int32(i)
            sink.Send(resp)
        }
        return nil
    }

    func ClientStream(_ reqs: [EchoRequest], _ metadata: [(String, String)]) -> Result<EchoResponse, StatusException> {
        for req in reqs where req.message == "fail" {
            return .failure(StatusException(3, "bad request"))
        }
        let resp = EchoResponse()
        resp.message = reqs.map { $0.message }.joined(separator: "+")
        return .success(resp)
    }

    func Bidi(_ reqs: [EchoRequest], _ metadata: [(String, String)], _ sink: EchoWasmGrpcDc.EchoServerSink) -> StatusException? {
        for req in reqs {
            if req.message == "fail" {
                return StatusException(3, "bad request")
            }
        }
        for req in reqs {
            let resp = EchoResponse()
            resp.message = req.message
            sink.Send(resp)
        }
        return nil
    }
}

@_cdecl("run_echo_server")
public func runEchoServer() {
    EchoWasmGrpcDc.registerEchoServer(SlowEchoServer())
}
