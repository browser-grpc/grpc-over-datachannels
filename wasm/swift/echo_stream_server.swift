// Incremental Echo implementation for the Swift/WASM facade
// stream server browser test (echo_swift_stream_server.wasm):
// requests arrive one request at a time through the generated
// serve_*Start/Feed/End exports (registerClientStreamInc /
// registerBidiInc on the page). Bidi answers each request as it
// lands (ping-pong proof).

final class SlowEchoStreamServer: EchoWasmGrpcDc.EchoStreamServer {
    private struct CallState {
        var parts: [String] = []
        var index: Int32 = 0
        var failed = false
    }

    private var states: [UInt32: CallState] = [:]

    func ClientStreamBegin(_ callId: UInt32, _ metadata: [(String, String)]) {
        states[callId] = CallState()
    }

    func ClientStreamRequest(_ callId: UInt32, _ req: EchoRequest) {
        if req.message == "fail" {
            states[callId, default: CallState()].failed = true
            return
        }
        states[callId, default: CallState()].parts.append(req.message)
    }

    func ClientStreamEnd(_ callId: UInt32) -> Result<EchoResponse, StatusException> {
        let state = states.removeValue(forKey: callId) ?? CallState()
        if state.failed {
            return .failure(StatusException(3, "asked to fail"))
        }
        let resp = EchoResponse()
        resp.message = state.parts.joined(separator: "+")
        resp.index = Int32(state.parts.count)
        return .success(resp)
    }

    func BidiBegin(_ callId: UInt32, _ metadata: [(String, String)]) {
        states[callId] = CallState()
    }

    func BidiRequest(_ callId: UInt32, _ req: EchoRequest, _ sink: EchoWasmGrpcDc.EchoServerSink) -> StatusException? {
        if req.message == "fail" {
            return StatusException(3, "asked to fail")
        }
        var state = states[callId] ?? CallState()
        let resp = EchoResponse()
        resp.message = req.message
        resp.index = state.index
        state.index += 1
        states[callId] = state
        sink.Send(resp)
        return nil
    }

    func BidiEnd(_ callId: UInt32) -> StatusException? {
        states.removeValue(forKey: callId)
        return nil
    }
}

@_cdecl("run_echo_stream_server")
public func runEchoStreamServer() {
    EchoWasmGrpcDc.registerEchoStreamServer(SlowEchoStreamServer())
}
