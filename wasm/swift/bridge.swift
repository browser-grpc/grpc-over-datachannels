// Bridge runtime for generated Swift WASM client facades
// (EchoWasmDc.swift): hands protobuf payloads to the page's
// JS grpc-dc bridge (js/src/wasm_bridge.js) via env imports,
// and receives responses through the exported on_bridge_*
// hooks. The JS implementation owns the wire; this file owns
// only the interop. Compiled as Embedded Swift
// (wasm32-unknown-none-wasm): no Foundation, callback-shaped
// because the browser thread cannot block.
//
// Pb.swift / EchoMessages.swift from swift/examples compile
// against the small leaf definitions below (StatusException,
// Marshaler, Unmarshaler) plus swift/grpcdc/Wire.swift; the
// threaded native endpoint/channel runtime stays native-only.

/// A gRPC status (code + message) carried as an error. Mirrors
/// swift/grpcdc/Status.swift without the Foundation import.
struct StatusException: Error, CustomStringConvertible {
    let code: Int
    let message: String

    init(_ code: Int, _ message: String) {
        self.code = code
        self.message = message
    }

    var description: String { "\(Wire.StatusName(code)): \(message)" }
}

/// Implemented by hand-written protobuf message types.
protocol Marshaler {
    func MarshalDc() -> [UInt8]
}

/// Implemented by hand-written protobuf message types.
protocol Unmarshaler {
    func UnmarshalDc(_ data: [UInt8])
}

@_extern(c, "js_unary")
func jsUnary(_ callId: UInt32, _ path: UnsafePointer<UInt8>, _ pathLen: Int,
             _ payload: UnsafePointer<UInt8>, _ payloadLen: Int)

@_extern(c, "js_server_stream")
func jsServerStream(_ callId: UInt32, _ path: UnsafePointer<UInt8>, _ pathLen: Int,
                    _ payload: UnsafePointer<UInt8>, _ payloadLen: Int)

@_extern(c, "js_client_stream")
func jsClientStream(_ callId: UInt32, _ path: UnsafePointer<UInt8>, _ pathLen: Int,
                    _ packed: UnsafePointer<UInt8>, _ packedLen: Int)

@_extern(c, "js_bidi")
func jsBidi(_ callId: UInt32, _ path: UnsafePointer<UInt8>, _ pathLen: Int,
            _ packed: UnsafePointer<UInt8>, _ packedLen: Int)

final class GrpcDcWasmBridge {
    static let shared = GrpcDcWasmBridge()

    typealias UnaryCallback = (Result<[UInt8], StatusException>) -> Void
    typealias MessageCallback = ([UInt8]) -> Void
    typealias DoneCallback = (StatusException?) -> Void

    private struct Entry {
        var onMessage: MessageCallback?
        var onUnary: UnaryCallback?
        var onDone: DoneCallback?
    }

    private var nextId: UInt32 = 1
    private var pending: [UInt32: Entry] = [:]

    private func register(_ entry: Entry) -> UInt32 {
        let id = nextId
        nextId += 1
        pending[id] = entry
        return id
    }

    private func withPointers(_ path: String, _ payload: [UInt8],
                              _ body: (UnsafePointer<UInt8>, Int, UnsafePointer<UInt8>, Int) -> Void) {
        let pathBytes = [UInt8](path.utf8)
        let safePath = pathBytes.isEmpty ? [0] : pathBytes
        let safePayload = payload.isEmpty ? [0] : payload
        safePath.withUnsafeBufferPointer { p in
            safePayload.withUnsafeBufferPointer { b in
                body(p.baseAddress!, pathBytes.count, b.baseAddress!, payload.count)
            }
        }
    }

    private func pack(_ payloads: [[UInt8]]) -> [UInt8] {
        var out: [UInt8] = []
        for payload in payloads {
            let n = UInt32(payload.count)
            out.append(UInt8((n >> 24) & 0xff))
            out.append(UInt8((n >> 16) & 0xff))
            out.append(UInt8((n >> 8) & 0xff))
            out.append(UInt8(n & 0xff))
            out.append(contentsOf: payload)
        }
        return out
    }

    func unary(_ path: String, _ payload: [UInt8], _ callback: @escaping UnaryCallback) {
        let id = register(Entry(onUnary: callback))
        withPointers(path, payload) { p, plen, b, blen in jsUnary(id, p, plen, b, blen) }
    }

    func serverStream(_ path: String, _ payload: [UInt8],
                      _ onMessage: @escaping MessageCallback,
                      _ onDone: @escaping DoneCallback) {
        let id = register(Entry(onMessage: onMessage, onDone: onDone))
        withPointers(path, payload) { p, plen, b, blen in jsServerStream(id, p, plen, b, blen) }
    }

    func clientStream(_ path: String, _ payloads: [[UInt8]], _ callback: @escaping UnaryCallback) {
        let id = register(Entry(onUnary: callback))
        withPointers(path, pack(payloads)) { p, plen, b, blen in jsClientStream(id, p, plen, b, blen) }
    }

    func bidi(_ path: String, _ payloads: [[UInt8]],
              _ onMessage: @escaping MessageCallback,
              _ onDone: @escaping DoneCallback) {
        let id = register(Entry(onMessage: onMessage, onDone: onDone))
        withPointers(path, pack(payloads)) { p, plen, b, blen in jsBidi(id, p, plen, b, blen) }
    }

    fileprivate func handleMessage(_ callId: UInt32, _ payload: [UInt8]) {
        pending[callId]?.onMessage?(payload)
    }

    fileprivate func handleDone(_ callId: UInt32, _ payload: [UInt8]?) {
        guard let entry = pending.removeValue(forKey: callId) else { return }
        if let onUnary = entry.onUnary {
            onUnary(.success(payload ?? []))
        } else {
            entry.onDone?(nil)
        }
    }

    fileprivate func handleError(_ callId: UInt32, _ status: StatusException) {
        guard let entry = pending.removeValue(forKey: callId) else { return }
        if let onUnary = entry.onUnary {
            onUnary(.failure(status))
        } else {
            entry.onDone?(status)
        }
    }
}

// ---- exports used by the page glue ----

@_cdecl("wasm_alloc")
public func wasm_alloc(_ len: Int) -> UnsafeMutablePointer<UInt8>? {
    UnsafeMutablePointer<UInt8>.allocate(capacity: max(len, 1))
}

@_cdecl("wasm_free")
public func wasm_free(_ ptr: UnsafeMutablePointer<UInt8>?, _ len: Int) {
    _ = len
    ptr?.deallocate()
}

private func copyAndFree(_ ptr: UnsafeMutablePointer<UInt8>?, _ len: Int) -> [UInt8] {
    guard let ptr, len > 0 else {
        wasm_free(ptr, len)
        return []
    }
    let bytes = [UInt8](UnsafeBufferPointer(start: UnsafePointer(ptr), count: len))
    wasm_free(ptr, len)
    return bytes
}

@_cdecl("on_bridge_message")
public func on_bridge_message(_ callId: UInt32, _ ptr: UnsafeMutablePointer<UInt8>?, _ len: Int) {
    GrpcDcWasmBridge.shared.handleMessage(callId, copyAndFree(ptr, len))
}

@_cdecl("on_bridge_done")
public func on_bridge_done(_ callId: UInt32, _ hasPayload: UInt32,
                           _ ptr: UnsafeMutablePointer<UInt8>?, _ len: Int) {
    let bytes = copyAndFree(ptr, len)
    GrpcDcWasmBridge.shared.handleDone(callId, hasPayload != 0 ? bytes : nil)
}

@_cdecl("on_bridge_error")
public func on_bridge_error(_ callId: UInt32, _ code: Int32,
                            _ ptr: UnsafeMutablePointer<UInt8>?, _ len: Int) {
    let message = String(decoding: copyAndFree(ptr, len), as: UTF8.self)
    GrpcDcWasmBridge.shared.handleError(callId, StatusException(Int(code), message))
}
