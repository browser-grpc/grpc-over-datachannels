// Native DataChannel transport for the Embedded Swift build:
// the real generated grpcdc runtime (swift/grpcdc) over the
// page's RTCDataChannel. Runs in a Web Worker; js_dc_recv
// waits on a SharedArrayBuffer mailbox the page fills (see
// browser-test/wasm_swift_native_worker.js). Provides TryRecv,
// so the grpcdc endpoint runs in its inline pump mode (no
// Foundation threads under wasm32-unknown-none-wasm). The
// runtime's GrpcTime clock uses the same worker's js_now_ms
// (performance.now).

@_extern(c, "js_dc_send")
func jsDcSend(_ ptr: UnsafePointer<UInt8>, _ len: Int)

@_extern(c, "js_dc_recv")
func jsDcRecv(_ ptr: UnsafeMutablePointer<UInt8>, _ cap: Int, _ timeoutMs: Int32) -> Int32

final class DcTransport: Transport {
    private var buffer = [UInt8](repeating: 0, count: 256 * 1024)

    func Send(_ data: [UInt8]) throws {
        let safe = data.isEmpty ? [0] : data
        safe.withUnsafeBufferPointer { buf in
            jsDcSend(buf.baseAddress!, data.count)
        }
    }

    func Recv() throws -> [UInt8] {
        while true {
            switch TryRecv() {
            case .message(let data):
                return data
            case .wouldBlock:
                continue
            case .closed:
                throw EndOfStreamError()
            }
        }
    }

    var HasTryRecv: Bool { true }

    func TryRecv() -> TryRecvResult {
        let n = buffer.withUnsafeMutableBufferPointer { buf in
            jsDcRecv(buf.baseAddress!, buf.count, 50)
        }
        if n == -1 { return .wouldBlock }
        if n < 0 { return .closed }
        return .message(Array(buffer[0..<Int(n)]))
    }

    func Close() {}
}
