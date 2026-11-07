#lang racket

;;; runtime-swift.rkt — the Swift gRPC runtime, emitted by metagen.rkt.
;;;
;;; The runtime files under swift/grpcdc/ are GENERATED from the
;;; bodies below plus fragments recursively expanded from spec.rkt's
;;; frame/status tables (see the dispatch generator). Do not edit the
;;; generated runtime files; edit here and run `make generate`.
;;; (Bodies were authored in-language and are kept verbatim so the
;;; generated output stays byte-reviewable in git diffs.)
;;;
;;; Swift 5 language mode, Foundation only — no external packages.

(require "spec.rkt" "desc.rkt")
(provide emit-swift-runtime-files)

(define swift-status-body
#<<GRPC_RUNTIME_EOF
/// Thrown at end of a receiving stream (call completed OK).
struct EndOfStreamError: Error {}

/// A gRPC status (code + message) carried as an error.
struct StatusException: Error, CustomStringConvertible {
    let code: Int
    let message: String
    /// Trailing metadata carried by a status frame (never null).
    var trailers: [String: String] = [:]

    init(_ code: Int, _ message: String) {
        self.code = code
        self.message = message
    }

    var description: String { "\(Wire.StatusName(code)): \(message)" }

    /// Convert any error to a StatusException (OK for nil).
    static func ToStatus(_ error: Error?) -> StatusException {
        guard let error = error else { return StatusException(Wire.CodeOk, "") }
        if let se = error as? StatusException { return se }
        #if canImport(Foundation)
        return StatusException(Wire.CodeInternal, String(describing: error))
        #else
        return StatusException(Wire.CodeInternal, "internal error")
        #endif
    }
}

/// Homegrown tracing: W3C traceparent propagation with a span
/// observer. Dormant until Tracing.SetTracer registers one;
/// generated code stays dependency-free (sampling and export are
/// the application's problem).
enum Tracing {
    protocol Tracer {
        func OnStart(_ kind: String, _ method: String, _ traceId: String, _ spanId: String, _ parentSpanId: String)
        func OnEnd(_ kind: String, _ method: String, _ traceId: String, _ spanId: String, _ status: String, _ durationMs: Double)
    }

    struct TraceContext {
        let traceId: String
        let spanId: String
        let parentSpanId: String
        let sampled: Bool
        let start: ContinuousClock.Instant
    }

    struct Parent {
        let traceId: String
        let spanId: String
        let sampled: Bool
    }

    private static var tracer: Tracer? = nil

    static func SetTracer(_ t: Tracer?) { tracer = t }

    private static var traceFilter: [String] = []

    // Restrict traced methods: ';'-separated paths, a trailing
    // '*' means prefix match ('/echo.Echo/*'). Empty = trace all.
    static func SetTraceFilter(_ patterns: String) {
        traceFilter = patterns.split(separator: ";").map(String.init).filter { !$0.isEmpty }
    }

    static func TraceAllowed(_ method: String) -> Bool {
        if traceFilter.isEmpty { return true }
        return traceFilter.contains { p in
            p.hasSuffix("*") ? method.hasPrefix(String(p.dropLast())) : method == p
        }
    }

    static var Enabled: Bool { tracer != nil }

    static func FormatTraceparent(_ traceId: String, _ spanId: String, _ sampled: Bool) -> String {
        "00-\(traceId)-\(spanId)-\(sampled ? "01" : "00")"
    }

    static func ParseTraceparent(_ value: String?) -> Parent? {
        guard let value else { return nil }
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[1].count == 32, parts[2].count == 16 else { return nil }
        let isHex: (Unicode.Scalar) -> Bool = { ($0.value >= 48 && $0.value <= 57) || ($0.value >= 97 && $0.value <= 102) }
        guard parts[1].unicodeScalars.allSatisfy(isHex),
              parts[2].unicodeScalars.allSatisfy(isHex) else { return nil }
        guard parts[3].count == 2, parts[3].unicodeScalars.allSatisfy(isHex),
              let flags = Int(parts[3], radix: 16) else { return nil }
        return Parent(traceId: String(parts[1]), spanId: String(parts[2]), sampled: (flags & 1) == 1)
    }

    private static func RandomHex(_ bytes: Int) -> String {
        let digits = Array("0123456789abcdef")
        var out = ""
        out.reserveCapacity(bytes * 2)
        for _ in 0..<bytes {
            let b = UInt8.random(in: 0...255)
            out.append(digits[Int(b >> 4)])
            out.append(digits[Int(b & 0xf)])
        }
        return out
    }

    static func TraceStart(_ kind: String, _ method: String, _ parent: Parent?) -> TraceContext? {
        guard let t = tracer, TraceAllowed(method) else { return nil }
        let ctx = TraceContext(
            traceId: parent?.traceId ?? RandomHex(16),
            spanId: RandomHex(8),
            parentSpanId: parent?.spanId ?? "",
            sampled: parent?.sampled ?? true,
            start: ContinuousClock.now)
        if !ctx.sampled { return ctx }
        t.OnStart(kind, method, ctx.traceId, ctx.spanId, ctx.parentSpanId)
        return ctx
    }

    static func TraceEnd(_ kind: String, _ method: String, _ ctx: TraceContext?, _ status: String) {
        guard let ctx, let t = tracer, ctx.sampled else { return }
        let d = ctx.start.duration(to: ContinuousClock.now)
        let durationMs = Double(d.components.seconds) * 1000.0
            + Double(d.components.attoseconds) / 1.0e15
        t.OnEnd(kind, method, ctx.traceId, ctx.spanId, status, durationMs)
    }
}
GRPC_RUNTIME_EOF
)

(define swift-codec-body
#<<GRPC_RUNTIME_EOF
/// Frame codec for gRPC over WebRTC DataChannels (wire protocol in
/// ../SPEC.md). Frame, status, channel and server semantics mirror the
/// Rust, JavaScript, Go, Python, Java, C# and C++ runtimes; the tables
/// in Wire.swift are generated by grpc-dc codegen.
enum Codec {
    static let HeaderLen = 9
    static let MaxDataPayload = 16 * 1024 * 1024

    /// One parsed frame.
    struct Frame {
        let type: Int
        let streamId: UInt32
        let payload: [UInt8]
    }

    static func PutU32(_ out: inout [UInt8], _ offset: Int, _ value: UInt32) {
        out[offset] = UInt8((value >> 24) & 0xff)
        out[offset + 1] = UInt8((value >> 16) & 0xff)
        out[offset + 2] = UInt8((value >> 8) & 0xff)
        out[offset + 3] = UInt8(value & 0xff)
    }

    static func GetU32(_ input: [UInt8], _ offset: Int) -> UInt32 {
        return (UInt32(input[offset]) << 24) | (UInt32(input[offset + 1]) << 16)
            | (UInt32(input[offset + 2]) << 8) | UInt32(input[offset + 3])
    }

    /// Build one DataChannel message: header + payload.
    static func EncodeFrame(_ frameType: Int, _ streamId: UInt32, _ payload: [UInt8]) throws -> [UInt8] {
        if !Wire.IsFrameType(frameType) {
            throw StatusException(Wire.CodeInvalidArgument, "unknown frame type \(frameType)")
        }
        if frameType == Wire.FrameData && payload.count > MaxDataPayload {
            throw StatusException(Wire.CodeResourceExhausted, "DATA payload exceeds 16 MiB")
        }
        var out = [UInt8](repeating: 0, count: HeaderLen + payload.count)
        out[0] = UInt8(frameType)
        PutU32(&out, 1, streamId)
        PutU32(&out, 5, UInt32(payload.count))
        out.replaceSubrange(HeaderLen..<out.count, with: payload)
        return out
    }

    /// Parse one DataChannel message.
    static func DecodeFrame(_ data: [UInt8]) throws -> Frame {
        if data.count < HeaderLen {
            throw StatusException(Wire.CodeInvalidArgument,
                                  "frame shorter than 9-byte header: \(data.count) bytes")
        }
        let length = GetU32(data, 5)
        if Int(length) != data.count - HeaderLen {
            throw StatusException(Wire.CodeInvalidArgument,
                                  "payload length \(length) does not match message size \(data.count)")
        }
        return Frame(type: Int(data[0]), streamId: GetU32(data, 1),
                     payload: Array(data[HeaderLen...]))
    }

    /// Parsed HEADERS payload: path == nil means response headers.
    struct Headers {
        var path: String?
        var metadata: [String: String] = [:]
    }

    static func HeadersFrame(_ streamId: UInt32, _ path: String?, _ metadata: [String: String]?) throws -> [UInt8] {
        var fields: [(String, JsonValue)] = []
        if let path = path { fields.append(("path", .string(path))) }
        if let metadata = metadata, !metadata.isEmpty {
            let entries = metadata.keys.sorted().map {
                ($0, JsonValue.string(metadata[$0] ?? ""))
            }
            fields.append(("metadata", .object(entries)))
        }
        return try EncodeFrame(Wire.FrameHeaders, streamId,
                               [UInt8](JsonWrite(.object(fields)).utf8))
    }

    static func ParseHeaders(_ payload: [UInt8]) throws -> Headers {
        var parser = JsonParser(payload)
        guard let root = parser.Parse(), case .object(let fields) = root else {
            throw StatusException(Wire.CodeInvalidArgument, "bad HEADERS payload: not an object")
        }
        var headers = Headers()
        if case .string(let path)? = JsonField(fields, "path") {
            headers.path = path
        }
        if case .object(let md)? = JsonField(fields, "metadata") {
            for (k, v) in md {
                headers.metadata[k] = JsonStringify(v)
            }
        }
        return headers
    }

    /// gRPC timeout grammar (grpc-timeout metadata): <digits><unit>,
    /// units H/M/S/m/u/n (at most 8 digits). Encoding uses
    /// milliseconds (seconds past the digit limit), rounded up.
    static func EncodeTimeout(_ timeout: Double) -> String {
        let ms = Int64((timeout * 1000.0).rounded(.up))
        if ms <= 99999999 {
            return "\(ms)m"
        }
        return "\(Int64(timeout.rounded(.up)))S"
    }

    /// Decoded grpc-timeout, or nil when malformed/absent.
    static func ParseTimeout(_ text: String?) -> Double? {
        guard let text, text.count >= 2, text.count <= 9 else { return nil }
        let digits = text.dropLast()
        guard digits.allSatisfy({ $0.isNumber }), let n = Double(digits) else { return nil }
        switch text.last {
        case "H": return n * 3600.0
        case "M": return n * 60.0
        case "S": return n
        case "m": return n / 1000.0
        case "u": return n / 1000000.0
        case "n": return n / 1000000000.0
        default: return nil
        }
    }

    static func StatusFrame(_ frameType: Int, _ streamId: UInt32, _ status: StatusException) throws -> [UInt8] {
        var fields: [(String, JsonValue)] = [
            ("code", .number(Double(status.code))),
            ("message", .string(status.message)),
        ]
        if !status.trailers.isEmpty {
            fields.append(("metadata", .object(status.trailers.map { ($0.key, JsonValue.string($0.value)) })))
        }
        let body = JsonWrite(.object(fields))
        return try EncodeFrame(frameType, streamId, [UInt8](body.utf8))
    }

    static func ParseStatus(_ payload: [UInt8]) -> StatusException {
        var parser = JsonParser(payload)
        guard let root = parser.Parse(), case .object(let fields) = root,
              case .number(let code)? = JsonField(fields, "code") else {
            return StatusException(Wire.CodeUnknown, "malformed trailers")
        }
        var message = ""
        if case .string(let text)? = JsonField(fields, "message") {
            message = text
        }
        var status = StatusException(Int(code), message)
        if case .object(let md)? = JsonField(fields, "metadata") {
            for (key, value) in md {
                if case .string(let text) = value {
                    status.trailers[key] = text
                }
            }
        }
        return status
    }

    // ---- minimal JSON for HEADERS/TRAILERS payloads ----
    //
    // Hand-rolled (no Foundation JSONSerialization) so the same
    // codec runs in Embedded Swift on wasm32. Only the shapes
    // the wire uses are produced; the parser accepts general
    // JSON values so peers' serializers stay compatible.

    indirect enum JsonValue {
        case object([(String, JsonValue)])
        case array([JsonValue])
        case string(String)
        case number(Double)
        case bool(Bool)
        case null
    }

    static func JsonField(_ fields: [(String, JsonValue)], _ key: String) -> JsonValue? {
        for (k, v) in fields where k == key { return v }
        return nil
    }

    static func JsonEscape(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += "\\u"
                    let hex = String(scalar.value, radix: 16)
                    out += String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    static func JsonWrite(_ value: JsonValue) -> String {
        switch value {
        case .object(let fields):
            return "{" + fields.map { JsonEscape($0.0) + ":" + JsonWrite($0.1) }
                .joined(separator: ",") + "}"
        case .array(let items):
            return "[" + items.map { JsonWrite($0) }.joined(separator: ",") + "]"
        case .string(let s):
            return JsonEscape(s)
        case .number(let n):
            if n == n.rounded() && abs(n) < 9007199254740992.0 {
                return String(Int64(n))
            }
            return String(n)
        case .bool(let b):
            return b ? "true" : "false"
        case .null:
            return "null"
        }
    }

    static func JsonStringify(_ value: JsonValue) -> String {
        if case .string(let s) = value { return s }
        return JsonWrite(value)
    }

    struct JsonParser {
        private let chars: [Character]
        private var pos = 0

        init(_ payload: [UInt8]) {
            chars = Array(String(decoding: payload, as: UTF8.self))
        }

        mutating func Parse() -> JsonValue? {
            SkipWs()
            guard let value = ParseValue() else { return nil }
            SkipWs()
            return pos == chars.count ? value : nil
        }

        private func Peek() -> Character? {
            pos < chars.count ? chars[pos] : nil
        }

        private mutating func SkipWs() {
            while let c = Peek(), c == " " || c == "\t" || c == "\n" || c == "\r" {
                pos += 1
            }
        }

        private mutating func Consume(_ c: Character) -> Bool {
            if Peek() == c {
                pos += 1
                return true
            }
            return false
        }

        private mutating func ParseValue() -> JsonValue? {
            SkipWs()
            guard let c = Peek() else { return nil }
            switch c {
            case "{":
                return ParseObject()
            case "[":
                pos += 1
                var items: [JsonValue] = []
                SkipWs()
                if Consume("]") { return .array(items) }
                while true {
                    guard let item = ParseValue() else { return nil }
                    items.append(item)
                    SkipWs()
                    if Consume("]") { return .array(items) }
                    if !Consume(",") { return nil }
                }
            case "\"":
                return ParseString().map { JsonValue.string($0) }
            case "t":
                return ConsumeLiteral("true") ? .bool(true) : nil
            case "f":
                return ConsumeLiteral("false") ? .bool(false) : nil
            case "n":
                return ConsumeLiteral("null") ? .null : nil
            default:
                return ParseNumber().map { JsonValue.number($0) }
            }
        }

        private mutating func ParseObject() -> JsonValue? {
            pos += 1  // {
            var fields: [(String, JsonValue)] = []
            SkipWs()
            if Consume("}") { return .object(fields) }
            while true {
                SkipWs()
                guard let key = ParseString() else { return nil }
                SkipWs()
                if !Consume(":") { return nil }
                guard let value = ParseValue() else { return nil }
                fields.append((key, value))
                SkipWs()
                if Consume("}") { return .object(fields) }
                if !Consume(",") { return nil }
            }
        }

        private mutating func ParseString() -> String? {
            if !Consume("\"") { return nil }
            var out = String()
            while let c = Peek() {
                pos += 1
                if c == "\"" { return out }
                if c != "\\" {
                    out.append(c)
                    continue
                }
                guard let esc = Peek() else { return nil }
                pos += 1
                switch esc {
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                case "/": out.append("/")
                case "b": out.append("\u{08}")
                case "f": out.append("\u{0C}")
                case "n": out.append("\n")
                case "r": out.append("\r")
                case "t": out.append("\t")
                case "u":
                    guard let scalar = ParseUnicodeEscape() else { return nil }
                    out.unicodeScalars.append(scalar)
                default:
                    return nil
                }
            }
            return nil
        }

        private mutating func ParseUnicodeEscape() -> UnicodeScalar? {
            guard let first = ParseHex4() else { return nil }
            if first >= 0xD800 && first <= 0xDBFF {
                // High surrogate: expect a low-surrogate escape.
                if Consume("\\") && Consume("u"), let second = ParseHex4(),
                   second >= 0xDC00 && second <= 0xDFFF {
                    return UnicodeScalar(0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00))
                }
                return UnicodeScalar(0xFFFD)
            }
            return UnicodeScalar(first)
        }

        private mutating func ParseHex4() -> UInt32? {
            var value: UInt32 = 0
            for _ in 0..<4 {
                guard let c = Peek(), let digit = c.hexDigitValue else { return nil }
                pos += 1
                value = value * 16 + UInt32(digit)
            }
            return value
        }

        private mutating func ConsumeLiteral(_ literal: String) -> Bool {
            for c in literal {
                if !Consume(c) { return false }
            }
            return true
        }

        private mutating func ParseNumber() -> Double? {
            let start = pos
            while let c = Peek(),
                  c == "-" || c == "+" || c == "." || c == "e" || c == "E" || c.isNumber {
                pos += 1
            }
            if pos == start { return nil }
            return Double(String(chars[start..<pos]))
        }
    }
}
GRPC_RUNTIME_EOF
)

(define swift-transport-body
#<<GRPC_RUNTIME_EOF
#if canImport(Foundation)
import Foundation
#endif

/// Lock shim: NSLock where Foundation exists (native), a no-op
/// on Embedded Swift (wasm32, single-threaded by construction).
#if canImport(Foundation)
typealias GrpcLock = NSLock
#else
final class GrpcLock {
    func lock() {}
    func unlock() {}
}

@_extern(c, "js_now_ms")
func grpcdcJsNowMs() -> Double
#endif

/// Monotonic clock seam (milliseconds). Native builds use the
/// wall clock via Foundation (as before); Embedded Swift uses
/// the host's js_now_ms import (performance.now in the worker).
enum GrpcTime {
    static func NowMs() -> Double {
        #if canImport(Foundation)
        return Date().timeIntervalSince1970 * 1000.0
        #else
        return grpcdcJsNowMs()
        #endif
    }
}

/// Carries whole DataChannel messages: one Send/Recv is one message,
/// boundaries preserved, ordered and reliable — the contract an
/// RTCDataChannel (or the loopback pair) offers.
protocol Transport: AnyObject {
    func Send(_ data: [UInt8]) throws
    /// Next message; throws EndOfStreamError when closed.
    func Recv() throws -> [UInt8]
    func Close()

    /// Optional bounded receive for single-threaded environments
    /// (wasm32). When a transport reports HasTryRecv, the
    /// endpoint runs in inline pump mode — no read or dispatch
    /// threads; stream waits pump the transport instead of
    /// blocking on a condition variable.
    var HasTryRecv: Bool { get }
    func TryRecv() -> TryRecvResult
}

/// Result of a Transport.TryRecv call.
enum TryRecvResult {
    case message([UInt8])
    case wouldBlock
    case closed
}

extension Transport {
    func Close() {}
    var HasTryRecv: Bool { false }
    func TryRecv() -> TryRecvResult { .wouldBlock }
}

/// Implemented by hand-written protobuf message types.
protocol Marshaler {
    func MarshalDc() -> [UInt8]
}

/// Implemented by hand-written protobuf message types.
protocol Unmarshaler {
    func UnmarshalDc(_ data: [UInt8])
}

#if canImport(Foundation)
/// Thread-safe blocking queue (Foundation only).
final class BlockingQueue<T> {
    private let cond = NSCondition()
    private var items: [T] = []
    private var closed = false

    func Add(_ item: T) {
        cond.lock()
        items.append(item)
        cond.signal()
        cond.unlock()
    }

    /// Non-blocking take: next item, or nil when empty.
    func TryTake() -> T? {
        cond.lock()
        defer { cond.unlock() }
        return items.isEmpty ? nil : items.removeFirst()
    }

    func IsClosed() -> Bool {
        cond.lock()
        defer { cond.unlock() }
        return closed
    }

    /// Next item, or nil once closed and drained.
    func Take() -> T? {
        cond.lock()
        while items.isEmpty && !closed {
            cond.wait()
        }
        let item = items.isEmpty ? nil : items.removeFirst()
        cond.unlock()
        return item
    }

    /// Timed take: timedOut is true when the deadline passed empty.
    func Take(until deadline: Date) -> (item: T?, timedOut: Bool) {
        cond.lock()
        while items.isEmpty && !closed {
            if !cond.wait(until: deadline) {
                break
            }
        }
        if items.isEmpty && !closed {
            cond.unlock()
            return (nil, true)
        }
        let item = items.isEmpty ? nil : items.removeFirst()
        cond.unlock()
        return (item, false)
    }

    func Close() {
        cond.lock()
        closed = true
        cond.broadcast()
        cond.unlock()
    }
}
#else
/// Single-threaded queue for Embedded Swift (no NSCondition):
/// Take is non-blocking; waiters use TryTake plus the endpoint
/// pump (inline mode), never a blocking wait.
final class BlockingQueue<T> {
    private var items: [T] = []
    private var closedFlag = false

    func Add(_ item: T) {
        items.append(item)
    }

    func TryTake() -> T? {
        items.isEmpty ? nil : items.removeFirst()
    }

    func IsClosed() -> Bool { closedFlag }

    /// Next item, or nil once closed and drained (non-blocking
    /// in this build; see the type doc).
    func Take() -> T? {
        if let item = TryTake() { return item }
        return nil
    }

    /// Non-blocking timed take: expiry is immediate emptiness.
    func Take(until deadlineMs: Double) -> (item: T?, timedOut: Bool) {
        if let item = TryTake() { return (item, false) }
        return (nil, !closedFlag)
    }

    func Close() {
        closedFlag = true
    }
}
#endif
GRPC_RUNTIME_EOF
)

(define swift-endpoint-body
#<<GRPC_RUNTIME_EOF
#if canImport(Foundation)
import Foundation
#endif

/// Multiplexes grpc-dc streams over one Transport.
final class Endpoint {
    enum EventKind {
        case headers, data, halfClose, trailers, rst
    }

    struct StreamEvent {
        var kind: EventKind
        var headers: Codec.Headers? = nil
        var payload: [UInt8] = []
        var status: StatusException? = nil
    }

    /// Receiving queue of one stream; closed after a terminal event.
    final class StreamInput {
        private let queue = BlockingQueue<StreamEvent>()

        /// Inline mode: Get drives the endpoint pump instead of
        /// waiting on a condition variable. Strong, cleared by
        /// Endpoint.CloseStream (`weak` is unavailable in
        /// Embedded Swift); ClientStream also retains both.
        var pump: Endpoint?

        func SetPump(_ endpoint: Endpoint?) { pump = endpoint }

        func Put(_ event: StreamEvent) { queue.Add(event) }
        func Close() { queue.Close() }

        /// Next event, or nil once the stream is closed and drained.
        func Get() -> StreamEvent? {
            if let pump = pump {
                while true {
                    if let event = queue.TryTake() { return event }
                    if queue.IsClosed() { return nil }
                    pump.PollOnce()
                }
            }
            return queue.Take()
        }

        /// Timed Get: timedOut is true on expiry with no event.
        func Get(deadlineMs: Double) -> (event: StreamEvent?, timedOut: Bool) {
            if let pump = pump {
                while true {
                    if let event = queue.TryTake() { return (event, false) }
                    if queue.IsClosed() { return (nil, false) }
                    if GrpcTime.NowMs() >= deadlineMs { return (nil, true) }
                    pump.PollOnce()
                }
            }
            #if canImport(Foundation)
            let result = queue.Take(until: Date(timeIntervalSince1970: deadlineMs / 1000.0))
            return (result.item, result.timedOut)
            #else
            return (queue.TryTake(), false)
            #endif
        }
    }

    /// Per-call context: metadata sent in HEADERS, plus deadline.
    /// A class (not a struct) so handlers can record response
    /// metadata the endpoint reads after dispatch.
    final class CallContext {
        var metadata: [String: String] = [:]
        /// Response initial metadata recorded via SetHeaders.
        var responseHeaders: [String: String] = [:]
        /// Response trailing metadata recorded via SetTrailers.
        var responseTrailers: [String: String] = [:]

        /// Record response initial metadata (sent lazily, before the first response message).
        func SetHeaders(_ md: [String: String]) {
            for (k, v) in md { responseHeaders[k] = v }
        }

        /// Record response trailing metadata (rides the terminal status frame).
        func SetTrailers(_ md: [String: String]) {
            for (k, v) in md { responseTrailers[k] = v }
        }
        /// Monotonic deadline (GrpcTime milliseconds) propagated
        /// via grpc-timeout, when the client set one.
        var deadlineMs: Double? = nil

        init() {}

        /// Seconds left before the deadline, or nil when unbounded.
        func TimeRemaining() -> Double? {
            guard let deadlineMs else { return nil }
            return max(0, (deadlineMs - GrpcTime.NowMs()) / 1000.0)
        }

        var DeadlineExceeded: Bool { TimeRemaining() == 0 }

        static func FromMetadata(_ metadata: [String: String]) -> CallContext {
            var ctx = CallContext()
            ctx.metadata = metadata
            if let remaining = Codec.ParseTimeout(metadata["grpc-timeout"]) {
                ctx.deadlineMs = GrpcTime.NowMs() + remaining * 1000.0
            }
            return ctx
        }
    }

    /// Sends response payloads of one inbound call.
    final class ResponseSink {
        private let endpoint: Endpoint
        private let streamId: UInt32

        init(_ endpoint: Endpoint, _ streamId: UInt32) {
            self.endpoint = endpoint
            self.streamId = streamId
        }

        // Wired to the CallContext by the endpoint (held by
        // reference so handler SetHeaders/SetTrailers mutations
        // are visible when the endpoint flushes).
        var ctx: CallContext? = nil
        var respHeaders: [String: String] { ctx?.responseHeaders ?? [:] }
        var respTrailers: [String: String] { ctx?.responseTrailers ?? [:] }
        var headersSent = false

        // A stream the endpoint has forgotten was RST by the
        // peer (or the channel went away): fail the send so a
        // producing handler stops instead of streaming into
        // the void.
        private func CheckOpen() throws {
            if endpoint.Stream(streamId) == nil {
                throw StatusException(Wire.CodeCancelled, "call cancelled")
            }
        }

        func Send(_ payload: [UInt8]) throws {
            try CheckOpen()
            try FlushHeaders()
            try endpoint.SendFrame(Codec.EncodeFrame(Wire.FrameData, streamId, payload))
        }

        func FlushHeaders() throws {
            if !headersSent {
                headersSent = true
                try SendHeaders(respHeaders)
            }
        }

        func SendHeaders() throws {
            try SendHeaders(respHeaders)
        }

        func SendHeaders(_ metadata: [String: String]) throws {
            try CheckOpen()
            headersSent = true
            try endpoint.SendFrame(Codec.HeadersFrame(streamId, nil, metadata))
        }

        func SendTrailers(_ status: StatusException) throws {
            var out = status
            if !respTrailers.isEmpty {
                var merged = respTrailers
                for (k, v) in status.trailers { merged[k] = v }
                out.trailers = merged
            }
            try endpoint.SendFrame(Codec.StatusFrame(Wire.FrameTrailers, streamId, out))
        }
    }

    /// Server-side call handler installed by Server.
    /// Returns the status that becomes the call's TRAILERS.
    typealias Dispatcher = (CallContext, Codec.Headers, StreamInput, ResponseSink) -> StatusException

    private let transport: Transport
    private var dispatcher: Dispatcher?
    private var nextId: UInt32
    private let sendLock = GrpcLock()
    private let streamsLock = GrpcLock()
    private var streams: [UInt32: StreamInput] = [:]
    private var closed = false
    private var started = false
    private var inlinePumpFlag = false
    private let stateLock = GrpcLock()

    /// The side that created the channel allocates odd stream ids, the
    /// answerer even. The read loop starts on Start() — after any
    /// dispatcher is installed, so an early HEADERS can never race
    /// dispatcher setup.
    init(_ transport: Transport, creator: Bool) {
        self.transport = transport
        self.nextId = creator ? 1 : 2
    }

    /// Start the read loop (idempotent). A TryRecv transport
    /// runs inline instead: no thread is spawned and stream
    /// waits pump the transport (single-threaded wasm32).
    func Start() {
        stateLock.lock()
        if started {
            stateLock.unlock()
            return
        }
        started = true
        inlinePumpFlag = transport.HasTryRecv
        stateLock.unlock()
        if inlinePumpFlag { return }
        #if canImport(Foundation)
        // Strong capture: the read loop keeps the endpoint alive for
        // as long as the transport delivers (callers may discard the
        // ServeTransport return value, as in every other language).
        let thread = Thread {
            self.ReadLoop()
        }
        thread.name = "grpcdc-endpoint"
        thread.start()
        #endif
    }

    /// Whether this endpoint runs in inline pump mode.
    func IsInlinePump() -> Bool { inlinePumpFlag }

    /// Inline mode: receive and dispatch at most one message.
    /// Stream waits call this through StreamInput's pump hook;
    /// a server-only program drives its endpoint by calling it
    /// in a loop.
    func PollOnce() {
        if IsClosed() { return }
        switch transport.TryRecv() {
        case .message(let data):
            if !IsClosed() { OnBytes(data) }
        case .wouldBlock:
            break
        case .closed:
            FailAll()
        }
    }

    private func AttachPump(_ input: StreamInput) {
        if inlinePumpFlag || transport.HasTryRecv {
            input.SetPump(self)
        }
    }

    func SetDispatcher(_ dispatcher: @escaping Dispatcher) {
        self.dispatcher = dispatcher
    }

    func SendFrame(_ frame: [UInt8]) throws {
        sendLock.lock()
        defer { sendLock.unlock() }
        try transport.Send(frame)
    }

    func OpenStream() -> (UInt32, StreamInput) {
        sendLock.lock()
        let id = nextId
        nextId += 2
        sendLock.unlock()
        let input = StreamInput()
        AttachPump(input)
        streamsLock.lock()
        streams[id] = input
        streamsLock.unlock()
        return (id, input)
    }

    func CloseStream(_ id: UInt32) {
        streamsLock.lock()
        let removed = streams.removeValue(forKey: id)
        streamsLock.unlock()
        removed?.SetPump(nil)
    }

    /// Abort one stream: RST out; a pending Recv wakes with CANCELLED.
    func CancelStream(_ id: UInt32) {
        streamsLock.lock()
        let input = streams.removeValue(forKey: id)
        streamsLock.unlock()
        if let input {
            input.Put(StreamEvent(kind: .rst, status: StatusException(Wire.CodeCancelled, "call cancelled")))
            input.Close()
        }
        try? SendFrame(Codec.StatusFrame(Wire.FrameRst, id,
                                         StatusException(Wire.CodeCancelled, "call cancelled")))
    }

    private func Stream(_ id: UInt32) -> StreamInput? {
        streamsLock.lock()
        defer { streamsLock.unlock() }
        return streams[id]
    }

    func Close() {
        stateLock.lock()
        if closed {
            stateLock.unlock()
            return
        }
        closed = true
        stateLock.unlock()
        transport.Close()
        FailAll()
    }

    private func FailAll() {
        streamsLock.lock()
        let all = streams
        streams.removeAll()
        streamsLock.unlock()
        for (_, input) in all {
            input.Put(StreamEvent(kind: .rst, status: StatusException(Wire.CodeUnavailable, "data channel closed")))
            input.Close()
        }
    }

    private func IsClosed() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return closed
    }

    private func ReadLoop() {
        while true {
            let data: [UInt8]
            do {
                data = try transport.Recv()
            } catch {
                FailAll()
                return
            }
            if IsClosed() { return }
            OnBytes(data)
        }
    }

    private func OnBytes(_ data: [UInt8]) {
        let frame: Codec.Frame
        do {
            frame = try Codec.DecodeFrame(data)
        } catch {
            return  // malformed frame: drop, keep the channel up
        }
        let frameType = frame.type
        let streamId = frame.streamId
        let payload = frame.payload
@@FRAME_DISPATCH@@
    }

    private func OnTerminal(_ streamId: UInt32, _ payload: [UInt8], _ kind: EventKind) {
        if let input = Stream(streamId) {
            input.Put(StreamEvent(kind: kind, status: Codec.ParseStatus(payload)))
            input.Close()
            CloseStream(streamId)
        }
    }

    private func PushEvent(_ streamId: UInt32, _ event: StreamEvent) {
        Stream(streamId)?.Put(event)
    }

    private func OnHeaders(_ streamId: UInt32, _ payload: [UInt8]) {
        let headers: Codec.Headers
        do {
            headers = try Codec.ParseHeaders(payload)
        } catch {
            try? SendFrame(Codec.StatusFrame(Wire.FrameRst, streamId, StatusException.ToStatus(error)))
            return
        }
        guard let path = headers.path else {
            // Server response headers for one of our outbound streams.
            Stream(streamId)?.Put(StreamEvent(kind: .headers, headers: headers))
            return
        }
        if Stream(streamId) != nil {
            try? SendFrame(Codec.StatusFrame(
                Wire.FrameRst, streamId,
                StatusException(Wire.CodeInternal, "HEADERS for stream already in use")))
            return
        }
        guard let dispatcher = dispatcher else {
            try? SendFrame(Codec.StatusFrame(
                Wire.FrameTrailers, streamId,
                StatusException(Wire.CodeUnimplemented, "unknown method \(path)")))
            return
        }
        let streamInput = StreamInput()
        AttachPump(streamInput)
        streamsLock.lock()
        streams[streamId] = streamInput
        streamsLock.unlock()
        if inlinePumpFlag {
            // Single-threaded mode: run the handler on this pump
            // stack; its stream waits re-enter PollOnce.
            DispatchCall(streamId, streamInput, headers, dispatcher)
            return
        }
        #if canImport(Foundation)
        let thread = Thread { [weak self] in
            guard let self = self else { return }
            self.DispatchCall(streamId, streamInput, headers, dispatcher)
        }
        thread.name = "grpcdc-call"
        thread.start()
        #endif
    }

    private func DispatchCall(_ streamId: UInt32, _ streamInput: StreamInput,
                              _ headers: Codec.Headers, _ dispatcher: Dispatcher) {
        let sink = ResponseSink(self, streamId)
        // No eager HEADERS: initial metadata flushes lazily via
        // the sink (first DATA, or below on a DATA-less success)
        // so handlers can SetHeaders first. Errors end
        // trailers-only, as gRPC allows.
        let ctx = CallContext.FromMetadata(headers.metadata)
        sink.ctx = ctx
        let status = dispatcher(ctx, headers, streamInput, sink)
        if status.code == Wire.CodeOk {
            try? sink.FlushHeaders()
        }
        try? sink.SendTrailers(status)
        CloseStream(streamId)
    }
}
GRPC_RUNTIME_EOF
)

(define swift-channel-body
#<<GRPC_RUNTIME_EOF
#if canImport(Foundation)
import Foundation
#endif
#if canImport(Dispatch)
import Dispatch
#endif
#if canImport(Foundation)
/// Run an async operation to completion on a blocking thread.
/// Shared by generated stubs and tests; defined once here (it was
/// previously emitted per stub file, which collided when several
/// generated stubs share one module).
func RunBlocking<T>(_ body: @escaping () async throws -> T) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<T, Error>!
    Task.detached {
        do {
            result = .success(try await body())
        } catch {
            result = .failure(error)
        }
        semaphore.signal()
    }
    semaphore.wait()
    return try result.get()
}
#endif

/// Channel: the client side of one Endpoint.
final class Channel {
    private let endpointInstance: Endpoint

    /// Wrap a transport, allocating odd stream ids.
    init(_ transport: Transport) {
        endpointInstance = Endpoint(transport, creator: true)
        endpointInstance.Start()
    }

    /// Wrap an existing endpoint (bidirectional use; starts its read loop).
    init(endpoint: Endpoint) {
        endpointInstance = endpoint
        endpoint.Start()
    }

    var endpoint: Endpoint { endpointInstance }

    /// Receives response messages of one call.
    final class ClientStream {
        let streamId: UInt32
        private let endpoint: Endpoint
        private let input: Endpoint.StreamInput
        private(set) var headers: Codec.Headers?
        /// Trailing metadata of the terminal status (nil until it arrives).
        private(set) var trailers: [String: String]?
        var deadlineMs: Double? = nil
        var traceCtx: Tracing.TraceContext? = nil
        var tracePath: String? = nil
        private var traceEnded = false
        private var terminated = false

        func EndTrace(_ status: String) {
            if !traceEnded {
                traceEnded = true
                Tracing.TraceEnd("client", tracePath ?? "", traceCtx, status)
            }
        }

        init(_ endpoint: Endpoint, _ streamId: UInt32, _ input: Endpoint.StreamInput) {
            self.endpoint = endpoint
            self.streamId = streamId
            self.input = input
        }

        /// Send one request message on an open stream (no half-close).
        func Send(_ msg: Marshaler) throws {
            try endpoint.SendFrame(Codec.EncodeFrame(Wire.FrameData, streamId, msg.MarshalDc()))
        }

        /// Half-close an open stream (no more requests).
        func HalfClose() throws {
            try endpoint.SendFrame(Codec.EncodeFrame(Wire.FrameHalfClose, streamId, []))
        }

        /// Abort this stream (sends RST, wakes a pending Recv).
        /// After normal completion this just closes locally.
        func Cancel() {
            if terminated {
                endpoint.CloseStream(streamId)
                return
            }
            terminated = true
            endpoint.CancelStream(streamId)
        }

        /// Abandon this stream: RST CANCELLED unless it already completed.
        func Close() { Cancel() }

        /// Decode the next response into resp. EndOfStreamError means
        /// the call completed OK; StatusException reports the
        /// trailers status.
        func Recv(_ resp: Unmarshaler) throws {
            while true {
                let event: Endpoint.StreamEvent?
                if let deadlineMs {
                    let result = input.Get(deadlineMs: deadlineMs)
                    if result.timedOut {
                        terminated = true
                        endpoint.CancelStream(streamId)
                        throw StatusException(Wire.CodeDeadlineExceeded, "deadline exceeded")
                    }
                    event = result.event
                } else {
                    event = input.Get()
                }
                guard let event else {
                    terminated = true
                    throw StatusException(Wire.CodeUnavailable, "data channel closed")
                }
                switch event.kind {
                case .headers:
                    headers = event.headers
                case .data:
                    resp.UnmarshalDc(event.payload)
                    return
                case .trailers:
                    terminated = true
                    trailers = event.status?.trailers
                    EndTrace(Wire.StatusName(event.status?.code ?? Wire.CodeOk))
                    if let status = event.status, status.code != Wire.CodeOk {
                        throw status
                    }
                    throw EndOfStreamError()
                case .rst:
                    terminated = true
                    let status = event.status ?? StatusException(Wire.CodeUnavailable, "stream reset")
                    trailers = status.trailers
                    EndTrace(Wire.StatusName(status.code))
                    throw status
                default:
                    continue
                }
            }
        }
    }

    private func Open(_ path: String, _ metadata: [String: String]?, _ timeout: Double? = nil) throws -> ClientStream {
        var metadata = metadata
        var deadlineMs: Double? = nil
        var traceCtx: Tracing.TraceContext? = nil
        if timeout != nil || Tracing.Enabled {
            var merged = metadata ?? [:]
            if let timeout {
                deadlineMs = GrpcTime.NowMs() + timeout * 1000.0
                merged["grpc-timeout"] = Codec.EncodeTimeout(timeout)
            }
            if Tracing.Enabled {
                traceCtx = Tracing.TraceStart("client", path, Tracing.ParseTraceparent(merged["traceparent"]))
                if let traceCtx {
                    merged["traceparent"] = Tracing.FormatTraceparent(traceCtx.traceId, traceCtx.spanId, traceCtx.sampled)
                }
            }
            metadata = merged
        }
        let (id, input) = endpointInstance.OpenStream()
        do {
            try endpointInstance.SendFrame(Codec.HeadersFrame(id, path, metadata))
        } catch {
            endpointInstance.CloseStream(id)
            Tracing.TraceEnd("client", path, traceCtx, "UNAVAILABLE")
            throw error
        }
        let stream = ClientStream(endpointInstance, id, input)
        stream.deadlineMs = deadlineMs
        stream.traceCtx = traceCtx
        stream.tracePath = path
        return stream
    }

    private func SendMessage(_ stream: ClientStream, _ msg: Marshaler) throws {
        try endpointInstance.SendFrame(Codec.EncodeFrame(Wire.FrameData, stream.streamId, msg.MarshalDc()))
    }

    private func HalfClose(_ stream: ClientStream) throws {
        try endpointInstance.SendFrame(Codec.EncodeFrame(Wire.FrameHalfClose, stream.streamId, []))
    }

    private func SendAll<T: Marshaler>(_ stream: ClientStream, _ reqs: [T]) throws {
        for req in reqs { try SendMessage(stream, req) }
        try HalfClose(stream)
    }

    private func CollectOne(_ stream: ClientStream, _ resp: Unmarshaler, _ what: String) throws {
        var got = false
        while true {
            do {
                try stream.Recv(resp)
            } catch is EndOfStreamError {
                if !got {
                    throw StatusException(Wire.CodeInternal, "call closed with no response")
                }
                return
            }
            if got {
                throw StatusException(Wire.CodeInternal, "\(what) received more than one response")
            }
            got = true
        }
    }

    /// Run a unary call, decoding the single response into resp.
    func Unary(_ path: String, _ req: Marshaler, _ resp: Unmarshaler, _ metadata: [String: String]? = nil, _ timeout: Double? = nil) throws {
        let stream = try Open(path, metadata, timeout)
        defer { endpointInstance.CloseStream(stream.streamId) }
        try SendMessage(stream, req)
        try HalfClose(stream)
        try CollectOne(stream, resp, "unary call")
    }

    /// Start a server-streaming call.
    func ServerStream(_ path: String, _ req: Marshaler, _ metadata: [String: String]? = nil, _ timeout: Double? = nil) throws -> ClientStream {
        let stream = try Open(path, metadata, timeout)
        try SendMessage(stream, req)
        try HalfClose(stream)
        return stream
    }

    /// Send all requests, then decode the one response into resp.
    func ClientStreamCall<T: Marshaler>(_ path: String, _ reqs: [T], _ resp: Unmarshaler, _ metadata: [String: String]? = nil, _ timeout: Double? = nil) throws {
        let stream = try Open(path, metadata, timeout)
        defer { endpointInstance.CloseStream(stream.streamId) }
        try SendAll(stream, reqs)
        try CollectOne(stream, resp, "client-streaming call")
    }

    /// Open a stream without sending anything: drive it with
    /// ClientStream.Send / HalfClose / Recv / Cancel.
    func OpenStream(_ path: String, _ metadata: [String: String]? = nil, _ timeout: Double? = nil) throws -> ClientStream {
        return try Open(path, metadata, timeout)
    }

    /// Start a bidi call with all requests sent up front.
    func Bidi<T: Marshaler>(_ path: String, _ reqs: [T], _ metadata: [String: String]? = nil, _ timeout: Double? = nil) throws -> ClientStream {
        let stream = try Open(path, metadata, timeout)
        try SendAll(stream, reqs)
        return stream
    }
}
GRPC_RUNTIME_EOF
)

(define swift-server-body
#<<GRPC_RUNTIME_EOF
/// Server: dispatches inbound calls to registered methods.
final class Server {
    public init() {}

    static let KindUnary = "unary"
    static let KindServerStreaming = "server-streaming"
    static let KindClientStreaming = "client-streaming"
    static let KindBidi = "bidi"

    /// Reads request messages of one inbound call.
    final class RequestStream {
        private let input: Endpoint.StreamInput

        init(_ input: Endpoint.StreamInput) {
            self.input = input
        }

        /// Next request payload; EndOfStreamError at half-close.
        func RecvRaw() throws -> [UInt8] {
            while true {
                guard let event = input.Get() else {
                    throw StatusException(Wire.CodeUnavailable, "data channel closed")
                }
                switch event.kind {
                case .data:
                    return event.payload
                case .halfClose:
                    throw EndOfStreamError()
                case .trailers, .rst:
                    throw event.status ?? StatusException(Wire.CodeUnavailable, "stream closed")
                default:
                    continue  // ignore HEADERS on the request side
                }
            }
        }

        /// Decode the next request message into req.
        func RecvInto(_ req: Unmarshaler) throws {
            try req.UnmarshalDc(RecvRaw())
        }
    }

    /// Sends response payloads of one inbound call.
    typealias ServerSink = ([UInt8]) throws -> Void

    /// Implements one method against raw payloads; stubs adapt it.
    typealias MethodHandler = (Endpoint.CallContext, RequestStream, @escaping ServerSink) throws -> Void

    struct Method {
        var name: String
        var path: String
        var kind: String
        var handler: MethodHandler

        public init(name: String, path: String, kind: String, handler: @escaping MethodHandler) {
            self.name = name
            self.path = path
            self.kind = kind
            self.handler = handler
        }
    }

    struct ServiceDesc {
        var name: String
        var methods: [Method]

        public init(name: String, methods: [Method]) {
            self.name = name
            self.methods = methods
        }
    }

    /// Method table shared with the dispatcher closure, so registered
    /// handlers stay valid as long as the endpoint lives.
    final class Shared {
        var methods: [String: Method] = [:]
    }

    private let shared = Shared()
    private var endpointRef: Endpoint?

    /// Adds a service's methods (generated code calls it).
    func RegisterService(_ desc: ServiceDesc) {
        for method in desc.methods {
            shared.methods[method.path] = method
        }
    }

    /// Attach to a transport (even stream ids); returns the Endpoint.
    @discardableResult
    func ServeTransport(_ transport: Transport) -> Endpoint {
        let endpoint = Endpoint(transport, creator: false)
        ServeEndpoint(endpoint)
        return endpoint
    }

    /// Attach to an existing endpoint (starts its read loop).
    func ServeEndpoint(_ endpoint: Endpoint) {
        endpointRef = endpoint
        let shared = self.shared
        endpoint.SetDispatcher { ctx, headers, input, sink in
            Server.Dispatch(shared, ctx, headers, input, sink)
        }
        endpoint.Start()
    }

    private static func Dispatch(_ shared: Shared, _ ctx: Endpoint.CallContext,
                                 _ headers: Codec.Headers, _ input: Endpoint.StreamInput,
                                 _ sink: Endpoint.ResponseSink) -> StatusException {
        guard let path = headers.path, let method = shared.methods[path] else {
            return StatusException(Wire.CodeUnimplemented, "unknown method \(headers.path ?? "")")
        }
        let traceCtx = Tracing.TraceStart("server", path, Tracing.ParseTraceparent(headers.metadata["traceparent"]))
        var result = StatusException(Wire.CodeOk, "")
        do {
            let reqs = RequestStream(input)
            try method.handler(ctx, reqs) { payload in
                try sink.Send(payload)
            }
        } catch {
            result = StatusException.ToStatus(error)
        }
        Tracing.TraceEnd("server", path, traceCtx, Wire.StatusName(result.code))
        return result
    }
}
GRPC_RUNTIME_EOF
)

(define swift-loopback-body
#<<GRPC_RUNTIME_EOF
/// In-memory transport pair for tests (one queue per direction).
enum MemoryTransport {
    private final class Impl: Transport {
        private let inbox: BlockingQueue<[UInt8]>
        private let outbox: BlockingQueue<[UInt8]>
        private var closed = false
        private let lock = GrpcLock()

        init(inbox: BlockingQueue<[UInt8]>, outbox: BlockingQueue<[UInt8]>) {
            self.inbox = inbox
            self.outbox = outbox
        }

        func Send(_ data: [UInt8]) throws {
            lock.lock()
            let isClosed = closed
            lock.unlock()
            if isClosed { throw EndOfStreamError() }
            outbox.Add(data)
        }

        func Recv() throws -> [UInt8] {
            guard let data = inbox.Take() else { throw EndOfStreamError() }
            return data
        }

        func Close() {
            lock.lock()
            closed = true
            lock.unlock()
            inbox.Close()
        }
    }

    /// Two connected in-memory transports.
    static func Pair() -> (Transport, Transport) {
        let aToB = BlockingQueue<[UInt8]>()
        let bToA = BlockingQueue<[UInt8]>()
        return (Impl(inbox: bToA, outbox: aToB), Impl(inbox: aToB, outbox: bToA))
    }
}
GRPC_RUNTIME_EOF
)


(define swift-sidecar-body
#<<GRPC_RUNTIME_EOF
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Transport over the Rust WebRTC-Direct sidecar: the sidecar
/// owns DTLS/SCTP/TURN and bridges one datachannel to a local
/// TCP socket using u32 big-endian length-prefixed messages
/// (one prefix per DataChannel message). POSIX sockets only;
/// `host` must be an IP literal (the sidecar is local).
final class SidecarTransport: Transport {
    private let fd: Int32
    private var closedFlag = false

    init(fd: Int32) {
        self.fd = fd
    }

    static func Connect(_ host: String, _ port: Int) throws -> SidecarTransport {
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        if fd < 0 { throw EndOfStreamError() }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr(host)
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc != 0 { throw EndOfStreamError() }
        return SidecarTransport(fd: fd)
    }

    func Send(_ data: [UInt8]) throws {
        if closedFlag { throw EndOfStreamError() }
        var frame = [UInt8](repeating: 0, count: 4)
        frame[0] = UInt8((data.count >> 24) & 0xff)
        frame[1] = UInt8((data.count >> 16) & 0xff)
        frame[2] = UInt8((data.count >> 8) & 0xff)
        frame[3] = UInt8(data.count & 0xff)
        frame.append(contentsOf: data)
        try writeAll(frame)
    }

    func Recv() throws -> [UInt8] {
        let header = try readExact(4)
        let length = (Int(header[0]) << 24) | (Int(header[1]) << 16) | (Int(header[2]) << 8) | Int(header[3])
        return try readExact(length)
    }

    func Close() {
        closedFlag = true
        close(fd)
    }

    private func writeAll(_ bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBufferPointer { buf in
                send(fd, buf.baseAddress! + offset, bytes.count - offset, 0)
            }
            if n <= 0 { throw EndOfStreamError() }
            offset += n
        }
    }

    private func readExact(_ count: Int) throws -> [UInt8] {
        var out = [UInt8]()
        while out.count < count {
            var chunk = [UInt8](repeating: 0, count: count - out.count)
            let n = chunk.withUnsafeMutableBufferPointer { buf in
                recv(fd, buf.baseAddress!, count - out.count, 0)
            }
            if n <= 0 { throw EndOfStreamError() }
            out.append(contentsOf: chunk[..<n])
        }
        return out
    }
}
GRPC_RUNTIME_EOF
)

(define swift-dynamic-body
#<<GRPC_RUNTIME_EOF
import Foundation

/// Dynamic, descriptor-driven client and server.
///
/// Parses a FileDescriptorSet (as produced by
/// `protoc --descriptor_set_out`) at runtime and builds clients and
/// servers whose messages are generic field maps — no generated stubs
/// required. This is the runtime-generation counterpart of the
/// protoc-plugin surfaces: schemas arrive as data (descriptor.proto),
/// not as code.
///
/// Generic values by field type: varint family -> int64/uint64/bool,
/// string -> string, bytes/message -> bytes / message(GenericMessage),
/// fixed/float -> uint64/int64 / double. Repeated fields are lists in
/// field-number order.
enum Dynamic {
    // FieldDescriptorProto.Type values (descriptor.proto).
    static let TypeDouble = 1
    static let TypeFloat = 2
    static let TypeInt64 = 3
    static let TypeUint64 = 4
    static let TypeInt32 = 5
    static let TypeFixed64 = 6
    static let TypeFixed32 = 7
    static let TypeBool = 8
    static let TypeString = 9
    static let TypeGroup = 10
    static let TypeMessage = 11
    static let TypeBytes = 12
    static let TypeUint32 = 13
    static let TypeEnum = 14
    static let TypeSfixed32 = 15
    static let TypeSfixed64 = 16
    static let TypeSint32 = 17
    static let TypeSint64 = 18

    static let LabelRepeated = 3

    final class FieldModel {
        var number: Int = 0
        var name: String = ""
        var type: Int = 0
        var repeated: Bool = false
        var typeName: String = ""  // for TypeMessage, e.g. ".echo.EchoRequest"
    }

    final class MessageModel {
        var fullName: String = ""
        var fields: [Int: FieldModel] = [:]
        var byName: [String: Int] = [:]
    }

    final class MethodModel {
        var name: String = ""
        var path: String = ""
        var kind: String = ""
        var input: MessageModel!
        var output: MessageModel!
    }

    final class ServiceModel {
        var fullName: String = ""
        var methods: [String: MethodModel] = [:]
    }

    /// Parsed descriptor set: messages and services by full name.
    /// Message keys carry the leading dot (".echo.EchoRequest"),
    /// matching FieldDescriptorProto.type_name; service keys do not
    /// ("echo.Echo").
    final class FileModel {
        var messages: [String: MessageModel] = [:]
        var services: [String: ServiceModel] = [:]

        func Message(_ fullName: String) throws -> MessageModel {
            guard let m = messages[fullName] else {
                throw StatusException(Wire.CodeInvalidArgument, "unknown message \(fullName)")
            }
            return m
        }

        func Service(_ fullName: String) throws -> ServiceModel {
            guard let s = services[fullName] else {
                throw StatusException(Wire.CodeInvalidArgument, "unknown service \(fullName)")
            }
            return s
        }
    }

    enum GenericValue {
        case int64(Int64)
        case uint64(UInt64)
        case bool(Bool)
        case double(Double)
        case string(String)
        case bytes([UInt8])
        case message(GenericMessage)
    }

    /// A message as field number -> list of values (descriptor order).
    ///
    /// Fields not in the model are retained as raw encoded chunks in
    /// `unknown` (protobuf unknown-field retention): a decode -> encode
    /// round trip re-emits them after the known fields, so intermediate
    /// hops do not strip newer fields.
    final class GenericMessage {
        var model: MessageModel?
        var values: [Int: [GenericValue]] = [:]
        var unknown: [[UInt8]] = []

        init(_ model: MessageModel? = nil) {
            self.model = model
        }

        @discardableResult
        func Set(_ number: Int, _ value: GenericValue) -> GenericMessage {
            values[number] = [value]
            return self
        }

        @discardableResult
        func Add(_ number: Int, _ value: GenericValue) -> GenericMessage {
            values[number, default: []].append(value)
            return self
        }

        func Get(_ number: Int) -> GenericValue? {
            values[number]?.first
        }

        func GetString(_ number: Int) -> String {
            if case .string(let s)? = Get(number) { return s }
            return ""
        }

        func GetInt(_ number: Int) -> Int64 {
            switch Get(number) {
            case .int64(let v)?: return v
            case .uint64(let v)?: return Int64(bitPattern: v)
            case .bool(let v)?: return v ? 1 : 0
            default: return 0
            }
        }
    }

    // ------------------------------------------------------------------
    // Generic protobuf codec
    // ------------------------------------------------------------------

    struct PbField {
        var number: Int = 0
        var wire: Int = 0
        var varint: UInt64 = 0
        var bytes: [UInt8] = []
        var chunk: [UInt8] = []
    }

    struct PbReader {
        let buf: [UInt8]
        var pos = 0

        mutating func Varint() throws -> UInt64 {
            var result: UInt64 = 0
            var shift = 0
            while true {
                if pos >= buf.count {
                    throw StatusException(Wire.CodeInvalidArgument, "truncated varint")
                }
                let b = buf[pos]
                pos += 1
                result |= UInt64(b & 0x7f) << shift
                if (b & 0x80) == 0 { return result }
                shift += 7
                if shift >= 70 {
                    throw StatusException(Wire.CodeInvalidArgument, "varint too long")
                }
            }
        }

        mutating func LenBytes() throws -> [UInt8] {
            let n = Int(try Varint())
            if pos + n > buf.count {
                throw StatusException(Wire.CodeInvalidArgument, "truncated bytes field")
            }
            defer { pos += n }
            return Array(buf[pos..<(pos + n)])
        }

        mutating func Next() throws -> PbField? {
            if pos >= buf.count { return nil }
            let start = pos
            let tag = try Varint()
            var field = PbField()
            field.number = Int(tag >> 3)
            field.wire = Int(tag & 7)
            switch field.wire {
            case 0:
                field.varint = try Varint()
            case 2:
                field.bytes = try LenBytes()
            case 1:
                if pos + 8 > buf.count {
                    throw StatusException(Wire.CodeInvalidArgument, "truncated fixed64")
                }
                field.bytes = Array(buf[pos..<(pos + 8)])
                pos += 8
            case 5:
                if pos + 4 > buf.count {
                    throw StatusException(Wire.CodeInvalidArgument, "truncated fixed32")
                }
                field.bytes = Array(buf[pos..<(pos + 4)])
                pos += 4
            default:
                throw StatusException(Wire.CodeInvalidArgument, "unsupported wire type \(field.wire)")
            }
            field.chunk = Array(buf[start..<pos])
            return field
        }
    }

    private static func AsString(_ field: PbField) -> String {
        String(decoding: field.bytes, as: UTF8.self)
    }

    private static func WireType(_ type: Int) -> Int {
        switch type {
        case TypeInt64, TypeUint64, TypeInt32, TypeBool, TypeUint32, TypeEnum, TypeSint32, TypeSint64:
            return 0
        case TypeFixed64, TypeSfixed64, TypeDouble:
            return 1
        case TypeString, TypeBytes, TypeMessage, TypeGroup:
            return 2
        case TypeFixed32, TypeSfixed32, TypeFloat:
            return 5
        default:
            return -1
        }
    }

    private static func EncodeVarint(_ out: inout [UInt8], _ value: UInt64) {
        var v = value
        while v > 0x7f {
            out.append(UInt8((v & 0x7f) | 0x80))
            v >>= 7
        }
        out.append(UInt8(v))
    }

    private static func ZigzagEncode(_ v: Int64) -> UInt64 {
        UInt64(bitPattern: (v << 1) ^ (v >> 63))
    }

    private static func ZigzagDecode(_ v: UInt64) -> Int64 {
        Int64(bitPattern: v >> 1) ^ -Int64(v & 1)
    }

    private static func ValueAsI64(_ value: GenericValue) -> Int64 {
        switch value {
        case .int64(let v): return v
        case .uint64(let v): return Int64(bitPattern: v)
        case .bool(let v): return v ? 1 : 0
        default: return 0
        }
    }

    private static func ValueAsU64(_ value: GenericValue) -> UInt64 {
        switch value {
        case .uint64(let v): return v
        case .int64(let v): return UInt64(bitPattern: v)
        case .bool(let v): return v ? 1 : 0
        default: return 0
        }
    }

    static func EncodeGeneric(_ model: MessageModel, _ message: GenericMessage, _ file: FileModel) throws -> [UInt8] {
        var out: [UInt8] = []
        for number in message.values.keys.sorted() {
            guard let field = model.fields[number] else {
                throw StatusException(Wire.CodeInvalidArgument,
                                      "unknown field \(number) for \(model.fullName)")
            }
            let values = message.values[number]!
            if field.repeated {
                for value in values {
                    try EncodeValue(&out, field, value, file)
                }
            } else if let value = values.first {
                try EncodeValue(&out, field, value, file)
            }
        }
        for chunk in message.unknown {
            out.append(contentsOf: chunk)
        }
        return out
    }

    private static func EncodeValue(_ out: inout [UInt8], _ field: FieldModel, _ value: GenericValue, _ file: FileModel) throws {
        let wire = WireType(field.type)
        if wire < 0 {
            throw StatusException(Wire.CodeInvalidArgument, "unsupported field type \(field.type)")
        }
        EncodeVarint(&out, (UInt64(field.number) << 3) | UInt64(wire))
        switch wire {
        case 0:
            var v: UInt64
            if field.type == TypeSint32 || field.type == TypeSint64 {
                v = ZigzagEncode(ValueAsI64(value))
                if field.type == TypeSint32 { v &= 0xffffffff }
            } else if field.type == TypeBool {
                v = ValueAsI64(value) != 0 ? 1 : 0
            } else {
                v = ValueAsU64(value)
            }
            EncodeVarint(&out, v)
        case 1:
            var v: UInt64
            if field.type == TypeDouble {
                var d: Double
                if case .double(let f) = value {
                    d = f
                } else {
                    d = Double(ValueAsI64(value))
                }
                v = d.bitPattern
            } else {
                v = ValueAsU64(value)
            }
            for i in 0..<8 { out.append(UInt8((v >> (8 * i)) & 0xff)) }
        case 5:
            var v: UInt32
            if field.type == TypeFloat {
                var f: Float
                if case .double(let d) = value {
                    f = Float(d)
                } else {
                    f = Float(ValueAsI64(value))
                }
                v = f.bitPattern
            } else {
                v = UInt32(truncatingIfNeeded: ValueAsU64(value))
            }
            for i in 0..<4 { out.append(UInt8((v >> (8 * i)) & 0xff)) }
        default:
            var data: [UInt8]
            if field.type == TypeString, case .string(let s) = value {
                data = [UInt8](s.utf8)
            } else if field.type == TypeMessage, case .message(let m) = value {
                data = try EncodeGeneric(file.Message(field.typeName), m, file)
            } else if case .bytes(let b) = value {
                data = b
            } else if case .string(let s) = value {
                data = [UInt8](s.utf8)
            } else {
                throw StatusException(Wire.CodeInvalidArgument,
                                      "value does not match field \(field.name) type \(field.type)")
            }
            EncodeVarint(&out, UInt64(data.count))
            out.append(contentsOf: data)
        }
    }

    static func DecodeGeneric(_ model: MessageModel, _ data: [UInt8], _ file: FileModel) throws -> GenericMessage {
        let message = GenericMessage(model)
        var reader = PbReader(buf: data)
        while let raw = try reader.Next() {
            guard let field = model.fields[raw.number] else {
                // Unknown field: retain the raw encoded chunk verbatim.
                message.unknown.append(raw.chunk)
                continue
            }
            message.values[raw.number, default: []].append(try DecodeValue(field, raw, file))
        }
        return message
    }

    private static func DecodeValue(_ field: FieldModel, _ raw: PbField, _ file: FileModel) throws -> GenericValue {
        switch raw.wire {
        case 0:
            if field.type == TypeBool { return .bool(raw.varint != 0) }
            if field.type == TypeSint32 || field.type == TypeSint64 {
                return .int64(ZigzagDecode(raw.varint))
            }
            if field.type == TypeInt32 || field.type == TypeEnum {
                return .int64(Int64(Int32(bitPattern: UInt32(truncatingIfNeeded: raw.varint))))
            }
            if field.type == TypeInt64 { return .int64(Int64(bitPattern: raw.varint)) }
            return .uint64(raw.varint)
        case 1:
            var v: UInt64 = 0
            for i in 0..<8 { v |= UInt64(raw.bytes[i]) << (8 * i) }
            if field.type == TypeDouble { return .double(Double(bitPattern: v)) }
            if field.type == TypeSfixed64 { return .int64(Int64(bitPattern: v)) }
            return .uint64(v)
        case 5:
            var v: UInt32 = 0
            for i in 0..<4 { v |= UInt32(raw.bytes[i]) << (8 * i) }
            if field.type == TypeFloat { return .double(Double(Float(bitPattern: v))) }
            if field.type == TypeSfixed32 { return .int64(Int64(Int32(bitPattern: v))) }
            return .uint64(UInt64(v))
        default:
            if field.type == TypeString {
                return .string(String(decoding: raw.bytes, as: UTF8.self))
            }
            if field.type == TypeMessage {
                return .message(try DecodeGeneric(file.Message(field.typeName), raw.bytes, file))
            }
            return .bytes(raw.bytes)
        }
    }

    // ------------------------------------------------------------------
    // Descriptor set parsing
    // ------------------------------------------------------------------

    /// Parse FileDescriptorSet bytes into a FileModel.
    static func ParseDescriptorSet(_ data: [UInt8]) throws -> FileModel {
        let file = FileModel()
        var pendingServices: [(String, [UInt8])] = []
        var reader = PbReader(buf: data)
        while let f = try reader.Next() {
            if f.number != 1 { continue }
            var package = ""
            var messageTypes: [[UInt8]] = []
            var serviceTypes: [[UInt8]] = []
            var fr = PbReader(buf: f.bytes)
            while let ff = try fr.Next() {
                switch ff.number {
                case 2: package = AsString(ff)
                case 4: messageTypes.append(ff.bytes)
                case 6: serviceTypes.append(ff.bytes)
                default: break
                }
            }
            for m in messageTypes {
                try ParseMessage(package, m, file)
            }
            for s in serviceTypes {
                pendingServices.append((package, s))
            }
        }
        for (package, serviceBytes) in pendingServices {
            try ParseService(package, serviceBytes, file)
        }
        return file
    }

    private static func ParseMessage(_ prefix: String, _ data: [UInt8], _ file: FileModel) throws {
        var name = ""
        var rawFields: [[UInt8]] = []
        var nested: [[UInt8]] = []
        var reader = PbReader(buf: data)
        while let f = try reader.Next() {
            switch f.number {
            case 1: name = AsString(f)
            case 2: rawFields.append(f.bytes)
            case 3: nested.append(f.bytes)
            default: break
            }
        }
        let fullName = prefix.isEmpty ? name : "\(prefix).\(name)"
        let model = MessageModel()
        model.fullName = fullName
        for fieldBytes in rawFields {
            let field = try ParseField(fieldBytes)
            model.byName[field.name] = field.number
            model.fields[field.number] = field
        }
        file.messages["." + fullName] = model
        for nestedBytes in nested {
            try ParseMessage(fullName, nestedBytes, file)
        }
    }

    private static func ParseField(_ data: [UInt8]) throws -> FieldModel {
        let field = FieldModel()
        var reader = PbReader(buf: data)
        while let f = try reader.Next() {
            switch f.number {
            case 1: field.name = AsString(f)
            case 3: field.number = Int(f.varint)
            case 4: field.repeated = Int(f.varint) == LabelRepeated
            case 5: field.type = Int(f.varint)
            case 6: field.typeName = AsString(f)
            default: break
            }
        }
        return field
    }

    private static func KindOf(_ clientStreaming: Bool, _ serverStreaming: Bool) -> String {
        if clientStreaming && serverStreaming { return Server.KindBidi }
        if serverStreaming { return Server.KindServerStreaming }
        if clientStreaming { return Server.KindClientStreaming }
        return Server.KindUnary
    }

    private static func ParseService(_ package: String, _ data: [UInt8], _ file: FileModel) throws {
        var name = ""
        var rawMethods: [[UInt8]] = []
        var reader = PbReader(buf: data)
        while let f = try reader.Next() {
            switch f.number {
            case 1: name = AsString(f)
            case 2: rawMethods.append(f.bytes)
            default: break
            }
        }
        let fullName = package.isEmpty ? name : "\(package).\(name)"
        let service = ServiceModel()
        service.fullName = fullName
        for methodBytes in rawMethods {
            var mname = ""
            var inputType = ""
            var outputType = ""
            var clientStreaming = false
            var serverStreaming = false
            var mr = PbReader(buf: methodBytes)
            while let mf = try mr.Next() {
                switch mf.number {
                case 1: mname = AsString(mf)
                case 2: inputType = AsString(mf)
                case 3: outputType = AsString(mf)
                case 5: clientStreaming = mf.varint != 0
                case 6: serverStreaming = mf.varint != 0
                default: break
                }
            }
            let method = MethodModel()
            method.name = mname
            method.path = "/\(fullName)/\(mname)"
            method.kind = KindOf(clientStreaming, serverStreaming)
            method.input = try file.Message(inputType)
            method.output = try file.Message(outputType)
            service.methods[mname] = method
        }
        file.services[fullName] = service
    }

    // ------------------------------------------------------------------
    // Client / server surfaces
    // ------------------------------------------------------------------

    /// Adapts a (MessageModel, GenericMessage) pair to the Channel
    /// marshal/unmarshal contract.
    private final class BoundMessage: Marshaler, Unmarshaler {
        private let model: MessageModel
        private let file: FileModel
        var generic: GenericMessage

        init(_ model: MessageModel, _ generic: GenericMessage, _ file: FileModel) {
            self.model = model
            self.generic = generic
            self.file = file
        }

        func MarshalDc() -> [UInt8] {
            // Channel surfaces are throwing; encoding a schema-conformant
            // message cannot fail in practice. Surface failure as empty.
            (try? EncodeGeneric(model, generic, file)) ?? []
        }

        func UnmarshalDc(_ data: [UInt8]) {
            if let decoded = try? DecodeGeneric(model, data, file) {
                generic = decoded
            }
        }
    }

    /// Runtime-built client: methods resolve from the FileModel.
    final class DynamicClient {
        private let channel: Channel
        private let model: FileModel

        init(_ channel: Channel, _ model: FileModel) {
            self.channel = channel
            self.model = model
        }

        private func Method(_ service: String, _ method: String) throws -> MethodModel {
            let svc = try model.Service(service)
            guard let m = svc.methods[method] else {
                throw StatusException(Wire.CodeInvalidArgument, "unknown method \(service)/\(method)")
            }
            return m
        }

        func Unary(_ service: String, _ method: String, _ req: GenericMessage, _ metadata: [String: String]? = nil, _ timeout: Double? = nil) throws -> GenericMessage {
            let m = try Method(service, method)
            let resp = BoundMessage(m.output, GenericMessage(m.output), model)
            try channel.Unary(m.path, BoundMessage(m.input, req, model), resp, metadata, timeout)
            return resp.generic
        }

        /// Receiving stream of generic responses.
        final class DynamicStream {
            private let stream: Channel.ClientStream
            private let output: MessageModel
            private let file: FileModel

            init(_ stream: Channel.ClientStream, _ output: MessageModel, _ file: FileModel) {
                self.stream = stream
                self.output = output
                self.file = file
            }

            /// Next response; EndOfStreamError at end.
            func Recv() throws -> GenericMessage {
                let resp = BoundMessage(output, GenericMessage(output), file)
                try stream.Recv(resp)
                return resp.generic
            }

            /// Abandon this stream (RST CANCELLED unless completed).
            func Cancel() { stream.Cancel() }

            /// Abandon this stream (RST CANCELLED unless completed).
            func Close() { stream.Close() }
        }

        func ServerStream(_ service: String, _ method: String, _ req: GenericMessage, _ metadata: [String: String]? = nil, _ timeout: Double? = nil) throws -> DynamicStream {
            let m = try Method(service, method)
            return DynamicStream(try channel.ServerStream(m.path, BoundMessage(m.input, req, model), metadata, timeout),
                                 m.output, model)
        }

        func ClientStream(_ service: String, _ method: String, _ reqs: [GenericMessage], _ metadata: [String: String]? = nil, _ timeout: Double? = nil) throws -> GenericMessage {
            let m = try Method(service, method)
            let bound = reqs.map { BoundMessage(m.input, $0, model) }
            let resp = BoundMessage(m.output, GenericMessage(m.output), model)
            try channel.ClientStreamCall(m.path, bound, resp, metadata, timeout)
            return resp.generic
        }

        func Bidi(_ service: String, _ method: String, _ reqs: [GenericMessage], _ metadata: [String: String]? = nil, _ timeout: Double? = nil) throws -> DynamicStream {
            let m = try Method(service, method)
            let bound = reqs.map { BoundMessage(m.input, $0, model) }
            return DynamicStream(try channel.Bidi(m.path, bound, metadata, timeout), m.output, model)
        }
    }

    /// Receives generic requests; EndOfStreamError at half-close.
    typealias RecvFn = () throws -> GenericMessage
    /// Sends one generic response.
    typealias SendFn = (GenericMessage) throws -> Void

    /// Implements a service with generic messages.
    protocol DynamicHandler: AnyObject {
        func Unary(_ ctx: Endpoint.CallContext, _ method: MethodModel, _ req: GenericMessage) throws -> GenericMessage
        func ServerStream(_ ctx: Endpoint.CallContext, _ method: MethodModel, _ req: GenericMessage, _ send: SendFn) throws
        func ClientStream(_ ctx: Endpoint.CallContext, _ method: MethodModel, _ recv: RecvFn) throws -> GenericMessage
        func Bidi(_ ctx: Endpoint.CallContext, _ method: MethodModel, _ recv: RecvFn, _ send: SendFn) throws
    }

    /// Register a runtime-built service on a Server.
    static func RegisterDynamicService(_ server: Server, _ fileModel: FileModel, _ serviceName: String, _ handler: DynamicHandler) throws {
        let service = try fileModel.Service(serviceName)
        var methods: [Server.Method] = []
        for m in service.methods.values {
            methods.append(Server.Method(name: m.name, path: m.path, kind: m.kind) { ctx, reqs, sink in
                let recv: RecvFn = {
                    try DecodeGeneric(m.input, try reqs.RecvRaw(), fileModel)
                }
                let send: SendFn = { resp in
                    try sink(EncodeGeneric(m.output, resp, fileModel))
                }
                switch m.kind {
                case Server.KindUnary:
                    try send(handler.Unary(ctx, m, try recv()))
                case Server.KindServerStreaming:
                    try handler.ServerStream(ctx, m, try recv(), send)
                case Server.KindClientStreaming:
                    try send(handler.ClientStream(ctx, m, recv))
                default:
                    try handler.Bidi(ctx, m, recv, send)
                }
            })
        }
        server.RegisterService(Server.ServiceDesc(name: service.fullName, methods: methods))
    }
}
GRPC_RUNTIME_EOF
)

(define swift-dispatch-arms
  '((HEADERS    . "OnHeaders(streamId, payload)")
    (DATA       . "PushEvent(streamId, StreamEvent(kind: .data, payload: payload))")
    (HALF-CLOSE . "PushEvent(streamId, StreamEvent(kind: .halfClose))")
    (TRAILERS   . "OnTerminal(streamId, payload, .trailers)")
    (RST        . "OnTerminal(streamId, payload, .rst)")))

(define (screaming-name sym)
  (string-replace (symbol->string sym) "-" "_"))

(define (pascal-swift sym) ; HALF-CLOSE -> HalfClose
  (apply string-append
         (for/list ([part (in-list (string-split (symbol->string sym) "-"))])
           (string-append (string (char-upcase (string-ref part 0)))
                          (string-downcase (substring part 1))))))

(define (emit-swift-dispatch)
  (string-append
   "        switch frameType {\n"
   (apply string-append
          (for/list ([e (in-list frame-table)])
            (define arm (assoc (first e) swift-dispatch-arms))
            (unless arm (error 'runtime-swift "no Swift dispatch arm for ~a" (first e)))
            (format "        case Wire.Frame~a: ~a\n"
                    (pascal-swift (first e)) (cdr arm))))
   "        default: break  // Unknown frame type: ignore for forward compatibility.\n        }"))

(define (emit-swift-runtime-files)
  ;; Publicized for the SwiftPM library product (desc.rkt);
  ;; in-module test/example builds are unaffected.
  (map (lambda (p) (cons (car p) (publicize-swift (cdr p))))
       (list
        (cons "grpcdc/Status.swift" swift-status-body)
        (cons "grpcdc/Codec.swift" swift-codec-body)
        (cons "grpcdc/Transport.swift" swift-transport-body)
        (cons "grpcdc/Endpoint.swift"
              (string-replace swift-endpoint-body "@@FRAME_DISPATCH@@" (emit-swift-dispatch)))
        (cons "grpcdc/Channel.swift" swift-channel-body)
        (cons "grpcdc/Server.swift" swift-server-body)
        (cons "grpcdc/MemoryTransport.swift" swift-loopback-body)
        (cons "grpcdc/SidecarTransport.swift" swift-sidecar-body)
        (cons "grpcdc/Dynamic.swift" swift-dynamic-body))))
