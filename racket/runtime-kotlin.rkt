#lang racket

;;; runtime-kotlin.rkt — the Kotlin gRPC runtime, emitted by
;;; metagen.rkt.
;;;
;;; The runtime files under kotlin/grpcdc/ are GENERATED from the
;;; bodies below plus fragments recursively expanded from spec.rkt's
;;; frame/status tables (see the dispatch generator). Do not edit the
;;; generated runtime files; edit here and run `make generate`.
;;; (Bodies were authored in-language and are kept verbatim so the
;;; generated output stays byte-reviewable in git diffs.)
;;;
;;; Kotlin/JVM, JDK + Kotlin stdlib only — no kotlinx, no external
;;; packages. Coroutine support uses stdlib kotlin.coroutines
;;; intrinsics via AsyncPump.

(require "spec.rkt")
(provide emit-kotlin-runtime-files emit-kotlin-wasm-runtime-files)

(define kotlin-status-body
#<<GRPC_RUNTIME_EOF
package grpcdc

/** A gRPC status (code + message) carried as an exception. */
class StatusException(val code: Int, message: String) : Exception(message) {
    /** Trailing metadata carried by a status frame (never null). */
    var trailers: Map<String, String> = emptyMap()

    override fun toString(): String = "${Wire.statusName(code)}: $message"

    companion object {
        /** Convert any exception to a StatusException (OK for null). */
        fun toStatus(err: Throwable?): StatusException {
            if (err == null) {
                return StatusException(Wire.CODE_OK, "")
            }
            if (err is StatusException) {
                return err
            }
            return StatusException(Wire.CODE_INTERNAL, err.message ?: err.toString())
        }
    }
}

/**
 * Homegrown tracing: W3C traceparent propagation with a span
 * observer. Dormant until [Tracing.setTracer] registers one;
 * generated code stays dependency-free (sampling and export are
 * the application's problem).
 */
object Tracing {
    /** Span observer callbacks (kind is "client" or "server"). */
    interface Tracer {
        fun onStart(kind: String, method: String, traceId: String, spanId: String, parentSpanId: String)
        fun onEnd(kind: String, method: String, traceId: String, spanId: String, status: String)
    }

    /** One in-flight span's context. */
    data class TraceContext(val traceId: String, val spanId: String, val parentSpanId: String)

    /** Parsed traceparent parent. */
    data class Parent(val traceId: String, val spanId: String)

    private var tracer: Tracer? = null
    private val rng = kotlin.random.Random.Default

    fun setTracer(t: Tracer?) {
        tracer = t
    }

    private var traceFilter: List<String> = emptyList()

    // Restrict traced methods: ';'-separated paths, a trailing
    // '*' means prefix match ('/echo.Echo/*'). Empty = trace all.
    fun setTraceFilter(patterns: String) {
        traceFilter = patterns.split(";").filter { it.isNotEmpty() }
    }

    fun traceAllowed(method: String): Boolean {
        if (traceFilter.isEmpty()) return true
        return traceFilter.any { p ->
            if (p.endsWith("*")) method.startsWith(p.dropLast(1)) else method == p
        }
    }

    fun enabled(): Boolean = tracer != null

    fun formatTraceparent(traceId: String, spanId: String): String =
        "00-$traceId-$spanId-01"

    fun parseTraceparent(value: String?): Parent? {
        if (value == null) return null
        val parts = value.split("-")
        if (parts.size != 4 || parts[1].length != 32 || parts[2].length != 16) return null
        if (!parts[1].all { it in '0'..'9' || it in 'a'..'f' }) return null
        if (!parts[2].all { it in '0'..'9' || it in 'a'..'f' }) return null
        return Parent(parts[1], parts[2])
    }

    private fun randomHex(bytes: Int): String {
        val buf = ByteArray(bytes)
        rng.nextBytes(buf)
        val out = StringBuilder(bytes * 2)
        for (b in buf) {
            out.append(((b.toInt() shr 4) and 0xf).toString(16))
            out.append((b.toInt() and 0xf).toString(16))
        }
        return out.toString()
    }

    fun traceStart(kind: String, method: String, parent: Parent?): TraceContext? {
        val t = tracer ?: return null
        if (!traceAllowed(method)) return null
        val ctx = TraceContext(
            parent?.traceId ?: randomHex(16),
            randomHex(8),
            parent?.spanId ?: ""
        )
        try {
            t.onStart(kind, method, ctx.traceId, ctx.spanId, ctx.parentSpanId)
        } catch (ignored: Throwable) {
        }
        return ctx
    }

    fun traceEnd(kind: String, method: String, ctx: TraceContext?, status: String) {
        val t = tracer
        if (ctx == null || t == null) return
        try {
            t.onEnd(kind, method, ctx.traceId, ctx.spanId, status)
        } catch (ignored: Throwable) {
        }
    }
}
GRPC_RUNTIME_EOF
)

(define kotlin-codec-body
#<<GRPC_RUNTIME_EOF
package grpcdc

import java.nio.charset.StandardCharsets

/**
 * Frame codec for gRPC over WebRTC DataChannels (wire protocol in
 * ../SPEC.md). Frame, status, channel and server semantics mirror the
 * other grpcdc runtimes; the tables in Wire.kt are stamped by the
 * grpc-dc codegen.
 */
object Codec {
    const val HEADER_LEN = 9
    const val MAX_DATA_PAYLOAD = 16 * 1024 * 1024

    /** One parsed frame. */
    class Frame(val type: Int, val streamId: Long, val payload: ByteArray)

    /** Build one DataChannel message: header + payload. */
    fun encodeFrame(frameType: Int, streamId: Long, payload: ByteArray): ByteArray {
        if (!Wire.isFrameType(frameType)) {
            throw StatusException(Wire.CODE_INVALID_ARGUMENT, "unknown frame type $frameType")
        }
        if (frameType == Wire.FRAME_DATA && payload.size > MAX_DATA_PAYLOAD) {
            throw StatusException(Wire.CODE_RESOURCE_EXHAUSTED, "DATA payload exceeds 16 MiB")
        }
        val out = ByteArray(HEADER_LEN + payload.size)
        out[0] = frameType.toByte()
        putU32(out, 1, streamId)
        putU32(out, 5, payload.size.toLong())
        System.arraycopy(payload, 0, out, HEADER_LEN, payload.size)
        return out
    }

    /** Parse one DataChannel message. */
    fun decodeFrame(data: ByteArray): Frame {
        if (data.size < HEADER_LEN) {
            throw StatusException(
                Wire.CODE_INVALID_ARGUMENT,
                "frame shorter than 9-byte header: ${data.size} bytes"
            )
        }
        val length = getU32(data, 5)
        if (length != (data.size - HEADER_LEN).toLong()) {
            throw StatusException(
                Wire.CODE_INVALID_ARGUMENT,
                "payload length $length does not match message size ${data.size}"
            )
        }
        val payload = ByteArray(data.size - HEADER_LEN)
        System.arraycopy(data, HEADER_LEN, payload, 0, payload.size)
        return Frame(data[0].toInt() and 0xff, getU32(data, 1), payload)
    }

    fun putU32(out: ByteArray, off: Int, value: Long) {
        out[off] = (value ushr 24).toByte()
        out[off + 1] = (value ushr 16).toByte()
        out[off + 2] = (value ushr 8).toByte()
        out[off + 3] = value.toByte()
    }

    fun getU32(inp: ByteArray, off: Int): Long {
        return ((inp[off].toLong() and 0xffL) shl 24) or ((inp[off + 1].toLong() and 0xffL) shl 16) or
            ((inp[off + 2].toLong() and 0xffL) shl 8) or (inp[off + 3].toLong() and 0xffL)
    }

    /** Parsed HEADERS payload: path == null means response headers. */
    class Headers(val path: String?, val metadata: Map<String, String>)

    fun headersFrame(streamId: Long, path: String?, metadata: Map<String, String>?): ByteArray {
        val sb = StringBuilder("{")
        var first = true
        if (path != null) {
            sb.append("\"path\":").append(jsonString(path))
            first = false
        }
        if (metadata != null && metadata.isNotEmpty()) {
            if (!first) sb.append(',')
            sb.append("\"metadata\":{")
            var mFirst = true
            for ((k, v) in metadata) {
                if (!mFirst) sb.append(',')
                sb.append(jsonString(k)).append(':').append(jsonString(v))
                mFirst = false
            }
            sb.append('}')
        }
        sb.append('}')
        return encodeFrame(Wire.FRAME_HEADERS, streamId, sb.toString().toByteArray(StandardCharsets.UTF_8))
    }

    fun parseHeaders(payload: ByteArray): Headers {
        val body = parseJsonObject(String(payload, StandardCharsets.UTF_8))
        val metadata = LinkedHashMap<String, String>()
        val md = body["metadata"]
        if (md is Map<*, *>) {
            for ((k, v) in md) {
                metadata[k.toString()] = v.toString()
            }
        }
        val path = body["path"]
        return Headers(path?.toString(), metadata)
    }

    // gRPC timeout grammar (grpc-timeout metadata): <digits><unit>,
    // units H/M/S/m/u/n (at most 8 digits). Encoding uses
    // milliseconds (seconds past the digit limit), rounded up.
    fun encodeTimeout(timeout: java.time.Duration): String {
        var ms = timeout.toMillis()
        if (timeout.minusMillis(ms).toNanos() > 0) ms++
        if (ms <= 99999999L) return "${ms}m"
        var secs = timeout.toSeconds()
        if (timeout.minusSeconds(secs).toNanos() > 0) secs++
        return "${secs}S"
    }

    /** Decoded grpc-timeout, or null when malformed/absent. */
    fun parseTimeout(text: String?): java.time.Duration? {
        if (text == null || text.length < 2 || text.length > 9) return null
        val digits = text.dropLast(1)
        if (!digits.all { it.isDigit() }) return null
        val n = digits.toLong()
        return when (text.last()) {
            'H' -> java.time.Duration.ofHours(n)
            'M' -> java.time.Duration.ofMinutes(n)
            'S' -> java.time.Duration.ofSeconds(n)
            'm' -> java.time.Duration.ofMillis(n)
            'u' -> java.time.Duration.ofNanos(n * 1000L)
            'n' -> java.time.Duration.ofNanos(n)
            else -> null
        }
    }

    fun statusFrame(frameType: Int, streamId: Long, status: StatusException): ByteArray {
        val sb = StringBuilder()
        sb.append("{\"code\":").append(status.code)
            .append(",\"message\":").append(jsonString(status.message ?: ""))
        if (status.trailers.isNotEmpty()) {
            sb.append(",\"metadata\":{")
            var first = true
            for ((k, v) in status.trailers) {
                if (!first) sb.append(',')
                sb.append(jsonString(k)).append(':').append(jsonString(v))
                first = false
            }
            sb.append('}')
        }
        sb.append('}')
        return encodeFrame(frameType, streamId, sb.toString().toByteArray(StandardCharsets.UTF_8))
    }

    fun parseStatus(payload: ByteArray): StatusException {
        return try {
            val body = parseJsonObject(String(payload, StandardCharsets.UTF_8))
            val code = (body["code"] as Number).toInt()
            val message = body["message"]
            val status = StatusException(code, message?.toString() ?: "")
            val metadata = body["metadata"]
            if (metadata is Map<*, *>) {
                val trailers = HashMap<String, String>()
                for ((k, v) in metadata) {
                    trailers[k.toString()] = v.toString()
                }
                status.trailers = trailers
            }
            status
        } catch (e: RuntimeException) {
            StatusException(Wire.CODE_UNKNOWN, "malformed trailers")
        }
    }

    // -- minimal JSON (flat objects, string/number/nested-object values) --

    fun jsonString(value: String): String {
        val sb = StringBuilder("\"")
        for (c in value) {
            when (c) {
                '"' -> sb.append("\\\"")
                '\\' -> sb.append("\\\\")
                '\n' -> sb.append("\\n")
                '\r' -> sb.append("\\r")
                '\t' -> sb.append("\\t")
                else -> {
                    if (c < ' ') {
                        sb.append(String.format("\\u%04x", c.code))
                    } else {
                        sb.append(c)
                    }
                }
            }
        }
        return sb.append('"').toString()
    }

    fun parseJsonObject(text: String): Map<String, Any?> {
        val pos = intArrayOf(0)
        val obj = parseObject(text, pos)
        skipWs(text, pos)
        if (pos[0] != text.length) {
            throw StatusException(Wire.CODE_INVALID_ARGUMENT, "trailing data in JSON")
        }
        return obj
    }

    private fun skipWs(text: String, pos: IntArray) {
        while (pos[0] < text.length && text[pos[0]].isWhitespace()) {
            pos[0]++
        }
    }

    private fun parseObject(text: String, pos: IntArray): Map<String, Any?> {
        skipWs(text, pos)
        expect(text, pos, '{')
        val map = LinkedHashMap<String, Any?>()
        skipWs(text, pos)
        if (pos[0] < text.length && text[pos[0]] == '}') {
            pos[0]++
            return map
        }
        while (true) {
            skipWs(text, pos)
            val key = parseString(text, pos)
            skipWs(text, pos)
            expect(text, pos, ':')
            val value = parseValue(text, pos)
            map[key] = value
            skipWs(text, pos)
            if (pos[0] >= text.length) {
                throw StatusException(Wire.CODE_INVALID_ARGUMENT, "unterminated JSON object")
            }
            when (text[pos[0]++]) {
                '}' -> return map
                ',' -> {}
                else -> throw StatusException(Wire.CODE_INVALID_ARGUMENT, "expected ',' or '}' in JSON")
            }
        }
    }

    private fun parseValue(text: String, pos: IntArray): Any? {
        skipWs(text, pos)
        if (pos[0] >= text.length) {
            throw StatusException(Wire.CODE_INVALID_ARGUMENT, "missing JSON value")
        }
        return when (text[pos[0]]) {
            '"' -> parseString(text, pos)
            '{' -> parseObject(text, pos)
            't' -> {
                expectLiteral(text, pos, "true")
                true
            }
            'f' -> {
                expectLiteral(text, pos, "false")
                false
            }
            'n' -> {
                expectLiteral(text, pos, "null")
                null
            }
            else -> {
                val start = pos[0]
                while (pos[0] < text.length && "-+0123456789.eE".indexOf(text[pos[0]]) >= 0) {
                    pos[0]++
                }
                if (start == pos[0]) {
                    throw StatusException(Wire.CODE_INVALID_ARGUMENT, "bad JSON value")
                }
                text.substring(start, pos[0]).toDouble()
            }
        }
    }

    private fun parseString(text: String, pos: IntArray): String {
        expect(text, pos, '"')
        val sb = StringBuilder()
        while (pos[0] < text.length) {
            val c = text[pos[0]++]
            if (c == '"') {
                return sb.toString()
            }
            if (c == '\\' && pos[0] < text.length) {
                when (val esc = text[pos[0]++]) {
                    'n' -> sb.append('\n')
                    'r' -> sb.append('\r')
                    't' -> sb.append('\t')
                    'b' -> sb.append('\b')
                    'f' -> sb.append('\u000C')
                    'u' -> {
                        sb.append(text.substring(pos[0], pos[0] + 4).toInt(16).toChar())
                        pos[0] += 4
                    }
                    else -> sb.append(esc)
                }
            } else {
                sb.append(c)
            }
        }
        throw StatusException(Wire.CODE_INVALID_ARGUMENT, "unterminated JSON string")
    }

    private fun expect(text: String, pos: IntArray, wanted: Char) {
        if (pos[0] >= text.length || text[pos[0]] != wanted) {
            throw StatusException(Wire.CODE_INVALID_ARGUMENT, "expected '$wanted' in JSON")
        }
        pos[0]++
    }

    private fun expectLiteral(text: String, pos: IntArray, literal: String) {
        if (!text.startsWith(literal, pos[0])) {
            throw StatusException(Wire.CODE_INVALID_ARGUMENT, "bad JSON literal")
        }
        pos[0] += literal.length
    }
}
GRPC_RUNTIME_EOF
)

(define kotlin-transport-body
#<<GRPC_RUNTIME_EOF
package grpcdc

/**
 * Carries whole DataChannel messages: one send/recv is one message,
 * boundaries preserved, ordered and reliable — the contract an
 * RTCDataChannel (or the loopback pair) offers.
 */
/** End-of-stream thrown by Transport.recv (EOFException on the JVM). */
typealias EndOfStream = java.io.EOFException

/** Result of a Transport.tryRecv call. */
sealed class TryRecvResult {
    class Message(val data: ByteArray) : TryRecvResult()
    object WouldBlock : TryRecvResult()
    object Closed : TryRecvResult()
}

interface Transport {
    fun send(data: ByteArray)

    /** Next message; EOFException when the transport is closed. */
    fun recv(): ByteArray

    fun close() {}

    /**
     * Optional bounded receive for single-threaded environments
     * (Kotlin/Wasm). When a transport reports hasTryRecv, the
     * endpoint runs in inline pump mode — no read or dispatch
     * threads; stream waits pump the transport instead of
     * blocking on a queue.
     */
    val hasTryRecv: Boolean
        get() = false

    fun tryRecv(): TryRecvResult = TryRecvResult.WouldBlock
}

/** Implemented by hand-written protobuf message types. */
interface Marshaler {
    fun marshalDc(): ByteArray
}

/** Implemented by hand-written protobuf message types. */
interface Unmarshaler {
    fun unmarshalDc(data: ByteArray)
}
GRPC_RUNTIME_EOF
)

(define kotlin-endpoint-body
#<<GRPC_RUNTIME_EOF
package grpcdc

import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.LinkedBlockingQueue

/** Multiplexes grpc-dc streams over one Transport. */
class Endpoint(private val transport: Transport, creator: Boolean) {
    /** Stream event kinds delivered to StreamInput queues. */
    enum class EventKind { HEADERS, DATA, HALF_CLOSE, TRAILERS, RST }

    class StreamEvent(
        val kind: EventKind,
        val headers: Codec.Headers?,
        val payload: ByteArray?,
        val status: StatusException?
    )

    /** Receiving queue of one stream; closed after a terminal event. */
    class StreamInput {
        private val events = LinkedBlockingQueue<Any>()

        /** Inline mode: get drives the endpoint pump instead of blocking. */
        @Volatile
        var pump: Endpoint? = null

        internal fun setPump(endpoint: Endpoint?) {
            pump = endpoint
        }

        internal fun put(event: StreamEvent) {
            events.offer(event)
        }

        internal fun close() {
            events.offer(CLOSED)
        }

        private fun convert(event: Any): StreamEvent? =
            if (event === CLOSED) null else event as StreamEvent

        /** Next event, or null once the stream is closed. */
        fun get(): StreamEvent? {
            val pump = pump
            if (pump != null) {
                while (true) {
                    val event = events.poll(10, java.util.concurrent.TimeUnit.MILLISECONDS)
                    if (event != null) return convert(event)
                    pump.pollOnce()
                }
            }
            return convert(events.take())
        }

        /**
         * Next event within nanos, or null once closed.
         * Throws TimeoutException on expiry.
         */
        fun get(nanos: Long): StreamEvent? {
            val pump = pump
            if (pump != null) {
                val deadline = System.nanoTime() + nanos
                while (true) {
                    val remaining = deadline - System.nanoTime()
                    if (remaining <= 0) throw java.util.concurrent.TimeoutException()
                    val event = events.poll(
                        minOf(remaining, 10_000_000L),
                        java.util.concurrent.TimeUnit.NANOSECONDS)
                    if (event != null) return convert(event)
                    pump.pollOnce()
                }
            }
            val event = events.poll(nanos, java.util.concurrent.TimeUnit.NANOSECONDS)
                ?: throw java.util.concurrent.TimeoutException()
            return convert(event)
        }

        companion object {
            private val CLOSED = Any()
        }
    }

    /** Per-call context: metadata sent in HEADERS. */
    class CallContext(val metadata: Map<String, String>) {
        /** Response initial metadata recorded via setHeaders. */
        val responseHeaders = HashMap<String, String>()
        /** Response trailing metadata recorded via setTrailers. */
        val responseTrailers = HashMap<String, String>()

        /** Record response initial metadata (sent lazily, before the first response message). */
        fun setHeaders(md: Map<String, String>) {
            responseHeaders.putAll(md)
        }

        /** Record response trailing metadata (rides the terminal status frame). */
        fun setTrailers(md: Map<String, String>) {
            responseTrailers.putAll(md)
        }

        /** Monotonic deadline (System.nanoTime), or -1 when unbounded. */
        val deadlineNanos: Long = Codec.parseTimeout(metadata["grpc-timeout"])
            ?.let { System.nanoTime() + it.toNanos() } ?: -1L

        /** Time left before the deadline, or null when unbounded. */
        fun timeRemaining(): java.time.Duration? =
            if (deadlineNanos < 0) null
            else java.time.Duration.ofNanos(maxOf(0L, deadlineNanos - System.nanoTime()))

        fun deadlineExceeded(): Boolean =
            deadlineNanos >= 0 && System.nanoTime() - deadlineNanos >= 0
    }

    /** Server-side call handler installed by Server.
     * Returned status becomes the call's TRAILERS (null means OK). */
    fun interface Dispatcher {
        fun dispatch(ctx: CallContext, headers: Codec.Headers, input: StreamInput, sink: ResponseSink): StatusException?
    }

    /** Sends response payloads of one inbound call. */
    class ResponseSink(private val endpoint: Endpoint, private val streamId: Long) {
        // Wired to the CallContext maps by the endpoint.
        var respHeaders: Map<String, String> = emptyMap()
        var respTrailers: Map<String, String> = emptyMap()
        var headersSent = false

        fun send(payload: ByteArray) {
            flushHeaders()
            endpoint.sendFrame(Codec.encodeFrame(Wire.FRAME_DATA, streamId, payload))
        }

        internal fun flushHeaders() {
            if (!headersSent) {
                headersSent = true
                sendHeaders(respHeaders)
            }
        }

        internal fun sendHeaders() {
            sendHeaders(respHeaders)
        }

        internal fun sendHeaders(metadata: Map<String, String>) {
            headersSent = true
            endpoint.sendFrame(Codec.headersFrame(streamId, null, metadata))
        }

        internal fun sendTrailers(status: StatusException) {
            var out = status
            if (respTrailers.isNotEmpty()) {
                val merged = HashMap(respTrailers)
                merged.putAll(status.trailers)
                out = StatusException(status.code, status.message ?: "")
                out.trailers = merged
            }
            endpoint.sendFrame(Codec.statusFrame(Wire.FRAME_TRAILERS, streamId, out))
        }
    }

    private var dispatcher: Dispatcher? = null
    private var nextId: Long = if (creator) 1 else 2
    private val sendLock = Any()
    private val streams = ConcurrentHashMap<Long, StreamInput>()

    @Volatile
    private var closed = false
    private var started = false

    @Volatile
    private var inlinePump = false

    /**
     * The side that created the channel allocates odd stream ids, the
     * answerer even. The read loop starts on start() — after any
     * dispatcher is installed, so an early HEADERS can never race
     * dispatcher setup. A tryRecv transport runs inline instead:
     * no thread is spawned and stream waits pump the transport
     * (single-threaded Kotlin/Wasm).
     */
    @Synchronized
    fun start() {
        if (started) {
            return
        }
        started = true
        inlinePump = transport.hasTryRecv
        if (inlinePump) {
            return
        }
        val thread = Thread({ readLoop() }, "grpcdc-endpoint")
        thread.isDaemon = true
        thread.start()
    }

    /** Whether this endpoint runs in inline pump mode. */
    fun isInlinePump(): Boolean = inlinePump

    /**
     * Inline mode: receive and dispatch at most one message.
     * Stream waits call this through StreamInput's pump hook;
     * a server-only program drives its endpoint by calling it
     * in a loop.
     */
    fun pollOnce() {
        if (closed) return
        when (val result = transport.tryRecv()) {
            is TryRecvResult.Message -> if (!closed) onBytes(result.data)
            is TryRecvResult.Closed -> failAll()
            is TryRecvResult.WouldBlock -> {}
        }
    }

    private fun attachPump(input: StreamInput) {
        if (inlinePump || transport.hasTryRecv) {
            input.setPump(this)
        }
    }

    fun setDispatcher(dispatcher: Dispatcher) {
        this.dispatcher = dispatcher
    }

    fun sendFrame(frame: ByteArray) {
        synchronized(sendLock) {
            transport.send(frame)
        }
    }

    data class OpenedStream(val id: Long, val input: StreamInput)

    fun openStream(): OpenedStream {
        val id: Long
        synchronized(sendLock) {
            id = nextId
            nextId += 2
        }
        val input = StreamInput()
        attachPump(input)
        streams[id] = input
        return OpenedStream(id, input)
    }

    fun closeStream(id: Long) {
        streams.remove(id)
    }

    /** Abort one stream: RST out; a pending recv wakes with CANCELLED. */
    fun cancelStream(id: Long) {
        val input = streams.remove(id)
        if (input != null) {
            input.put(StreamEvent(EventKind.RST, null, null,
                StatusException(Wire.CODE_CANCELLED, "call cancelled")))
            input.close()
        }
        try {
            sendFrame(Codec.statusFrame(Wire.FRAME_RST, id,
                StatusException(Wire.CODE_CANCELLED, "call cancelled")))
        } catch (e: Exception) {
            // Transport already gone; the local abort still stands.
        }
    }

    private fun stream(id: Long): StreamInput? = streams[id]

    fun close() {
        if (closed) {
            return
        }
        closed = true
        try {
            transport.close()
        } catch (e: Exception) {
            // best effort
        }
        failAll()
    }

    private fun failAll() {
        for ((_, input) in streams) {
            input.put(StreamEvent(EventKind.RST, null, null,
                StatusException(Wire.CODE_UNAVAILABLE, "data channel closed")))
            input.close()
        }
        streams.clear()
    }

    private fun readLoop() {
        while (true) {
            val data: ByteArray
            try {
                data = transport.recv()
            } catch (e: Exception) {
                failAll()
                return
            }
            if (closed) {
                return
            }
            onBytes(data)
        }
    }

    private fun onBytes(data: ByteArray) {
        val frame: Codec.Frame
        try {
            frame = Codec.decodeFrame(data)
        } catch (e: StatusException) {
            return // malformed frame: drop, keep the channel up
        }
        val frameType = frame.type
        val streamId = frame.streamId
        val payload = frame.payload
@@FRAME_DISPATCH@@
    }

    private fun onTerminal(streamId: Long, payload: ByteArray, kind: EventKind) {
        val input = stream(streamId)
        if (input != null) {
            input.put(StreamEvent(kind, null, null, Codec.parseStatus(payload)))
            input.close()
            closeStream(streamId)
        }
    }

    private fun pushEvent(streamId: Long, event: StreamEvent) {
        stream(streamId)?.put(event)
    }

    private fun onHeaders(streamId: Long, payload: ByteArray) {
        val headers: Codec.Headers
        try {
            headers = Codec.parseHeaders(payload)
        } catch (e: StatusException) {
            try {
                sendFrame(Codec.statusFrame(Wire.FRAME_RST, streamId, StatusException.toStatus(e)))
            } catch (ignored: Exception) {
                // best effort
            }
            return
        }
        if (headers.path == null) {
            // Server response headers for one of our outbound streams.
            stream(streamId)?.put(StreamEvent(EventKind.HEADERS, headers, null, null))
            return
        }
        if (stream(streamId) != null) {
            try {
                sendFrame(Codec.statusFrame(Wire.FRAME_RST, streamId,
                    StatusException(Wire.CODE_INTERNAL, "HEADERS for stream already in use")))
            } catch (ignored: Exception) {
                // best effort
            }
            return
        }
        val currentDispatcher = dispatcher
        if (currentDispatcher == null) {
            try {
                sendFrame(Codec.statusFrame(Wire.FRAME_TRAILERS, streamId,
                    StatusException(Wire.CODE_UNIMPLEMENTED, "unknown method " + headers.path)))
            } catch (ignored: Exception) {
                // best effort
            }
            return
        }
        val input = StreamInput()
        attachPump(input)
        streams[streamId] = input
        if (inlinePump) {
            // Single-threaded mode: run the handler on this pump
            // stack; its stream waits re-enter pollOnce.
            dispatchCall(streamId, input, headers, currentDispatcher)
            return
        }
        val thread = Thread({
            dispatchCall(streamId, input, headers, currentDispatcher)
        }, "grpcdc-call")
        thread.isDaemon = true
        thread.start()
    }

    private fun dispatchCall(streamId: Long, input: StreamInput,
                             headers: Codec.Headers, dispatcher: Dispatcher) {
        val sink = ResponseSink(this, streamId)
        try {
            // No eager HEADERS: initial metadata flushes lazily via
            // the sink (first DATA, or below on a DATA-less success)
            // so handlers can setHeaders first. Errors end
            // trailers-only, as gRPC allows.
            val ctx = CallContext(headers.metadata)
            sink.respHeaders = ctx.responseHeaders
            sink.respTrailers = ctx.responseTrailers
            var status = dispatcher.dispatch(ctx, headers, input, sink)
            if (status == null) {
                status = StatusException(Wire.CODE_OK, "")
                try {
                    sink.flushHeaders()
                } catch (ignored: Exception) {
                    // best effort
                }
            }
            try {
                sink.sendTrailers(status)
            } catch (ignored: Exception) {
                // best effort
            }
        } finally {
            closeStream(streamId)
        }
    }
}
GRPC_RUNTIME_EOF
)

(define kotlin-channel-body
#<<GRPC_RUNTIME_EOF
package grpcdc

import java.io.EOFException

/** Channel: the client side of one Endpoint. */
class Channel {
    val endpoint: Endpoint

    /** Wrap a transport, allocating odd stream ids. */
    constructor(transport: Transport) {
        endpoint = Endpoint(transport, true)
        endpoint.start()
    }

    /** Wrap an existing endpoint (bidirectional use; starts its read loop). */
    constructor(endpoint: Endpoint) {
        this.endpoint = endpoint
        endpoint.start()
    }

    /** Receives response messages of one call. */
    class ClientStream internal constructor(
        val streamId: Long,
        private val endpoint: Endpoint,
        private val input: Endpoint.StreamInput
    ) {
        internal var deadlineNanos: Long = -1L
        internal var traceCtx: Tracing.TraceContext? = null
        internal var tracePath: String? = null
        private var traceEnded: Boolean = false

        internal fun endTrace(status: String) {
            if (!traceEnded) {
                traceEnded = true
                Tracing.traceEnd("client", tracePath ?: "", traceCtx, status)
            }
        }

        /** Abort this stream (sends RST, wakes a pending recv). */
        fun cancel() = endpoint.cancelStream(streamId)

        private fun nextEvent(): Endpoint.StreamEvent {
            if (deadlineNanos < 0) {
                return input.get()
                    ?: throw StatusException(Wire.CODE_UNAVAILABLE, "data channel closed")
            }
            try {
                val remaining = deadlineNanos - System.nanoTime()
                if (remaining <= 0) throw java.util.concurrent.TimeoutException()
                return input.get(remaining)
                    ?: throw StatusException(Wire.CODE_UNAVAILABLE, "data channel closed")
            } catch (e: java.util.concurrent.TimeoutException) {
                endpoint.cancelStream(streamId)
                throw StatusException(Wire.CODE_DEADLINE_EXCEEDED, "deadline exceeded")
            }
        }
        var headers: Codec.Headers? = null
            private set

        /** Trailing metadata of the terminal status (null until it arrives). */
        var trailers: Map<String, String>? = null
            private set

        /**
         * Decode the next response into resp. EOFException means the
         * call completed OK; StatusException reports the trailers.
         */
        fun recv(resp: Unmarshaler) {
            while (true) {
                val event = nextEvent()
                when (event.kind) {
                    Endpoint.EventKind.HEADERS -> headers = event.headers
                    Endpoint.EventKind.DATA -> {
                        resp.unmarshalDc(event.payload!!)
                        return
                    }
                    Endpoint.EventKind.TRAILERS -> {
                        val status = event.status
                        trailers = status?.trailers
                        endTrace(Wire.statusName(status?.code ?: Wire.CODE_OK))
                        if (status != null && status.code != Wire.CODE_OK) {
                            throw status
                        }
                        throw EOFException("call completed")
                    }
                    Endpoint.EventKind.RST -> {
                        val status = event.status
                            ?: StatusException(Wire.CODE_UNAVAILABLE, "stream reset")
                        trailers = status.trailers
                        endTrace(Wire.statusName(status.code))
                        throw status
                    }
                    else -> {}
                }
            }
        }
    }

    private fun open(path: String, metadata: Map<String, String>?,
                     timeout: java.time.Duration? = null): ClientStream {
        var metadata = metadata
        var deadlineNanos = -1L
        var traceCtx: Tracing.TraceContext? = null
        if (timeout != null || Tracing.enabled()) {
            var merged = metadata ?: emptyMap()
            if (timeout != null) {
                deadlineNanos = System.nanoTime() + timeout.toNanos()
                merged = merged + ("grpc-timeout" to Codec.encodeTimeout(timeout))
            }
            if (Tracing.enabled()) {
                traceCtx = Tracing.traceStart("client", path, Tracing.parseTraceparent(merged["traceparent"]))
                if (traceCtx != null) {
                    merged = merged + ("traceparent" to Tracing.formatTraceparent(traceCtx.traceId, traceCtx.spanId))
                }
            }
            metadata = merged
        }
        val (id, input) = endpoint.openStream()
        try {
            endpoint.sendFrame(Codec.headersFrame(id, path, metadata))
        } catch (e: Exception) {
            endpoint.closeStream(id)
            Tracing.traceEnd("client", path, traceCtx, "UNAVAILABLE")
            throw e
        }
        val stream = ClientStream(id, endpoint, input)
        stream.deadlineNanos = deadlineNanos
        stream.traceCtx = traceCtx
        stream.tracePath = path
        return stream
    }

    private fun sendMessage(stream: ClientStream, msg: Marshaler) {
        endpoint.sendFrame(Codec.encodeFrame(Wire.FRAME_DATA, stream.streamId, msg.marshalDc()))
    }

    private fun halfClose(stream: ClientStream) {
        endpoint.sendFrame(Codec.encodeFrame(Wire.FRAME_HALF_CLOSE, stream.streamId, ByteArray(0)))
    }

    private fun sendAll(stream: ClientStream, reqs: List<Marshaler>) {
        for (req in reqs) {
            sendMessage(stream, req)
        }
        halfClose(stream)
    }

    private fun collectOne(stream: ClientStream, resp: Unmarshaler, what: String) {
        var got = false
        while (true) {
            try {
                stream.recv(resp)
            } catch (e: EOFException) {
                if (!got) {
                    throw StatusException(Wire.CODE_INTERNAL, "call closed with no response")
                }
                return
            }
            if (got) {
                throw StatusException(Wire.CODE_INTERNAL, "$what received more than one response")
            }
            got = true
        }
    }

    /** Run a unary call, decoding the single response into resp. */
    fun unary(path: String, req: Marshaler, resp: Unmarshaler, metadata: Map<String, String>? = null, timeout: java.time.Duration? = null) {
        val stream = open(path, metadata, timeout)
        try {
            sendMessage(stream, req)
            halfClose(stream)
            collectOne(stream, resp, "unary call")
        } finally {
            endpoint.closeStream(stream.streamId)
        }
    }

    /** Start a server-streaming call. */
    fun serverStream(path: String, req: Marshaler, metadata: Map<String, String>? = null, timeout: java.time.Duration? = null): ClientStream {
        val stream = open(path, metadata, timeout)
        sendMessage(stream, req)
        halfClose(stream)
        return stream
    }

    /** Send all requests, then decode the one response into resp. */
    fun clientStreamCall(path: String, reqs: List<Marshaler>, resp: Unmarshaler, metadata: Map<String, String>? = null, timeout: java.time.Duration? = null) {
        val stream = open(path, metadata, timeout)
        try {
            sendAll(stream, reqs)
            collectOne(stream, resp, "client-streaming call")
        } finally {
            endpoint.closeStream(stream.streamId)
        }
    }

    /** Start a bidi call with all requests sent up front. */
    fun bidi(path: String, reqs: List<Marshaler>, metadata: Map<String, String>? = null, timeout: java.time.Duration? = null): ClientStream {
        val stream = open(path, metadata, timeout)
        sendAll(stream, reqs)
        return stream
    }
}
GRPC_RUNTIME_EOF
)

(define kotlin-server-body
#<<GRPC_RUNTIME_EOF
package grpcdc

import java.io.EOFException

/** Server: dispatches inbound calls to registered methods. */
class Server {
    /** Reads request messages of one inbound call. */
    class RequestStream(private val input: Endpoint.StreamInput) {
        /** Next request payload; EOFException at half-close. */
        fun recvRaw(): ByteArray {
            while (true) {
                val event = input.get()
                    ?: throw StatusException(Wire.CODE_UNAVAILABLE, "data channel closed")
                when (event.kind) {
                    Endpoint.EventKind.DATA -> return event.payload!!
                    Endpoint.EventKind.HALF_CLOSE -> throw EOFException("half-close")
                    Endpoint.EventKind.TRAILERS, Endpoint.EventKind.RST -> throw event.status
                        ?: StatusException(Wire.CODE_UNAVAILABLE, "stream closed")
                    else -> {
                        // ignore HEADERS on the request side
                    }
                }
            }
        }

        /** Decode the next request message into req. */
        fun recvInto(req: Unmarshaler) {
            req.unmarshalDc(recvRaw())
        }
    }

    /** Sends response payloads of one inbound call. */
    fun interface ServerSink {
        fun send(payload: ByteArray)
    }

    /** Implements one method against raw payloads; stubs adapt it. */
    fun interface MethodHandler {
        fun handle(ctx: Endpoint.CallContext, reqs: RequestStream, sink: ServerSink)
    }

    /** One entry of a ServiceDesc. */
    data class Method(val name: String, val path: String, val kind: String, val handler: MethodHandler)

    /** Describes a service for registerService. */
    data class ServiceDesc(val name: String, val methods: List<Method>)

    private val methods = HashMap<String, Method>()

    /** Adds a service's methods (generated code calls it). */
    fun registerService(desc: ServiceDesc) {
        for (method in desc.methods) {
            methods[method.path] = method
        }
    }

    /** Attach to a transport (even stream ids); returns the Endpoint. */
    fun serveTransport(transport: Transport): Endpoint {
        val endpoint = Endpoint(transport, false)
        serveEndpoint(endpoint)
        return endpoint
    }

    /** Attach to an existing endpoint (starts its read loop). */
    fun serveEndpoint(endpoint: Endpoint) {
        endpoint.setDispatcher { ctx, headers, input, sink -> dispatch(ctx, headers, input, sink) }
        endpoint.start()
    }

    private fun dispatch(ctx: Endpoint.CallContext, headers: Codec.Headers,
                         input: Endpoint.StreamInput, sink: Endpoint.ResponseSink): StatusException? {
        val method = methods[headers.path]
            ?: return StatusException(Wire.CODE_UNIMPLEMENTED, "unknown method " + headers.path)
        val traceCtx = Tracing.traceStart("server", headers.path ?: "", Tracing.parseTraceparent(headers.metadata["traceparent"]))
        var result: StatusException? = null
        try {
            method.handler.handle(ctx, RequestStream(input), ServerSink { payload -> sink.send(payload) })
        } catch (e: Exception) {
            result = StatusException.toStatus(e)
        }
        Tracing.traceEnd("server", headers.path ?: "", traceCtx, if (result == null) "OK" else Wire.statusName(result.code))
        return result
    }

    companion object {
        const val KIND_UNARY = "unary"
        const val KIND_SERVER_STREAMING = "server-streaming"
        const val KIND_CLIENT_STREAMING = "client-streaming"
        const val KIND_BIDI = "bidi"
    }
}
GRPC_RUNTIME_EOF
)

(define kotlin-loopback-body
#<<GRPC_RUNTIME_EOF
package grpcdc

import java.io.EOFException
import java.util.concurrent.LinkedBlockingQueue

/** In-memory transport pair for tests (one queue per direction). */
object MemoryTransport {
    private val SENTINEL = Any()

    private class Impl(
        private val inbox: LinkedBlockingQueue<Any>,
        private val outbox: LinkedBlockingQueue<Any>
    ) : Transport {
        @Volatile
        private var closed = false

        override fun send(data: ByteArray) {
            if (closed) {
                throw EOFException("transport closed")
            }
            outbox.offer(data.clone())
        }

        override fun recv(): ByteArray {
            val item = inbox.take()
            if (item === SENTINEL) {
                throw EOFException("transport closed")
            }
            return item as ByteArray
        }

        override fun close() {
            closed = true
            inbox.offer(SENTINEL)
        }
    }

    /** Two connected in-memory transports. */
    fun pair(): Pair<Transport, Transport> {
        val aToB = LinkedBlockingQueue<Any>()
        val bToA = LinkedBlockingQueue<Any>()
        return Pair(Impl(bToA, aToB), Impl(aToB, bToA))
    }
}
GRPC_RUNTIME_EOF
)


(define kotlin-sidecar-body
#<<GRPC_RUNTIME_EOF
package grpcdc

import java.io.DataInputStream
import java.io.EOFException
import java.net.Socket

/**
 * Transport over the Rust WebRTC-Direct sidecar: the sidecar
 * owns DTLS/SCTP/TURN and bridges one datachannel to a local
 * TCP socket using u32 big-endian length-prefixed messages
 * (one prefix per DataChannel message). JDK only.
 */
class SidecarTransport(private val socket: Socket) : Transport {
    private val input = DataInputStream(socket.getInputStream())
    private val output = socket.getOutputStream()

    @Volatile
    private var closed = false

    override fun send(data: ByteArray) {
        if (closed) {
            throw EOFException("transport closed")
        }
        val header = byteArrayOf(
            (data.size ushr 24).toByte(),
            (data.size ushr 16).toByte(),
            (data.size ushr 8).toByte(),
            data.size.toByte()
        )
        synchronized(output) {
            output.write(header)
            output.write(data)
            output.flush()
        }
    }

    override fun recv(): ByteArray {
        val length = input.readInt()
        val payload = ByteArray(length)
        input.readFully(payload)
        return payload
    }

    override fun close() {
        closed = true
        try {
            socket.close()
        } catch (ignored: Exception) {
        }
    }

    companion object {
        fun connect(host: String, port: Int): SidecarTransport =
            SidecarTransport(Socket(host, port))
    }
}
GRPC_RUNTIME_EOF
)

(define kotlin-async-body
#<<GRPC_RUNTIME_EOF
package grpcdc

import java.util.concurrent.CompletableFuture
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import kotlin.coroutines.Continuation
import kotlin.coroutines.EmptyCoroutineContext
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlin.coroutines.startCoroutine
import kotlin.coroutines.suspendCoroutine

/**
 * Bridges Kotlin coroutines (stdlib only — no kotlinx dependency)
 * with the blocking runtime: generated stubs expose suspend methods
 * and CompletableFuture methods built on these helpers.
 */
object AsyncPump {
    private val executor = Executors.newCachedThreadPool { r ->
        Thread(r, "grpcdc-async").apply { isDaemon = true }
    }

    /** Run a suspend block on the pool as a CompletableFuture. */
    fun <T> future(block: suspend () -> T): CompletableFuture<T> {
        val result = CompletableFuture<T>()
        executor.execute {
            try {
                result.complete(runSuspend(block))
            } catch (e: Throwable) {
                result.completeExceptionally(e)
            }
        }
        return result
    }

    /** Run a suspend block to completion on the current thread. */
    fun <T> runSuspend(block: suspend () -> T): T {
        val latch = CountDownLatch(1)
        var outcome: Result<T>? = null
        block.startCoroutine(object : Continuation<T> {
            override val context = EmptyCoroutineContext
            override fun resumeWith(result: Result<T>) {
                outcome = result
                latch.countDown()
            }
        })
        latch.await()
        return outcome!!.getOrThrow()
    }

    /** Await a CompletableFuture from a suspend function. Uses the
     * stdlib suspendCoroutine (the cancellable variant lives in
     * kotlinx.coroutines, which this runtime deliberately avoids). */
    suspend fun <T> await(future: CompletableFuture<T>): T {
        return suspendCoroutine { cont ->
            future.whenComplete { value, error ->
                if (error != null) {
                    cont.resumeWithException(error)
                } else {
                    cont.resume(value)
                }
            }
        }
    }
}
GRPC_RUNTIME_EOF
)

(define kotlin-dynamic-body
#<<GRPC_RUNTIME_EOF
package grpcdc

import java.io.ByteArrayOutputStream
import java.io.EOFException
import java.nio.charset.StandardCharsets
import java.util.TreeMap

/**
 * Dynamic, descriptor-driven client and server.
 *
 * Parses a FileDescriptorSet (as produced by
 * `protoc --descriptor_set_out`) at runtime and builds clients and
 * servers whose messages are generic field maps — no generated stubs
 * required. This is the runtime-generation counterpart of the
 * protoc-plugin surfaces: schemas arrive as data (descriptor.proto),
 * not as code.
 *
 * Generic values by field type: varint family -> Long/Boolean,
 * string -> String, bytes/message -> ByteArray / GenericMessage,
 * fixed/float -> Long / Double. Repeated fields are lists in
 * field-number order.
 */
object Dynamic {
    // FieldDescriptorProto.Type values (descriptor.proto).
    const val TYPE_DOUBLE = 1
    const val TYPE_FLOAT = 2
    const val TYPE_INT64 = 3
    const val TYPE_UINT64 = 4
    const val TYPE_INT32 = 5
    const val TYPE_FIXED64 = 6
    const val TYPE_FIXED32 = 7
    const val TYPE_BOOL = 8
    const val TYPE_STRING = 9
    const val TYPE_GROUP = 10
    const val TYPE_MESSAGE = 11
    const val TYPE_BYTES = 12
    const val TYPE_UINT32 = 13
    const val TYPE_ENUM = 14
    const val TYPE_SFIXED32 = 15
    const val TYPE_SFIXED64 = 16
    const val TYPE_SINT32 = 17
    const val TYPE_SINT64 = 18

    private const val LABEL_REPEATED = 3

    class FieldModel(
        var number: Int = 0,
        var name: String = "",
        var type: Int = 0,
        var repeated: Boolean = false,
        var typeName: String = "" // for TYPE_MESSAGE, e.g. ".echo.EchoRequest"
    )

    class MessageModel(
        val fullName: String,
        val fields: MutableMap<Int, FieldModel> = TreeMap(),
        val byName: MutableMap<String, Int> = HashMap()
    )

    class MethodModel(
        var name: String = "",
        var path: String = "",
        var kind: String = "",
        var input: MessageModel? = null,
        var output: MessageModel? = null
    )

    class ServiceModel(
        val fullName: String,
        val methods: MutableMap<String, MethodModel> = HashMap()
    )

    /**
     * Parsed descriptor set: messages and services by full name.
     * Message keys carry the leading dot (".echo.EchoRequest"),
     * matching FieldDescriptorProto.type_name; service keys do not
     * ("echo.Echo").
     */
    class FileModel {
        val messages: MutableMap<String, MessageModel> = HashMap()
        val services: MutableMap<String, ServiceModel> = HashMap()

        fun message(fullName: String): MessageModel {
            return messages[fullName]
                ?: throw StatusException(Wire.CODE_INVALID_ARGUMENT, "unknown message $fullName")
        }

        fun service(fullName: String): ServiceModel {
            return services[fullName]
                ?: throw StatusException(Wire.CODE_INVALID_ARGUMENT, "unknown service $fullName")
        }
    }

    /**
     * A message as field number -> list of values (descriptor order).
     *
     * Fields not in the model are retained as raw encoded chunks in
     * `unknown` (protobuf unknown-field retention): a decode -> encode
     * round trip re-emits them after the known fields, so intermediate
     * hops do not strip newer fields.
     */
    class GenericMessage(val model: MessageModel?) {
        val values: MutableMap<Int, MutableList<Any>> = TreeMap()
        val unknown: MutableList<ByteArray> = ArrayList()

        fun set(number: Int, value: Any): GenericMessage {
            values[number] = mutableListOf(value)
            return this
        }

        fun add(number: Int, value: Any): GenericMessage {
            values.getOrPut(number) { ArrayList() }.add(value)
            return this
        }

        fun get(number: Int): Any? {
            val list = values[number]
            return if (list.isNullOrEmpty()) null else list[0]
        }

        fun getString(number: Int): String {
            val v = get(number)
            return if (v is String) v else ""
        }

        fun getInt(number: Int): Long {
            return when (val v = get(number)) {
                is Boolean -> if (v) 1L else 0L
                is Number -> v.toLong()
                else -> 0L
            }
        }

        override fun toString(): String = "GenericMessage$values"
    }

    // ------------------------------------------------------------------
    // Generic protobuf codec
    // ------------------------------------------------------------------

    private class PbField(
        var number: Int = 0,
        var wire: Int = 0,
        var varint: Long = 0,
        var bytes: ByteArray = ByteArray(0),
        var chunk: ByteArray = ByteArray(0)
    )

    private class PbReader(private val buf: ByteArray) {
        private var pos = 0

        fun varint(): Long {
            var result = 0L
            var shift = 0
            while (true) {
                if (pos >= buf.size) {
                    throw StatusException(Wire.CODE_INVALID_ARGUMENT, "truncated varint")
                }
                val b = buf[pos++].toInt() and 0xff
                result = result or ((b and 0x7f).toLong() shl shift)
                if (b and 0x80 == 0) {
                    return result
                }
                shift += 7
                if (shift >= 70) {
                    throw StatusException(Wire.CODE_INVALID_ARGUMENT, "varint too long")
                }
            }
        }

        private fun lenBytes(): ByteArray {
            val n = varint().toInt()
            if (pos + n > buf.size) {
                throw StatusException(Wire.CODE_INVALID_ARGUMENT, "truncated bytes field")
            }
            val out = buf.copyOfRange(pos, pos + n)
            pos += n
            return out
        }

        fun next(): PbField? {
            if (pos >= buf.size) {
                return null
            }
            val start = pos
            val tag = varint()
            val field = PbField()
            field.number = (tag ushr 3).toInt()
            field.wire = (tag and 7).toInt()
            when (field.wire) {
                0 -> field.varint = varint()
                2 -> field.bytes = lenBytes()
                1 -> {
                    if (pos + 8 > buf.size) {
                        throw StatusException(Wire.CODE_INVALID_ARGUMENT, "truncated fixed64")
                    }
                    field.bytes = buf.copyOfRange(pos, pos + 8)
                    pos += 8
                }
                5 -> {
                    if (pos + 4 > buf.size) {
                        throw StatusException(Wire.CODE_INVALID_ARGUMENT, "truncated fixed32")
                    }
                    field.bytes = buf.copyOfRange(pos, pos + 4)
                    pos += 4
                }
                else -> throw StatusException(Wire.CODE_INVALID_ARGUMENT, "unsupported wire type ${field.wire}")
            }
            field.chunk = buf.copyOfRange(start, pos)
            return field
        }
    }

    private fun asString(field: PbField): String = String(field.bytes, StandardCharsets.UTF_8)

    private fun wireType(type: Int): Int {
        return when (type) {
            TYPE_INT64, TYPE_UINT64, TYPE_INT32, TYPE_BOOL, TYPE_UINT32, TYPE_ENUM, TYPE_SINT32, TYPE_SINT64 -> 0
            TYPE_FIXED64, TYPE_SFIXED64, TYPE_DOUBLE -> 1
            TYPE_STRING, TYPE_BYTES, TYPE_MESSAGE, TYPE_GROUP -> 2
            TYPE_FIXED32, TYPE_SFIXED32, TYPE_FLOAT -> 5
            else -> -1
        }
    }

    private fun encodeVarint(out: ByteArrayOutputStream, value: Long) {
        var v = value
        while ((v and -0x80L) != 0L) {
            out.write(((v and 0x7f) or 0x80).toInt())
            v = v ushr 7
        }
        out.write(v.toInt())
    }

    private fun zigzagEncode(v: Long): Long = (v shl 1) xor (v shr 63)

    private fun zigzagDecode(v: Long): Long = (v ushr 1) xor -(v and 1)

    private fun valueAsLong(value: Any): Long {
        return when (value) {
            is Boolean -> if (value) 1L else 0L
            is Number -> value.toLong()
            else -> 0L
        }
    }

    fun encodeGeneric(model: MessageModel, message: GenericMessage, file: FileModel): ByteArray {
        val out = ByteArrayOutputStream()
        for ((number, values) in message.values) {
            val field = model.fields[number]
                ?: throw StatusException(Wire.CODE_INVALID_ARGUMENT, "unknown field $number for ${model.fullName}")
            if (field.repeated) {
                for (value in values) {
                    encodeValue(out, field, value, file)
                }
            } else if (values.isNotEmpty()) {
                encodeValue(out, field, values[0], file)
            }
        }
        for (chunk in message.unknown) {
            out.write(chunk)
        }
        return out.toByteArray()
    }

    private fun encodeValue(out: ByteArrayOutputStream, field: FieldModel, value: Any, file: FileModel) {
        val wire = wireType(field.type)
        if (wire < 0) {
            throw StatusException(Wire.CODE_INVALID_ARGUMENT, "unsupported field type ${field.type}")
        }
        encodeVarint(out, (field.number.toLong() shl 3) or wire.toLong())
        when (wire) {
            0 -> {
                var v: Long
                if (field.type == TYPE_SINT32 || field.type == TYPE_SINT64) {
                    v = zigzagEncode(valueAsLong(value))
                    if (field.type == TYPE_SINT32) {
                        v = v and 0xffffffffL
                    }
                } else if (field.type == TYPE_BOOL) {
                    v = if (valueAsLong(value) != 0L) 1 else 0
                } else {
                    v = valueAsLong(value)
                }
                encodeVarint(out, v)
            }
            1 -> {
                var v: Long
                if (field.type == TYPE_DOUBLE) {
                    val d = if (value is Number) value.toDouble() else 0.0
                    v = d.toRawBits()
                } else {
                    v = valueAsLong(value)
                }
                for (i in 0 until 8) {
                    out.write(((v ushr (8 * i)) and 0xff).toInt())
                }
            }
            5 -> {
                var v: Int
                if (field.type == TYPE_FLOAT) {
                    val f = if (value is Number) value.toFloat() else 0f
                    v = f.toRawBits()
                } else {
                    v = valueAsLong(value).toInt()
                }
                for (i in 0 until 4) {
                    out.write((v ushr (8 * i)) and 0xff)
                }
            }
            else -> {
                val data: ByteArray
                if (field.type == TYPE_STRING && value is String) {
                    data = value.toByteArray(StandardCharsets.UTF_8)
                } else if (field.type == TYPE_MESSAGE && value is GenericMessage) {
                    data = encodeGeneric(file.message(field.typeName), value, file)
                } else if (value is ByteArray) {
                    data = value
                } else if (value is String) {
                    data = value.toByteArray(StandardCharsets.UTF_8)
                } else {
                    throw StatusException(
                        Wire.CODE_INVALID_ARGUMENT,
                        "value does not match field ${field.name} type ${field.type}"
                    )
                }
                encodeVarint(out, data.size.toLong())
                out.write(data)
            }
        }
    }

    fun decodeGeneric(model: MessageModel, data: ByteArray, file: FileModel): GenericMessage {
        val message = GenericMessage(model)
        val reader = PbReader(data)
        while (true) {
            val raw = reader.next() ?: break
            val field = model.fields[raw.number]
            if (field == null) {
                // Unknown field: retain the raw encoded chunk verbatim.
                message.unknown.add(raw.chunk)
                continue
            }
            message.values.getOrPut(raw.number) { ArrayList() }.add(decodeValue(field, raw, file))
        }
        return message
    }

    private fun decodeValue(field: FieldModel, raw: PbField, file: FileModel): Any {
        return when (raw.wire) {
            0 -> {
                when (field.type) {
                    TYPE_BOOL -> raw.varint != 0L
                    TYPE_SINT32, TYPE_SINT64 -> zigzagDecode(raw.varint)
                    TYPE_INT32, TYPE_ENUM -> raw.varint.toInt().toLong()
                    else -> raw.varint
                }
            }
            1 -> {
                var v = 0L
                for (i in 0 until 8) {
                    v = v or ((raw.bytes[i].toLong() and 0xffL) shl (8 * i))
                }
                when (field.type) {
                    TYPE_DOUBLE -> Double.fromBits(v)
                    else -> v
                }
            }
            5 -> {
                var v = 0
                for (i in 0 until 4) {
                    v = v or ((raw.bytes[i].toInt() and 0xff) shl (8 * i))
                }
                when (field.type) {
                    TYPE_FLOAT -> Float.fromBits(v).toDouble()
                    TYPE_SFIXED32 -> v.toLong()
                    else -> v.toLong() and 0xffffffffL
                }
            }
            else -> {
                when (field.type) {
                    TYPE_STRING -> String(raw.bytes, StandardCharsets.UTF_8)
                    TYPE_MESSAGE -> decodeGeneric(file.message(field.typeName), raw.bytes, file)
                    else -> raw.bytes
                }
            }
        }
    }

    // ------------------------------------------------------------------
    // Descriptor set parsing
    // ------------------------------------------------------------------

    /** Parse FileDescriptorSet bytes into a FileModel. */
    fun parseDescriptorSet(data: ByteArray): FileModel {
        val file = FileModel()
        val pendingServices = ArrayList<Pair<String, ByteArray>>()
        val reader = PbReader(data)
        while (true) {
            val f = reader.next() ?: break
            if (f.number != 1) {
                continue
            }
            var pkg = ""
            val messageTypes = ArrayList<ByteArray>()
            val serviceTypes = ArrayList<ByteArray>()
            val fr = PbReader(f.bytes)
            while (true) {
                val ff = fr.next() ?: break
                when (ff.number) {
                    2 -> pkg = asString(ff)
                    4 -> messageTypes.add(ff.bytes)
                    6 -> serviceTypes.add(ff.bytes)
                }
            }
            for (m in messageTypes) {
                parseMessage(pkg, m, file)
            }
            for (s in serviceTypes) {
                pendingServices.add(Pair(pkg, s))
            }
        }
        for ((pkg, serviceBytes) in pendingServices) {
            parseService(pkg, serviceBytes, file)
        }
        return file
    }

    private fun parseMessage(prefix: String, data: ByteArray, file: FileModel) {
        var name = ""
        val rawFields = ArrayList<ByteArray>()
        val nested = ArrayList<ByteArray>()
        val reader = PbReader(data)
        while (true) {
            val f = reader.next() ?: break
            when (f.number) {
                1 -> name = asString(f)
                2 -> rawFields.add(f.bytes)
                3 -> nested.add(f.bytes)
            }
        }
        val fullName = if (prefix.isEmpty()) name else "$prefix.$name"
        val model = MessageModel(fullName)
        for (fieldBytes in rawFields) {
            val field = parseField(fieldBytes)
            model.byName[field.name] = field.number
            model.fields[field.number] = field
        }
        file.messages[".$fullName"] = model
        for (nestedBytes in nested) {
            parseMessage(fullName, nestedBytes, file)
        }
    }

    private fun parseField(data: ByteArray): FieldModel {
        val field = FieldModel()
        val reader = PbReader(data)
        while (true) {
            val f = reader.next() ?: break
            when (f.number) {
                1 -> field.name = asString(f)
                3 -> field.number = f.varint.toInt()
                4 -> field.repeated = f.varint.toInt() == LABEL_REPEATED
                5 -> field.type = f.varint.toInt()
                6 -> field.typeName = asString(f)
            }
        }
        return field
    }

    private fun kindOf(clientStreaming: Boolean, serverStreaming: Boolean): String {
        return when {
            clientStreaming && serverStreaming -> Server.KIND_BIDI
            serverStreaming -> Server.KIND_SERVER_STREAMING
            clientStreaming -> Server.KIND_CLIENT_STREAMING
            else -> Server.KIND_UNARY
        }
    }

    private fun parseService(pkg: String, data: ByteArray, file: FileModel) {
        var name = ""
        val rawMethods = ArrayList<ByteArray>()
        val reader = PbReader(data)
        while (true) {
            val f = reader.next() ?: break
            when (f.number) {
                1 -> name = asString(f)
                2 -> rawMethods.add(f.bytes)
            }
        }
        val fullName = if (pkg.isEmpty()) name else "$pkg.$name"
        val service = ServiceModel(fullName)
        for (methodBytes in rawMethods) {
            var mname = ""
            var inputType = ""
            var outputType = ""
            var clientStreaming = false
            var serverStreaming = false
            val mr = PbReader(methodBytes)
            while (true) {
                val mf = mr.next() ?: break
                when (mf.number) {
                    1 -> mname = asString(mf)
                    2 -> inputType = asString(mf)
                    3 -> outputType = asString(mf)
                    5 -> clientStreaming = mf.varint != 0L
                    6 -> serverStreaming = mf.varint != 0L
                }
            }
            val method = MethodModel()
            method.name = mname
            method.path = "/$fullName/$mname"
            method.kind = kindOf(clientStreaming, serverStreaming)
            method.input = file.message(inputType)
            method.output = file.message(outputType)
            service.methods[mname] = method
        }
        file.services[fullName] = service
    }

    // ------------------------------------------------------------------
    // Client / server surfaces
    // ------------------------------------------------------------------

    /** Adapts a (MessageModel, GenericMessage) pair to the Channel
     * marshal/unmarshal contract. */
    private class BoundMessage(
        private val model: MessageModel,
        var generic: GenericMessage,
        private val file: FileModel
    ) : Marshaler, Unmarshaler {
        override fun marshalDc(): ByteArray = encodeGeneric(model, generic, file)

        override fun unmarshalDc(data: ByteArray) {
            generic = decodeGeneric(model, data, file)
        }
    }

    /** Runtime-built client: methods resolve from the FileModel. */
    class DynamicClient(private val channel: Channel, private val model: FileModel) {
        private fun method(service: String, method: String): MethodModel {
            val svc = model.service(service)
            return svc.methods[method]
                ?: throw StatusException(Wire.CODE_INVALID_ARGUMENT, "unknown method $service/$method")
        }

        fun unary(service: String, method: String, req: GenericMessage, metadata: Map<String, String>? = null, timeout: java.time.Duration? = null): GenericMessage {
            val m = method(service, method)
            val resp = BoundMessage(m.output!!, GenericMessage(m.output), model)
            channel.unary(m.path, BoundMessage(m.input!!, req, model), resp, metadata, timeout)
            return resp.generic
        }

        /** Receiving stream of generic responses. */
        class DynamicStream internal constructor(
            private val stream: Channel.ClientStream,
            private val output: MessageModel,
            private val file: FileModel
        ) {
            /** Next response; EOFException at end. */
            fun recv(): GenericMessage {
                val resp = BoundMessage(output, GenericMessage(output), file)
                stream.recv(resp)
                return resp.generic
            }
        }

        fun serverStream(service: String, method: String, req: GenericMessage, metadata: Map<String, String>? = null, timeout: java.time.Duration? = null): DynamicStream {
            val m = method(service, method)
            return DynamicStream(channel.serverStream(m.path, BoundMessage(m.input!!, req, model), metadata, timeout), m.output!!, model)
        }

        fun clientStream(service: String, method: String, reqs: List<GenericMessage>, metadata: Map<String, String>? = null, timeout: java.time.Duration? = null): GenericMessage {
            val m = method(service, method)
            val bound = reqs.map { BoundMessage(m.input!!, it, model) }
            val resp = BoundMessage(m.output!!, GenericMessage(m.output), model)
            channel.clientStreamCall(m.path, bound, resp, metadata, timeout)
            return resp.generic
        }

        fun bidi(service: String, method: String, reqs: List<GenericMessage>, metadata: Map<String, String>? = null, timeout: java.time.Duration? = null): DynamicStream {
            val m = method(service, method)
            val bound = reqs.map { BoundMessage(m.input!!, it, model) }
            return DynamicStream(channel.bidi(m.path, bound, metadata, timeout), m.output!!, model)
        }
    }

    /** Receives generic requests; EOFException at half-close. */
    fun interface RecvFn {
        fun recv(): GenericMessage
    }

    /** Sends one generic response. */
    fun interface SendFn {
        fun send(resp: GenericMessage)
    }

    /** Implements a service with generic messages. */
    interface DynamicHandler {
        fun unary(ctx: Endpoint.CallContext, method: MethodModel, req: GenericMessage): GenericMessage
        fun serverStream(ctx: Endpoint.CallContext, method: MethodModel, req: GenericMessage, send: SendFn)
        fun clientStream(ctx: Endpoint.CallContext, method: MethodModel, recv: RecvFn): GenericMessage
        fun bidi(ctx: Endpoint.CallContext, method: MethodModel, recv: RecvFn, send: SendFn)
    }

    /** Register a runtime-built service on a Server. */
    fun registerDynamicService(server: Server, fileModel: FileModel, serviceName: String, handler: DynamicHandler) {
        val service = fileModel.service(serviceName)
        val methods = ArrayList<Server.Method>()
        for (m in service.methods.values) {
            methods.add(Server.Method(m.name, m.path, m.kind) { ctx, reqs, sink ->
                val recv = RecvFn { decodeGeneric(m.input!!, reqs.recvRaw(), fileModel) }
                val send = SendFn { resp -> sink.send(encodeGeneric(m.output!!, resp, fileModel)) }
                when (m.kind) {
                    Server.KIND_UNARY -> send.send(handler.unary(ctx, m, recv.recv()))
                    Server.KIND_SERVER_STREAMING -> handler.serverStream(ctx, m, recv.recv(), send)
                    Server.KIND_CLIENT_STREAMING -> send.send(handler.clientStream(ctx, m, recv))
                    else -> handler.bidi(ctx, m, recv, send)
                }
            })
        }
        server.registerService(Server.ServiceDesc(service.fullName, methods))
    }
}
GRPC_RUNTIME_EOF
)

(define kotlin-dispatch-arms
  '((HEADERS    . "onHeaders(streamId, payload)")
    (DATA       . "pushEvent(streamId, StreamEvent(EventKind.DATA, null, payload, null))")
    (HALF-CLOSE . "pushEvent(streamId, StreamEvent(EventKind.HALF_CLOSE, null, null, null))")
    (TRAILERS   . "onTerminal(streamId, payload, EventKind.TRAILERS)")
    (RST        . "onTerminal(streamId, payload, EventKind.RST)")))

(define (screaming-name sym)
  (string-replace (symbol->string sym) "-" "_"))

(define (emit-kotlin-dispatch)
  (string-append
   "        when (frameType) {\n"
   (apply string-append
          (for/list ([e (in-list frame-table)])
            (define arm (assoc (first e) kotlin-dispatch-arms))
            (unless arm (error 'runtime-kotlin "no Kotlin dispatch arm for ~a" (first e)))
            (format "            Wire.FRAME_~a -> ~a\n"
                    (screaming-name (first e)) (cdr arm))))
   "            else -> {\n"
   "                // Unknown frame type: ignore for forward compatibility.\n"
   "            }\n"
   "        }"))

(define (emit-kotlin-runtime-files)
  (list
   (cons "grpcdc/Status.kt" kotlin-status-body)
   (cons "grpcdc/Codec.kt" kotlin-codec-body)
   (cons "grpcdc/Transport.kt" kotlin-transport-body)
   (cons "grpcdc/Endpoint.kt"
         (string-replace kotlin-endpoint-body "@@FRAME_DISPATCH@@" (emit-kotlin-dispatch)))
   (cons "grpcdc/Channel.kt" kotlin-channel-body)
   (cons "grpcdc/Server.kt" kotlin-server-body)
   (cons "grpcdc/MemoryTransport.kt" kotlin-loopback-body)
   (cons "grpcdc/SidecarTransport.kt" kotlin-sidecar-body)
   (cons "grpcdc/AsyncPump.kt" kotlin-async-body)
   (cons "grpcdc/Dynamic.kt" kotlin-dynamic-body)))

;; ---------------------------------------------------------------------------
;; Kotlin/Wasm variant: the same bodies, with JVM-only APIs
;; replaced at generation time (checked replacements — a pattern
;; that no longer matches is a generation error, not silent
;; drift). Timeouts become Long nanoseconds, threads become the
;; inline grpcdcSpawn, queues/maps become single-threaded
;; ArrayDeque/mutableMap, and the clock is performance.now via
;; js(). AsyncPump/Dynamic are JVM-only and not emitted here.
;; ---------------------------------------------------------------------------

(define (kotlin-wasm-xform name body pairs)
  (for/fold ([text body])
            ([pair (in-list pairs)])
    (unless (string-contains? text (car pair))
      (error 'runtime-kotlin "wasm transform for ~a: pattern not found: ~e" name (car pair)))
    (string-replace text (car pair) (cdr pair))))

(define kotlin-wasm-common-pairs
  (list
   (cons "System.nanoTime()" "grpcdcNowNanos()")
   (cons "java.util.concurrent.TimeoutException" "GrpcdcTimeoutException")
   (cons "synchronized(" "grpcdcSynchronized(")))

;; Common pairs are applied where present (not every file
;; uses every one); file-specific pairs stay checked above.
(define (kotlin-wasm-xform/common body)
  (for/fold ([text body])
            ([pair (in-list kotlin-wasm-common-pairs)])
    (if (string-contains? text (car pair))
        (string-replace text (car pair) (cdr pair))
        text)))

(define kotlin-wasm-transport-extra
  "
// ---- Kotlin/Wasm platform pieces (single-threaded) ----

/** End-of-stream thrown by Transport.recv on Wasm. */
class EndOfStream(message: String) : Exception(message)

typealias EOFException = EndOfStream

/** Timeout raised by timed stream waits on Wasm. */
class GrpcdcTimeoutException : Exception(\"timeout\")

private fun grpcdcNowMs(): Double = js(\"performance.now()\")

/** Monotonic clock: performance.now in the worker. */
fun grpcdcNowNanos(): Long = (grpcdcNowMs() * 1000000.0).toLong()

/** Single-threaded stand-in for synchronized blocks. */
inline fun <T> grpcdcSynchronized(lock: Any, block: () -> T): T = block()

/** Thread spawn on Wasm: run inline (dispatch in pump mode). */
fun grpcdcSpawn(block: () -> Unit) {
    block()
}

/** Single-threaded queue behind StreamInput on Wasm. */
class GrpcdcQueue<T> {
    private val items = ArrayDeque<T>()

    fun offer(item: T): Boolean {
        items.addLast(item)
        return true
    }

    fun take(): T = items.removeFirst()

    fun pollNanos(timeoutNanos: Long): T? = items.removeFirstOrNull()
}
")

(define (emit-kotlin-wasm-runtime-files)
  (define x kotlin-wasm-xform)
  (list
   (cons "grpcdc/Status.kt" kotlin-status-body)
   (cons "grpcdc/Codec.kt"
         (x "Codec" (kotlin-wasm-xform/common kotlin-codec-body)
            (list
                     (cons "import java.nio.charset.StandardCharsets\n" "")
                     (cons "System.arraycopy(payload, 0, out, HEADER_LEN, payload.size)"
                           "payload.copyInto(out, HEADER_LEN)")
                     (cons "System.arraycopy(data, HEADER_LEN, payload, 0, payload.size)"
                           "data.copyInto(payload, 0, HEADER_LEN)")
                     (cons ".toByteArray(StandardCharsets.UTF_8)" ".encodeToByteArray()")
                     (cons "String(payload, StandardCharsets.UTF_8)" "payload.decodeToString()")
                     (cons "fun encodeTimeout(timeout: java.time.Duration): String {\n        var ms = timeout.toMillis()\n        if (timeout.minusMillis(ms).toNanos() > 0) ms++\n        if (ms <= 99999999L) return \"${ms}m\"\n        var secs = timeout.toSeconds()\n        if (timeout.minusSeconds(secs).toNanos() > 0) secs++\n        return \"${secs}S\"\n    }"
                           "fun encodeTimeout(timeoutNanos: Long): String {\n        val ms = (timeoutNanos + 999999L) / 1000000L\n        if (ms <= 99999999L) return \"${ms}m\"\n        val secs = (timeoutNanos + 999999999L) / 1000000000L\n        return \"${secs}S\"\n    }")
                     (cons "fun parseTimeout(text: String?): java.time.Duration?"
                           "fun parseTimeout(text: String?): Long?")
                     (cons "java.time.Duration.ofHours(n)" "n * 3600000000000L")
                     (cons "java.time.Duration.ofMinutes(n)" "n * 60000000000L")
                     (cons "java.time.Duration.ofSeconds(n)" "n * 1000000000L")
                     (cons "java.time.Duration.ofMillis(n)" "n * 1000000L")
                     (cons "java.time.Duration.ofNanos(n * 1000L)" "n * 1000L")
                     (cons "java.time.Duration.ofNanos(n)" "n")
                     (cons "sb.append(String.format(\"\\\\u%04x\", c.code))"
                           "sb.append(\"\\\\u\" + c.code.toString(16).padStart(4, '0'))"))))
   (cons "grpcdc/Transport.kt"
         (string-append
          (x "Transport" kotlin-transport-body
             (list
              (cons "typealias EndOfStream = java.io.EOFException"
                    "// EndOfStream is defined for Wasm below.")))
          kotlin-wasm-transport-extra))
   (cons "grpcdc/Endpoint.kt"
         (x "Endpoint"
            (kotlin-wasm-xform/common
             (string-replace kotlin-endpoint-body "@@FRAME_DISPATCH@@" (emit-kotlin-dispatch)))
            (list
                     (cons "import java.util.concurrent.ConcurrentHashMap\nimport java.util.concurrent.LinkedBlockingQueue\n" "")
                     (cons "@Synchronized\n    fun start()" "fun start()")
                     (cons "@Volatile\n" "")
                     (cons "        val id: Long\n        grpcdcSynchronized(sendLock) {\n            id = nextId\n            nextId += 2\n        }"
                           "        val id = nextId\n        nextId += 2")
                     (cons "ConcurrentHashMap<Long, StreamInput>()" "mutableMapOf<Long, StreamInput>()")
                     (cons "LinkedBlockingQueue<Any>()" "GrpcdcQueue<Any>()")
                     (cons "events.poll(10, java.util.concurrent.TimeUnit.MILLISECONDS)"
                           "events.pollNanos(10000000L)")
                     (cons "events.poll(\n                        minOf(remaining, 10_000_000L),\n                        java.util.concurrent.TimeUnit.NANOSECONDS)"
                           "events.pollNanos(minOf(remaining, 10000000L))")
                     (cons "events.poll(nanos, java.util.concurrent.TimeUnit.NANOSECONDS)"
                           "events.pollNanos(nanos)")
                     (cons "?.let { grpcdcNowNanos() + it.toNanos() } ?: -1L"
                           "?.let { grpcdcNowNanos() + it } ?: -1L")
                     (cons "fun timeRemaining(): java.time.Duration? =\n            if (deadlineNanos < 0) null\n            else java.time.Duration.ofNanos(maxOf(0L, deadlineNanos - grpcdcNowNanos()))"
                           "fun timeRemaining(): Long? =\n            if (deadlineNanos < 0) null\n            else maxOf(0L, deadlineNanos - grpcdcNowNanos())")
                     (cons "        val thread = Thread({ readLoop() }, \"grpcdc-endpoint\")\n        thread.isDaemon = true\n        thread.start()"
                           "        grpcdcSpawn { readLoop() }")
                     (cons "        val thread = Thread({\n            dispatchCall(streamId, input, headers, currentDispatcher)\n        }, \"grpcdc-call\")\n        thread.isDaemon = true\n        thread.start()"
                           "        grpcdcSpawn { dispatchCall(streamId, input, headers, currentDispatcher) }"))))
   (cons "grpcdc/Channel.kt"
         (x "Channel" (kotlin-wasm-xform/common kotlin-channel-body)
            (list
                     (cons "import java.io.EOFException\n" "")
                     (cons "java.time.Duration?" "Long?")
                     (cons "timeout.toNanos()" "timeout"))))
   (cons "grpcdc/Server.kt"
         (x "Server" kotlin-server-body
            (list (cons "import java.io.EOFException\n" ""))))
   (cons "grpcdc/MemoryTransport.kt"
         (x "MemoryTransport" kotlin-loopback-body
            (list
             (cons "import java.io.EOFException\nimport java.util.concurrent.LinkedBlockingQueue\n" "")
             (cons "@Volatile\n" "")
             (cons "data.clone()" "data.copyOf()")
             (cons "LinkedBlockingQueue<Any>" "GrpcdcQueue<Any>"))))))
