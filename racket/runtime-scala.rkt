#lang racket

;;; runtime-scala.rkt — the Scala gRPC runtime, emitted by metagen.rkt.
;;;
;;; The runtime files under scala/grpcdc/ are GENERATED from the
;;; bodies below plus fragments recursively expanded from spec.rkt's
;;; frame/status tables (see the dispatch generator). Do not edit the
;;; generated runtime files; edit here and run `make generate`.
;;; (Bodies were authored in-language and are kept verbatim so the
;;; generated output stays byte-reviewable in git diffs.)
;;;
;;; Scala 3 on the JVM, standard library only. Threaded endpoint
;;; mirroring the Kotlin runtime (read thread + per-call dispatch
;;; threads, timed queue waits for deadline enforcement).

(require "spec.rkt")
(provide emit-scala-runtime-files)

(define scala-status-body
#<<GRPC_RUNTIME_EOF
package grpcdc

/** A gRPC status (code + message) carried as an exception. */
class StatusException(val code: Int, message: String) extends Exception(message) {
  /** Trailing metadata carried by a status frame (never null). */
  var trailers: Map[String, String] = Map.empty

  override def toString: String = s"${Wire.statusName(code)}: $message"
}

object StatusException {
  /** Convert any exception to a StatusException (OK for null). */
  def toStatus(err: Throwable): StatusException = {
    if (err == null) {
      return StatusException(Wire.CODE_OK, "")
    }
    if (err.isInstanceOf[StatusException]) {
      return err.asInstanceOf[StatusException]
    }
    StatusException(Wire.CODE_INTERNAL, Option(err.getMessage).getOrElse(err.toString))
  }
}

/**
 * Homegrown tracing: W3C traceparent propagation with a span
 * observer. Dormant until Tracing.setTracer registers one;
 * generated code stays dependency-free (sampling and export are
 * the application's problem).
 */
object Tracing {
  /** Span observer callbacks (kind is "client" or "server"). */
  trait Tracer {
    def onStart(kind: String, method: String, traceId: String, spanId: String, parentSpanId: String): Unit
    def onEnd(kind: String, method: String, traceId: String, spanId: String, status: String): Unit
  }

  /** One in-flight span's context. */
  case class TraceContext(traceId: String, spanId: String, parentSpanId: String)

  /** Parsed traceparent parent. */
  case class Parent(traceId: String, spanId: String)

  @volatile private var tracer: Tracer = null
  private val rng = new java.security.SecureRandom()

  def setTracer(t: Tracer): Unit = {
    tracer = t
  }

  @volatile private var traceFilter: Array[String] = Array.empty

  // Restrict traced methods: ';'-separated paths, a trailing
  // '*' means prefix match ('/echo.Echo/*'). Empty = trace all.
  def setTraceFilter(patterns: String): Unit = {
    traceFilter = patterns.split(";").filter(_.nonEmpty)
  }

  def traceAllowed(method: String): Boolean = {
    if (traceFilter.isEmpty) return true
    traceFilter.exists { p =>
      if (p.endsWith("*")) method.startsWith(p.dropRight(1)) else method == p
    }
  }

  def enabled: Boolean = tracer != null

  def formatTraceparent(traceId: String, spanId: String): String =
    "00-" + traceId + "-" + spanId + "-01"

  def parseTraceparent(value: String): Parent = {
    if (value == null) return null
    val parts = value.split("-")
    if (parts.length != 4 || parts(1).length != 32 || parts(2).length != 16) return null
    if (!parts(1).forall(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return null
    if (!parts(2).forall(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return null
    Parent(parts(1), parts(2))
  }

  private def randomHex(bytes: Int): String = {
    val buf = new Array[Byte](bytes)
    rng.nextBytes(buf)
    val out = new StringBuilder(bytes * 2)
    for (b <- buf) {
      out.append(((b >> 4) & 0xf).toHexString)
      out.append((b & 0xf).toHexString)
    }
    out.toString
  }

  def traceStart(kind: String, method: String, parent: Parent): TraceContext = {
    val t = tracer
    if (t == null || !traceAllowed(method)) return null
    val ctx = TraceContext(
      if (parent != null) parent.traceId else randomHex(16),
      randomHex(8),
      if (parent != null) parent.spanId else "")
    try {
      t.onStart(kind, method, ctx.traceId, ctx.spanId, ctx.parentSpanId)
    } catch {
      case _: Throwable => ()
    }
    ctx
  }

  def traceEnd(kind: String, method: String, ctx: TraceContext, status: String): Unit = {
    val t = tracer
    if (ctx == null || t == null) return
    try {
      t.onEnd(kind, method, ctx.traceId, ctx.spanId, status)
    } catch {
      case _: Throwable => ()
    }
  }
}
GRPC_RUNTIME_EOF
)

(define scala-codec-body
#<<GRPC_RUNTIME_EOF
package grpcdc

import java.nio.charset.StandardCharsets

/**
 * Frame codec for gRPC over WebRTC DataChannels (wire protocol in
 * ../SPEC.md). Frame, status, channel and server semantics mirror the
 * other grpcdc runtimes; the tables in WireGen.scala are stamped by
 * grpc-dc codegen.
 */
object Codec {
  val HEADER_LEN: Int = 9
  val MAX_DATA_PAYLOAD: Int = 16 * 1024 * 1024

  /** One parsed frame. */
  class Frame(val frameType: Int, val streamId: Long, val payload: Array[Byte])

  /** Build one DataChannel message: header + payload. */
  def encodeFrame(frameType: Int, streamId: Long, payload: Array[Byte]): Array[Byte] = {
    if (!Wire.isFrameType(frameType)) {
      throw StatusException(Wire.CODE_INVALID_ARGUMENT, s"unknown frame type $frameType")
    }
    if (frameType == Wire.FRAME_DATA && payload.length > MAX_DATA_PAYLOAD) {
      throw StatusException(Wire.CODE_RESOURCE_EXHAUSTED, "DATA payload exceeds 16 MiB")
    }
    val out = new Array[Byte](HEADER_LEN + payload.length)
    out(0) = frameType.toByte
    putU32(out, 1, streamId)
    putU32(out, 5, payload.length.toLong)
    System.arraycopy(payload, 0, out, HEADER_LEN, payload.length)
    out
  }

  /** Parse one DataChannel message. */
  def decodeFrame(data: Array[Byte]): Frame = {
    if (data.length < HEADER_LEN) {
      throw StatusException(
        Wire.CODE_INVALID_ARGUMENT,
        s"frame shorter than 9-byte header: ${data.length} bytes")
    }
    val length = getU32(data, 5)
    if (length != (data.length - HEADER_LEN).toLong) {
      throw StatusException(
        Wire.CODE_INVALID_ARGUMENT,
        s"payload length $length does not match message size ${data.length}")
    }
    val payload = new Array[Byte](data.length - HEADER_LEN)
    System.arraycopy(data, HEADER_LEN, payload, 0, payload.length)
    Frame(data(0).toInt & 0xff, getU32(data, 1), payload)
  }

  def putU32(out: Array[Byte], off: Int, value: Long): Unit = {
    out(off) = (value >>> 24).toByte
    out(off + 1) = (value >>> 16).toByte
    out(off + 2) = (value >>> 8).toByte
    out(off + 3) = value.toByte
  }

  def getU32(inp: Array[Byte], off: Int): Long = {
    ((inp(off).toLong & 0xffL) << 24) | ((inp(off + 1).toLong & 0xffL) << 16) |
      ((inp(off + 2).toLong & 0xffL) << 8) | (inp(off + 3).toLong & 0xffL)
  }

  /** Parsed HEADERS payload: path == null means response headers. */
  class Headers(val path: String, val metadata: Map[String, String])

  def headersFrame(streamId: Long, path: String, metadata: Map[String, String]): Array[Byte] = {
    val sb = new StringBuilder("{")
    var first = true
    if (path != null) {
      sb.append("\"path\":").append(jsonString(path))
      first = false
    }
    if (metadata != null && metadata.nonEmpty) {
      if (!first) sb.append(',')
      sb.append("\"metadata\":{")
      var mFirst = true
      for ((k, v) <- metadata) {
        if (!mFirst) sb.append(',')
        sb.append(jsonString(k)).append(':').append(jsonString(v))
        mFirst = false
      }
      sb.append('}')
    }
    sb.append('}')
    encodeFrame(Wire.FRAME_HEADERS, streamId, sb.toString.getBytes(StandardCharsets.UTF_8))
  }

  def parseHeaders(payload: Array[Byte]): Headers = {
    val body = parseJsonObject(new String(payload, StandardCharsets.UTF_8))
    val metadata = scala.collection.mutable.LinkedHashMap[String, String]()
    body.get("metadata") match {
      case Some(md: Map[_, _]) =>
        for ((k, v) <- md) {
          metadata(k.toString) = v.toString
        }
      case _ => ()
    }
    val path = body.getOrElse("path", null)
    Headers(if (path == null) null else path.toString, metadata.toMap)
  }

  // gRPC timeout grammar (grpc-timeout metadata): <digits><unit>,
  // units H/M/S/m/u/n (at most 8 digits). Encoding uses
  // milliseconds (seconds past the digit limit), rounded up.
  def encodeTimeout(timeout: java.time.Duration): String = {
    var ms = timeout.toMillis
    if (timeout.minusMillis(ms).toNanos > 0) ms += 1
    if (ms <= 99999999L) return s"${ms}m"
    var secs = timeout.toSeconds
    if (timeout.minusSeconds(secs).toNanos > 0) secs += 1
    s"${secs}S"
  }

  /** Decoded grpc-timeout, or null when malformed/absent. */
  def parseTimeout(text: String): java.time.Duration = {
    if (text == null || text.length < 2 || text.length > 9) return null
    val digits = text.dropRight(1)
    if (!digits.forall(_.isDigit)) return null
    val n = digits.toLong
    text.last match {
      case 'H' => java.time.Duration.ofHours(n)
      case 'M' => java.time.Duration.ofMinutes(n)
      case 'S' => java.time.Duration.ofSeconds(n)
      case 'm' => java.time.Duration.ofMillis(n)
      case 'u' => java.time.Duration.ofNanos(n * 1000L)
      case 'n' => java.time.Duration.ofNanos(n)
      case _ => null
    }
  }

  def statusFrame(frameType: Int, streamId: Long, status: StatusException): Array[Byte] = {
    val sb = new StringBuilder
    sb.append("{\"code\":").append(status.code)
      .append(",\"message\":").append(jsonString(Option(status.getMessage).getOrElse("")))
    if (status.trailers != null && status.trailers.nonEmpty) {
      sb.append(",\"metadata\":{")
      var first = true
      for ((k, v) <- status.trailers) {
        if (!first) sb.append(',')
        sb.append(jsonString(k)).append(':').append(jsonString(v))
        first = false
      }
      sb.append('}')
    }
    sb.append('}')
    encodeFrame(frameType, streamId, sb.toString.getBytes(StandardCharsets.UTF_8))
  }

  def parseStatus(payload: Array[Byte]): StatusException = {
    try {
      val body = parseJsonObject(new String(payload, StandardCharsets.UTF_8))
      val code = body("code").asInstanceOf[Number].intValue
      val message = body.getOrElse("message", null)
      val status = StatusException(code, if (message == null) "" else message.toString)
      body.get("metadata") match {
        case Some(mm: Map[_, _]) =>
          status.trailers = mm.map { case (k, v) => k.toString -> v.toString }
        case _ => ()
      }
      status
    } catch {
      case e: RuntimeException => StatusException(Wire.CODE_UNKNOWN, "malformed trailers")
    }
  }

  // -- minimal JSON (flat objects, string/number/nested-object values) --

  def jsonString(value: String): String = {
    val sb = new StringBuilder("\"")
    for (c <- value) {
      c match {
        case '"' => sb.append("\\\"")
        case '\\' => sb.append("\\\\")
        case '\n' => sb.append("\\n")
        case '\r' => sb.append("\\r")
        case '\t' => sb.append("\\t")
        case _ =>
          if (c < ' ') {
            sb.append(String.format("\\u%04x", c.toInt))
          } else {
            sb.append(c)
          }
      }
    }
    sb.append('"').toString
  }

  def parseJsonObject(text: String): Map[String, Any] = {
    val pos = Array(0)
    val obj = parseObject(text, pos)
    skipWs(text, pos)
    if (pos(0) != text.length) {
      throw StatusException(Wire.CODE_INVALID_ARGUMENT, "trailing data in JSON")
    }
    obj
  }

  private def skipWs(text: String, pos: Array[Int]): Unit = {
    while (pos(0) < text.length && text(pos(0)).isWhitespace) {
      pos(0) += 1
    }
  }

  private def parseObject(text: String, pos: Array[Int]): Map[String, Any] = {
    skipWs(text, pos)
    expect(text, pos, '{')
    val map = scala.collection.mutable.LinkedHashMap[String, Any]()
    skipWs(text, pos)
    if (pos(0) < text.length && text(pos(0)) == '}') {
      pos(0) += 1
      return map.toMap
    }
    while (true) {
      skipWs(text, pos)
      val key = parseString(text, pos)
      skipWs(text, pos)
      expect(text, pos, ':')
      val value = parseValue(text, pos)
      map(key) = value
      skipWs(text, pos)
      if (pos(0) >= text.length) {
        throw StatusException(Wire.CODE_INVALID_ARGUMENT, "unterminated JSON object")
      }
      text(pos(0)) match {
        case '}' => pos(0) += 1; return map.toMap
        case ',' => pos(0) += 1
        case _ => throw StatusException(Wire.CODE_INVALID_ARGUMENT, "expected ',' or '}' in JSON")
      }
    }
    map.toMap
  }

  private def parseValue(text: String, pos: Array[Int]): Any = {
    skipWs(text, pos)
    if (pos(0) >= text.length) {
      throw StatusException(Wire.CODE_INVALID_ARGUMENT, "missing JSON value")
    }
    text(pos(0)) match {
      case '"' => parseString(text, pos)
      case '{' => parseObject(text, pos)
      case 't' => expectLiteral(text, pos, "true"); true
      case 'f' => expectLiteral(text, pos, "false"); false
      case 'n' => expectLiteral(text, pos, "null"); null
      case _ =>
        val start = pos(0)
        while (pos(0) < text.length && "-+0123456789.eE".indexOf(text(pos(0)).toInt) >= 0) {
          pos(0) += 1
        }
        if (start == pos(0)) {
          throw StatusException(Wire.CODE_INVALID_ARGUMENT, "bad JSON value")
        }
        text.substring(start, pos(0)).toDouble
    }
  }

  private def parseString(text: String, pos: Array[Int]): String = {
    expect(text, pos, '"')
    val sb = new StringBuilder
    while (pos(0) < text.length) {
      val c = text(pos(0))
      pos(0) += 1
      if (c == '"') {
        return sb.toString
      }
      if (c == '\\' && pos(0) < text.length) {
        val esc = text(pos(0))
        pos(0) += 1
        esc match {
          case 'n' => sb.append('\n')
          case 'r' => sb.append('\r')
          case 't' => sb.append('\t')
          case 'b' => sb.append('\b')
          case 'f' => sb.append('\u000C')
          case 'u' =>
            sb.append(Integer.parseInt(text.substring(pos(0), pos(0) + 4), 16).toChar)
            pos(0) += 4
          case _ => sb.append(esc)
        }
      } else {
        sb.append(c)
      }
    }
    throw StatusException(Wire.CODE_INVALID_ARGUMENT, "unterminated JSON string")
  }

  private def expect(text: String, pos: Array[Int], wanted: Char): Unit = {
    if (pos(0) >= text.length || text(pos(0)) != wanted) {
      throw StatusException(Wire.CODE_INVALID_ARGUMENT, s"expected '$wanted' in JSON")
    }
    pos(0) += 1
  }

  private def expectLiteral(text: String, pos: Array[Int], literal: String): Unit = {
    if (!text.startsWith(literal, pos(0))) {
      throw StatusException(Wire.CODE_INVALID_ARGUMENT, "bad JSON literal")
    }
    pos(0) += literal.length
  }
}
GRPC_RUNTIME_EOF
)

(define scala-transport-body
#<<GRPC_RUNTIME_EOF
package grpcdc

/**
 * Carries whole DataChannel messages: one send/recv is one message,
 * boundaries preserved, ordered and reliable — the contract an
 * RTCDataChannel (or the loopback pair) offers.
 */
/** End-of-stream thrown by Transport.recv (EOFException on the JVM). */
type EndOfStream = java.io.EOFException

trait Transport {
  def send(data: Array[Byte]): Unit

  /** Next message; EOFException when the transport is closed. */
  def recv(): Array[Byte]

  def close(): Unit = {}
}

/** Implemented by hand-written protobuf message types. */
trait Marshaler {
  def marshalDc(): Array[Byte]
}

/** Implemented by hand-written protobuf message types. */
trait Unmarshaler {
  def unmarshalDc(data: Array[Byte]): Unit
}
GRPC_RUNTIME_EOF
)

(define scala-endpoint-body
#<<GRPC_RUNTIME_EOF
package grpcdc

import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.LinkedBlockingQueue

/** Multiplexes grpc-dc streams over one Transport. */
class Endpoint(private val transport: Transport, creator: Boolean) {
  import Endpoint.EventKind

  class StreamEvent(
      val kind: EventKind,
      val headers: Codec.Headers,
      val payload: Array[Byte],
      val status: StatusException)

  /** Receiving queue of one stream; closed after a terminal event. */
  class StreamInput {
    private val events = new LinkedBlockingQueue[Any]()

    def put(event: StreamEvent): Unit = {
      events.offer(event)
      ()
    }

    def close(): Unit = {
      events.offer(StreamInput.CLOSED)
      ()
    }

    private def convert(event: Any): StreamEvent = {
      if (event.asInstanceOf[AnyRef] eq StreamInput.CLOSED) null
      else event.asInstanceOf[StreamEvent]
    }

    /** Next event, or null once the stream is closed. */
    def get(): StreamEvent = convert(events.take())

    /**
     * Next event within nanos, or null once closed.
     * Throws TimeoutException on expiry.
     */
    def getNanos(nanos: Long): StreamEvent = {
      val event = events.poll(nanos, java.util.concurrent.TimeUnit.NANOSECONDS)
      if (event == null) throw new java.util.concurrent.TimeoutException()
      convert(event)
    }
  }

  object StreamInput {
    private val CLOSED = new Object()
  }

  /** Per-call context: metadata sent in HEADERS. */
  class CallContext(val metadata: Map[String, String]) {
    /** Response initial metadata recorded via setHeaders. */
    val responseHeaders: scala.collection.mutable.Map[String, String] =
      scala.collection.mutable.HashMap.empty
    /** Response trailing metadata recorded via setTrailers. */
    val responseTrailers: scala.collection.mutable.Map[String, String] =
      scala.collection.mutable.HashMap.empty

    /** Record response initial metadata (sent lazily, before the first response message). */
    def setHeaders(md: Map[String, String]): Unit = {
      responseHeaders ++= md
    }

    /** Record response trailing metadata (rides the terminal status frame). */
    def setTrailers(md: Map[String, String]): Unit = {
      responseTrailers ++= md
    }

    /** Monotonic deadline (System.nanoTime), or -1 when unbounded. */
    val deadlineNanos: Long = {
      val parsed = Codec.parseTimeout(metadata.getOrElse("grpc-timeout", null))
      if (parsed == null) -1L else System.nanoTime() + parsed.toNanos
    }

    /** Time left before the deadline, or null when unbounded. */
    def timeRemaining(): java.time.Duration = {
      if (deadlineNanos < 0) null
      else java.time.Duration.ofNanos(math.max(0L, deadlineNanos - System.nanoTime()))
    }

    def deadlineExceeded(): Boolean = {
      deadlineNanos >= 0 && System.nanoTime() - deadlineNanos >= 0
    }
  }

  /** Sends response payloads of one inbound call. */
  class ResponseSink(private val endpoint: Endpoint, private val streamId: Long) {
    // Wired to the CallContext maps by the endpoint.
    var respHeaders: scala.collection.Map[String, String] = Map.empty
    var respTrailers: scala.collection.Map[String, String] = Map.empty
    var headersSent: Boolean = false

    // A stream the endpoint has forgotten was RST by the peer
    // (or the channel went away): fail the send so a producing
    // handler stops instead of streaming into the void.
    private def checkOpen(): Unit = {
      if (endpoint.stream(streamId) == null) {
        throw StatusException(Wire.CODE_CANCELLED, "call cancelled")
      }
    }

    def send(payload: Array[Byte]): Unit = {
      checkOpen()
      flushHeaders()
      endpoint.sendFrame(Codec.encodeFrame(Wire.FRAME_DATA, streamId, payload))
    }

    def flushHeaders(): Unit = {
      if (!headersSent) {
        headersSent = true
        sendHeaders(respHeaders.toMap)
      }
    }

    def sendHeaders(): Unit = {
      sendHeaders(respHeaders.toMap)
    }

    def sendHeaders(metadata: Map[String, String]): Unit = {
      checkOpen()
      headersSent = true
      endpoint.sendFrame(Codec.headersFrame(streamId, null, metadata))
    }

    def sendTrailers(status: StatusException): Unit = {
      var out = status
      if (respTrailers.nonEmpty) {
        out = StatusException(status.code, Option(status.getMessage).getOrElse(""))
        out.trailers = (respTrailers ++ status.trailers).toMap
      }
      endpoint.sendFrame(Codec.statusFrame(Wire.FRAME_TRAILERS, streamId, out))
    }
  }

  /** Server-side call handler installed by Server.
   * Returned status becomes the call's TRAILERS (null means OK). */
  type Dispatcher = (CallContext, Codec.Headers, StreamInput, ResponseSink) => StatusException

  private var dispatcher: Dispatcher = null
  private var nextId: Long = if (creator) 1 else 2
  private val sendLock = new Object()
  private val streams = new ConcurrentHashMap[Long, StreamInput]()

  @volatile
  private var closed = false
  private var started = false

  /**
   * The side that created the channel allocates odd stream ids, the
   * answerer even. The read loop starts on start() — after any
   * dispatcher is installed, so an early HEADERS can never race
   * dispatcher setup.
   */
  def start(): Unit = synchronized {
    if (started) {
      return
    }
    started = true
    val thread = new Thread(() => readLoop(), "grpcdc-endpoint")
    thread.setDaemon(true)
    thread.start()
  }

  def setDispatcher(dispatcher: Dispatcher): Unit = {
    this.dispatcher = dispatcher
  }

  def sendFrame(frame: Array[Byte]): Unit = {
    sendLock.synchronized {
      transport.send(frame)
    }
  }

  case class OpenedStream(id: Long, input: StreamInput)

  def openStream(): OpenedStream = {
    val id = sendLock.synchronized {
      val current = nextId
      nextId += 2
      current
    }
    val input = new StreamInput()
    streams.put(id, input)
    OpenedStream(id, input)
  }

  def closeStream(id: Long): Unit = {
    streams.remove(id)
    ()
  }

  /** Abort one stream: RST out; a pending recv wakes with CANCELLED. */
  def cancelStream(id: Long): Unit = {
    val input = streams.remove(id)
    if (input != null) {
      input.put(StreamEvent(EventKind.RST, null, null,
        StatusException(Wire.CODE_CANCELLED, "call cancelled")))
      input.close()
    }
    try {
      sendFrame(Codec.statusFrame(Wire.FRAME_RST, id,
        StatusException(Wire.CODE_CANCELLED, "call cancelled")))
    } catch {
      case e: Exception => () // Transport already gone; the local abort still stands.
    }
  }

  private def stream(id: Long): StreamInput = streams.get(id)

  def close(): Unit = {
    if (closed) {
      return
    }
    closed = true
    try {
      transport.close()
    } catch {
      case e: Exception => () // best effort
    }
    failAll()
  }

  private def failAll(): Unit = {
    val it = streams.values().iterator()
    while (it.hasNext) {
      val input = it.next()
      input.put(StreamEvent(EventKind.RST, null, null,
        StatusException(Wire.CODE_UNAVAILABLE, "data channel closed")))
      input.close()
    }
    streams.clear()
  }

  private def readLoop(): Unit = {
    while (true) {
      val data: Array[Byte] =
        try {
          transport.recv()
        } catch {
          case e: Exception =>
            failAll()
            return
        }
      if (closed) {
        return
      }
      onBytes(data)
    }
  }

  private def onBytes(data: Array[Byte]): Unit = {
    val frame: Codec.Frame =
      try {
        Codec.decodeFrame(data)
      } catch {
        case e: StatusException => return // malformed frame: drop, keep the channel up
      }
    frame.frameType match {
      case Wire.FRAME_HEADERS => onHeaders(frame.streamId, frame.payload)
      case Wire.FRAME_DATA => pushEvent(frame.streamId, StreamEvent(EventKind.DATA, null, frame.payload, null))
      case Wire.FRAME_TRAILERS => onTerminal(frame.streamId, frame.payload, EventKind.TRAILERS)
      case Wire.FRAME_HALF_CLOSE => pushEvent(frame.streamId, StreamEvent(EventKind.HALF_CLOSE, null, null, null))
      case Wire.FRAME_RST => onTerminal(frame.streamId, frame.payload, EventKind.RST)
      case _ => () // Unknown frame type: ignore for forward compatibility.
    }
  }

  private def onTerminal(streamId: Long, payload: Array[Byte], kind: EventKind): Unit = {
    val input = stream(streamId)
    if (input != null) {
      input.put(StreamEvent(kind, null, null, Codec.parseStatus(payload)))
      input.close()
      closeStream(streamId)
    }
  }

  private def pushEvent(streamId: Long, event: StreamEvent): Unit = {
    val input = stream(streamId)
    if (input != null) {
      input.put(event)
    }
  }

  private def onHeaders(streamId: Long, payload: Array[Byte]): Unit = {
    val headers: Codec.Headers =
      try {
        Codec.parseHeaders(payload)
      } catch {
        case e: StatusException =>
          try {
            sendFrame(Codec.statusFrame(Wire.FRAME_RST, streamId, StatusException.toStatus(e)))
          } catch {
            case ignored: Exception => ()
          }
          return
      }
    if (headers.path == null) {
      // Server response headers for one of our outbound streams.
      val input = stream(streamId)
      if (input != null) {
        input.put(StreamEvent(EventKind.HEADERS, headers, null, null))
      }
      return
    }
    if (stream(streamId) != null) {
      try {
        sendFrame(Codec.statusFrame(Wire.FRAME_RST, streamId,
          StatusException(Wire.CODE_INTERNAL, "HEADERS for stream already in use")))
      } catch {
        case ignored: Exception => ()
      }
      return
    }
    val currentDispatcher = dispatcher
    if (currentDispatcher == null) {
      try {
        sendFrame(Codec.statusFrame(Wire.FRAME_TRAILERS, streamId,
          StatusException(Wire.CODE_UNIMPLEMENTED, "unknown method " + headers.path)))
      } catch {
        case ignored: Exception => ()
      }
      return
    }
    val input = new StreamInput()
    streams.put(streamId, input)
    val thread = new Thread(() => {
      dispatchCall(streamId, input, headers, currentDispatcher)
    }, "grpcdc-call")
    thread.setDaemon(true)
    thread.start()
  }

  private def dispatchCall(streamId: Long, input: StreamInput,
                           headers: Codec.Headers, dispatcher: Dispatcher): Unit = {
    val sink = new ResponseSink(this, streamId)
    try {
      // No eager HEADERS: initial metadata flushes lazily via
      // the sink (first DATA, or below on a DATA-less success)
      // so handlers can setHeaders first. Errors end
      // trailers-only, as gRPC allows.
      val ctx = CallContext(headers.metadata)
      sink.respHeaders = ctx.responseHeaders
      sink.respTrailers = ctx.responseTrailers
      var status = dispatcher(ctx, headers, input, sink)
      if (status == null) {
        status = StatusException(Wire.CODE_OK, "")
        try {
          sink.flushHeaders()
        } catch {
          case ignored: Exception => ()
        }
      }
      try {
        sink.sendTrailers(status)
      } catch {
        case ignored: Exception => ()
      }
    } finally {
      closeStream(streamId)
    }
  }
}

object Endpoint {
  /** Stream event kinds delivered to StreamInput queues. */
  enum EventKind { case HEADERS, DATA, HALF_CLOSE, TRAILERS, RST }
}
GRPC_RUNTIME_EOF
)

(define scala-channel-body
#<<GRPC_RUNTIME_EOF
package grpcdc

import java.io.EOFException

/** Channel: the client side of one Endpoint. */
class Channel(val endpoint: Endpoint) {
  endpoint.start()

  /** Wrap a transport, allocating odd stream ids. */
  def this(transport: Transport) = {
    this(Endpoint(transport, true))
  }

  /** Receives response messages of one call. */
  class ClientStream(
      val streamId: Long,
      private val endpoint: Endpoint,
      private val input: Endpoint#StreamInput) {
    var deadlineNanos: Long = -1L
    var headers: Codec.Headers = null
    /** Trailing metadata of the terminal status (null until it arrives). */
    var trailers: Map[String, String] = null
    var traceCtx: Tracing.TraceContext = null
    var tracePath: String = null
    private var traceEnded: Boolean = false

    @volatile
    private var terminated: Boolean = false

    def endTrace(status: String): Unit = {
      if (!traceEnded) {
        traceEnded = true
        Tracing.traceEnd("client", tracePath, traceCtx, status)
      }
    }

    /** Send one request message on an open stream (no half-close). */
    def send(msg: Marshaler): Unit = {
      endpoint.sendFrame(Codec.encodeFrame(Wire.FRAME_DATA, streamId, msg.marshalDc()))
    }

    /** Half-close an open stream (no more requests). */
    def halfClose(): Unit = {
      endpoint.sendFrame(Codec.encodeFrame(Wire.FRAME_HALF_CLOSE, streamId, new Array[Byte](0)))
    }

    /** Abort this stream (sends RST, wakes a pending recv). */
    def cancel(): Unit = {
      if (!terminated) {
        terminated = true
        endpoint.cancelStream(streamId)
      }
    }

    /** Abandon this stream: RST CANCELLED unless it already
     * completed, in which case it just closes locally. */
    def close(): Unit = cancel()

    private def nextEvent(): Endpoint#StreamEvent = {
      if (deadlineNanos < 0) {
        val event = input.get()
        if (event == null) {
          terminated = true
          throw StatusException(Wire.CODE_UNAVAILABLE, "data channel closed")
        }
        return event
      }
      try {
        val remaining = deadlineNanos - System.nanoTime()
        if (remaining <= 0) throw new java.util.concurrent.TimeoutException()
        val event = input.getNanos(remaining)
        if (event == null) {
          terminated = true
          throw StatusException(Wire.CODE_UNAVAILABLE, "data channel closed")
        }
        event
      } catch {
        case e: java.util.concurrent.TimeoutException =>
          terminated = true
          endpoint.cancelStream(streamId)
          throw StatusException(Wire.CODE_DEADLINE_EXCEEDED, "deadline exceeded")
      }
    }

    /**
     * Decode the next response into resp. EOFException means the
     * call completed OK; StatusException reports the trailers.
     */
    def recv(resp: Unmarshaler): Unit = {
      while (true) {
        val event = nextEvent()
        event.kind match {
          case Endpoint.EventKind.HEADERS => headers = event.headers
          case Endpoint.EventKind.DATA =>
            resp.unmarshalDc(event.payload)
            return
          case Endpoint.EventKind.TRAILERS =>
            terminated = true
            val status = event.status
            trailers = if (status != null) status.trailers else null
            endTrace(Wire.statusName(if (status != null) status.code else Wire.CODE_OK))
            if (status != null && status.code != Wire.CODE_OK) {
              throw status
            }
            throw new EOFException("call completed")
          case Endpoint.EventKind.RST =>
            terminated = true
            val status = if (event.status != null) event.status
                         else StatusException(Wire.CODE_UNAVAILABLE, "stream reset")
            trailers = status.trailers
            endTrace(Wire.statusName(status.code))
            throw status
          case _ => ()
        }
      }
    }
  }

  private def open(path: String, metadata: Map[String, String],
                   timeout: java.time.Duration): ClientStream = {
    var md = metadata
    var deadlineNanos = -1L
    var traceCtx: Tracing.TraceContext = null
    if (timeout != null || Tracing.enabled) {
      md = if (md == null) Map.empty[String, String] else md
      if (timeout != null) {
        deadlineNanos = System.nanoTime() + timeout.toNanos
        md = md + ("grpc-timeout" -> Codec.encodeTimeout(timeout))
      }
      if (Tracing.enabled) {
        traceCtx = Tracing.traceStart("client", path, Tracing.parseTraceparent(md.getOrElse("traceparent", null)))
        if (traceCtx != null) {
          md = md + ("traceparent" -> Tracing.formatTraceparent(traceCtx.traceId, traceCtx.spanId))
        }
      }
    }
    val opened = endpoint.openStream()
    try {
      endpoint.sendFrame(Codec.headersFrame(opened.id, path, md))
    } catch {
      case e: Exception =>
        endpoint.closeStream(opened.id)
        Tracing.traceEnd("client", path, traceCtx, "UNAVAILABLE")
        throw e
    }
    val stream = new ClientStream(opened.id, endpoint, opened.input)
    stream.deadlineNanos = deadlineNanos
    stream.traceCtx = traceCtx
    stream.tracePath = path
    stream
  }

  private def sendMessage(stream: ClientStream, msg: Marshaler): Unit = {
    endpoint.sendFrame(Codec.encodeFrame(Wire.FRAME_DATA, stream.streamId, msg.marshalDc()))
  }

  private def halfClose(stream: ClientStream): Unit = {
    endpoint.sendFrame(Codec.encodeFrame(Wire.FRAME_HALF_CLOSE, stream.streamId, Array.empty[Byte]))
  }

  private def sendAll(stream: ClientStream, reqs: List[Marshaler]): Unit = {
    for (req <- reqs) {
      sendMessage(stream, req)
    }
    halfClose(stream)
  }

  private def collectOne(stream: ClientStream, resp: Unmarshaler, what: String): Unit = {
    var got = false
    while (true) {
      try {
        stream.recv(resp)
      } catch {
        case e: EOFException =>
          if (!got) {
            throw StatusException(Wire.CODE_INTERNAL, "call closed with no response")
          }
          return
      }
      if (got) {
        throw StatusException(Wire.CODE_INTERNAL, s"$what received more than one response")
      }
      got = true
    }
  }

  /** Run a unary call, decoding the single response into resp. */
  def unary(path: String, req: Marshaler, resp: Unmarshaler, metadata: Map[String, String] = null, timeout: java.time.Duration = null): Unit = {
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
  def serverStream(path: String, req: Marshaler, metadata: Map[String, String] = null, timeout: java.time.Duration = null): ClientStream = {
    val stream = open(path, metadata, timeout)
    sendMessage(stream, req)
    halfClose(stream)
    stream
  }

  /** Send all requests, then decode the one response into resp. */
  def clientStreamCall(path: String, reqs: List[Marshaler], resp: Unmarshaler, metadata: Map[String, String] = null, timeout: java.time.Duration = null): Unit = {
    val stream = open(path, metadata, timeout)
    try {
      sendAll(stream, reqs)
      collectOne(stream, resp, "client-streaming call")
    } finally {
      endpoint.closeStream(stream.streamId)
    }
  }

  /** Open a stream without sending anything: drive it with
   *  ClientStream.send / halfClose / recv / cancel. */
  def openStream(path: String, metadata: Map[String, String] = null, timeout: java.time.Duration = null): ClientStream = {
    open(path, metadata, timeout)
  }

  /** Start a bidi call with all requests sent up front. */
  def bidi(path: String, reqs: List[Marshaler], metadata: Map[String, String] = null, timeout: java.time.Duration = null): ClientStream = {
    val stream = open(path, metadata, timeout)
    sendAll(stream, reqs)
    stream
  }
}
GRPC_RUNTIME_EOF
)

(define scala-server-body
#<<GRPC_RUNTIME_EOF
package grpcdc

import java.io.EOFException

/** Server: dispatches inbound calls to registered methods. */
class Server {
  import Server.{Method, ServerSink, ServiceDesc}

  /** Reads request messages of one inbound call. */
  class RequestStream(private val input: Endpoint#StreamInput) {
    /** Next request payload; EOFException at half-close. */
    def recvRaw(): Array[Byte] = {
      while (true) {
        val event = input.get()
        if (event == null) {
          throw StatusException(Wire.CODE_UNAVAILABLE, "data channel closed")
        }
        event.kind match {
          case Endpoint.EventKind.DATA => return event.payload
          case Endpoint.EventKind.HALF_CLOSE => throw new EOFException("half-close")
          case Endpoint.EventKind.TRAILERS | Endpoint.EventKind.RST =>
            throw (if (event.status != null) event.status
                   else StatusException(Wire.CODE_UNAVAILABLE, "stream closed"))
          case _ => () // ignore HEADERS on the request side
        }
      }
      Array.empty[Byte] // unreachable
    }

    /** Decode the next request message into req. */
    def recvInto(req: Unmarshaler): Unit = {
      req.unmarshalDc(recvRaw())
    }
  }

  private val methods = scala.collection.mutable.HashMap[String, Method]()

  /** Adds a service's methods (generated code calls it). */
  def registerService(desc: ServiceDesc): Unit = {
    for (method <- desc.methods) {
      methods(method.path) = method
    }
  }

  /** Attach to a transport (even stream ids); returns the Endpoint. */
  def serveTransport(transport: Transport): Endpoint = {
    val endpoint = Endpoint(transport, false)
    serveEndpoint(endpoint)
    endpoint
  }

  /** Attach to an existing endpoint (starts its read loop). */
  def serveEndpoint(endpoint: Endpoint): Unit = {
    endpoint.setDispatcher((ctx, headers, input, sink) => dispatch(ctx, headers, input, sink))
    endpoint.start()
  }

  private def dispatch(ctx: Endpoint#CallContext, headers: Codec.Headers,
                       input: Endpoint#StreamInput, sink: Endpoint#ResponseSink): StatusException = {
    val method = methods.getOrElse(headers.path, null)
    if (method == null) {
      return StatusException(Wire.CODE_UNIMPLEMENTED, "unknown method " + headers.path)
    }
    val traceCtx = Tracing.traceStart("server", headers.path, Tracing.parseTraceparent(headers.metadata.getOrElse("traceparent", null)))
    var result: StatusException = null
    try {
      method.handler(ctx, new RequestStream(input), new ServerSink {
        def send(payload: Array[Byte]): Unit = sink.send(payload)
      })
    } catch {
      case e: Exception => result = StatusException.toStatus(e)
    }
    Tracing.traceEnd("server", headers.path, traceCtx, if (result == null) "OK" else Wire.statusName(result.code))
    result
  }
}

object Server {
  val KIND_UNARY: String = "unary"
  val KIND_SERVER_STREAMING: String = "server-streaming"
  val KIND_CLIENT_STREAMING: String = "client-streaming"
  val KIND_BIDI: String = "bidi"

  /** Sends response payloads of one inbound call. */
  trait ServerSink {
    def send(payload: Array[Byte]): Unit
  }

  /** Implements one method against raw payloads; stubs adapt it. */
  type MethodHandler = (Endpoint#CallContext, Server#RequestStream, ServerSink) => Unit

  /** One entry of a ServiceDesc. */
  case class Method(name: String, path: String, kind: String, handler: MethodHandler)

  /** Describes a service for registerService. */
  case class ServiceDesc(name: String, methods: List[Method])
}
GRPC_RUNTIME_EOF
)

(define scala-memory-body
#<<GRPC_RUNTIME_EOF
package grpcdc

import java.io.EOFException
import java.util.concurrent.LinkedBlockingQueue

/** In-memory transport pair for tests (one queue per direction). */
object MemoryTransport {
  private val SENTINEL = new Object()

  private class Impl(
      private val inbox: LinkedBlockingQueue[Any],
      private val outbox: LinkedBlockingQueue[Any]) extends Transport {
    @volatile
    private var closed = false

    def send(data: Array[Byte]): Unit = {
      if (closed) {
        throw new EOFException("transport closed")
      }
      outbox.offer(data.clone())
      ()
    }

    def recv(): Array[Byte] = {
      val item = inbox.take()
      if (item.asInstanceOf[AnyRef] eq SENTINEL) {
        throw new EOFException("transport closed")
      }
      item.asInstanceOf[Array[Byte]]
    }

    override def close(): Unit = {
      closed = true
      inbox.offer(SENTINEL)
      ()
    }
  }

  /** Two connected in-memory transports. */
  def pair(): (Transport, Transport) = {
    val aToB = new LinkedBlockingQueue[Any]()
    val bToA = new LinkedBlockingQueue[Any]()
    (Impl(bToA, aToB), Impl(aToB, bToA))
  }
}
GRPC_RUNTIME_EOF
)


(define scala-sidecar-body
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
class SidecarTransport(private val socket: Socket) extends Transport {
  private val input = new DataInputStream(socket.getInputStream())
  private val output = socket.getOutputStream()

  @volatile
  private var closed = false

  def send(data: Array[Byte]): Unit = {
    if (closed) {
      throw new EOFException("transport closed")
    }
    val header = Array[Byte](
      (data.length >>> 24).toByte,
      (data.length >>> 16).toByte,
      (data.length >>> 8).toByte,
      data.length.toByte
    )
    output.synchronized {
      output.write(header)
      output.write(data)
      output.flush()
    }
  }

  def recv(): Array[Byte] = {
    val length = input.readInt()
    val payload = new Array[Byte](length)
    input.readFully(payload)
    payload
  }

  override def close(): Unit = {
    closed = true
    try {
      socket.close()
    } catch {
      case _: Exception => ()
    }
  }
}

object SidecarTransport {
  def connect(host: String, port: Int): SidecarTransport =
    new SidecarTransport(new Socket(host, port))
}
GRPC_RUNTIME_EOF
)

(define scala-futures-body
#<<GRPC_RUNTIME_EOF
package grpcdc

import java.util.concurrent.Executors
import scala.concurrent.{ExecutionContext, Future}

/**
 * Future surface for generated stubs: blocking calls run on a
 * daemon cached pool (the Scala counterpart of the Kotlin
 * runtime's CompletableFuture bridge — stdlib only).
 */
object Futures {
  private val executor = Executors.newCachedThreadPool { (r: Runnable) =>
    val thread = new Thread(r, "grpcdc-async")
    thread.setDaemon(true)
    thread
  }

  implicit val ec: ExecutionContext = ExecutionContext.fromExecutor(executor)

  /** Run a blocking call as a Future on the pool. */
  def apply[T](block: => T): Future[T] = Future(block)(ec)
}
GRPC_RUNTIME_EOF
)

(define scala-dynamic-body
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
 * string -> String, bytes/message -> Array[Byte] / GenericMessage,
 * fixed/float -> Long / Double. Repeated fields are lists in
 * field-number order.
 */
object Dynamic {
  // FieldDescriptorProto.Type values (descriptor.proto).
  val TYPE_DOUBLE: Int = 1
  val TYPE_FLOAT: Int = 2
  val TYPE_INT64: Int = 3
  val TYPE_UINT64: Int = 4
  val TYPE_INT32: Int = 5
  val TYPE_FIXED64: Int = 6
  val TYPE_FIXED32: Int = 7
  val TYPE_BOOL: Int = 8
  val TYPE_STRING: Int = 9
  val TYPE_GROUP: Int = 10
  val TYPE_MESSAGE: Int = 11
  val TYPE_BYTES: Int = 12
  val TYPE_UINT32: Int = 13
  val TYPE_ENUM: Int = 14
  val TYPE_SFIXED32: Int = 15
  val TYPE_SFIXED64: Int = 16
  val TYPE_SINT32: Int = 17
  val TYPE_SINT64: Int = 18

  private val LABEL_REPEATED: Int = 3

  class FieldModel(
      var number: Int = 0,
      var name: String = "",
      var fieldType: Int = 0,
      var repeated: Boolean = false,
      var typeName: String = "" // for TYPE_MESSAGE, e.g. ".echo.EchoRequest"
  )

  class MessageModel(
      val fullName: String,
      val fields: scala.collection.mutable.Map[Int, FieldModel] = scala.collection.mutable.TreeMap[Int, FieldModel](),
      val byName: scala.collection.mutable.Map[String, Int] = scala.collection.mutable.HashMap[String, Int]()
  )

  class MethodModel(
      var name: String = "",
      var path: String = "",
      var kind: String = "",
      var input: MessageModel = null,
      var output: MessageModel = null
  )

  class ServiceModel(
      val fullName: String,
      val methods: scala.collection.mutable.Map[String, MethodModel] = scala.collection.mutable.HashMap[String, MethodModel]()
  )

  /**
   * Parsed descriptor set: messages and services by full name.
   * Message keys carry the leading dot (".echo.EchoRequest"),
   * matching FieldDescriptorProto.type_name; service keys do not
   * ("echo.Echo").
   */
  class FileModel {
    val messages: scala.collection.mutable.Map[String, MessageModel] = scala.collection.mutable.HashMap[String, MessageModel]()
    val services: scala.collection.mutable.Map[String, ServiceModel] = scala.collection.mutable.HashMap[String, ServiceModel]()

    def message(fullName: String): MessageModel = {
      messages.getOrElse(fullName,
        throw StatusException(Wire.CODE_INVALID_ARGUMENT, s"unknown message $fullName"))
    }

    def service(fullName: String): ServiceModel = {
      services.getOrElse(fullName,
        throw StatusException(Wire.CODE_INVALID_ARGUMENT, s"unknown service $fullName"))
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
  class GenericMessage(val model: MessageModel) {
    val values: scala.collection.mutable.Map[Int, scala.collection.mutable.ListBuffer[Any]] =
      scala.collection.mutable.TreeMap[Int, scala.collection.mutable.ListBuffer[Any]]()
    val unknown: scala.collection.mutable.ListBuffer[Array[Byte]] =
      scala.collection.mutable.ListBuffer[Array[Byte]]()

    def set(number: Int, value: Any): GenericMessage = {
      values(number) = scala.collection.mutable.ListBuffer(value)
      this
    }

    def add(number: Int, value: Any): GenericMessage = {
      values.getOrElseUpdate(number, scala.collection.mutable.ListBuffer[Any]()) += value
      this
    }

    def get(number: Int): Any = {
      val list = values.getOrElse(number, null)
      if (list == null || list.isEmpty) null else list.head
    }

    def getString(number: Int): String = {
      get(number) match {
        case v: String => v
        case _ => ""
      }
    }

    def getInt(number: Int): Long = {
      get(number) match {
        case v: Boolean => if (v) 1L else 0L
        case v: Number => v.longValue
        case _ => 0L
      }
    }

    override def toString: String = s"GenericMessage$values"
  }

  // ------------------------------------------------------------------
  // Generic protobuf codec
  // ------------------------------------------------------------------

  private class PbField(
      var number: Int = 0,
      var wire: Int = 0,
      var varint: Long = 0,
      var bytes: Array[Byte] = Array.empty[Byte],
      var chunk: Array[Byte] = Array.empty[Byte]
  )

  private class PbReader(private val buf: Array[Byte]) {
    private var pos = 0

    def varint(): Long = {
      var result = 0L
      var shift = 0
      while (true) {
        if (pos >= buf.length) {
          throw StatusException(Wire.CODE_INVALID_ARGUMENT, "truncated varint")
        }
        val b = buf(pos).toInt & 0xff
        pos += 1
        result = result | ((b & 0x7f).toLong << shift)
        if ((b & 0x80) == 0) {
          return result
        }
        shift += 7
        if (shift >= 70) {
          throw StatusException(Wire.CODE_INVALID_ARGUMENT, "varint too long")
        }
      }
      0L // unreachable
    }

    private def lenBytes(): Array[Byte] = {
      val n = varint().toInt
      if (pos + n > buf.length) {
        throw StatusException(Wire.CODE_INVALID_ARGUMENT, "truncated bytes field")
      }
      val out = buf.slice(pos, pos + n)
      pos += n
      out
    }

    def next(): PbField = {
      if (pos >= buf.length) {
        return null
      }
      val start = pos
      val tag = varint()
      val field = new PbField()
      field.number = (tag >>> 3).toInt
      field.wire = (tag & 7).toInt
      field.wire match {
        case 0 => field.varint = varint()
        case 2 => field.bytes = lenBytes()
        case 1 =>
          if (pos + 8 > buf.length) {
            throw StatusException(Wire.CODE_INVALID_ARGUMENT, "truncated fixed64")
          }
          field.bytes = buf.slice(pos, pos + 8)
          pos += 8
        case 5 =>
          if (pos + 4 > buf.length) {
            throw StatusException(Wire.CODE_INVALID_ARGUMENT, "truncated fixed32")
          }
          field.bytes = buf.slice(pos, pos + 4)
          pos += 4
        case _ => throw StatusException(Wire.CODE_INVALID_ARGUMENT, s"unsupported wire type ${field.wire}")
      }
      field.chunk = buf.slice(start, pos)
      field
    }
  }

  private def asString(field: PbField): String = new String(field.bytes, StandardCharsets.UTF_8)

  private def wireType(fieldType: Int): Int = {
    fieldType match {
      case TYPE_INT64 | TYPE_UINT64 | TYPE_INT32 | TYPE_BOOL | TYPE_UINT32 | TYPE_ENUM | TYPE_SINT32 | TYPE_SINT64 => 0
      case TYPE_FIXED64 | TYPE_SFIXED64 | TYPE_DOUBLE => 1
      case TYPE_STRING | TYPE_BYTES | TYPE_MESSAGE | TYPE_GROUP => 2
      case TYPE_FIXED32 | TYPE_SFIXED32 | TYPE_FLOAT => 5
      case _ => -1
    }
  }

  private def encodeVarint(out: ByteArrayOutputStream, value: Long): Unit = {
    var v = value
    while ((v & -0x80L) != 0L) {
      out.write(((v & 0x7f) | 0x80).toInt)
      v = v >>> 7
    }
    out.write(v.toInt)
  }

  private def zigzagEncode(v: Long): Long = (v << 1) ^ (v >> 63)

  private def zigzagDecode(v: Long): Long = (v >>> 1) ^ -(v & 1)

  private def valueAsLong(value: Any): Long = {
    value match {
      case v: Boolean => if (v) 1L else 0L
      case v: Number => v.longValue
      case _ => 0L
    }
  }

  def encodeGeneric(model: MessageModel, message: GenericMessage, file: FileModel): Array[Byte] = {
    val out = new ByteArrayOutputStream()
    for ((number, values) <- message.values) {
      val field = model.fields.getOrElse(number,
        throw StatusException(Wire.CODE_INVALID_ARGUMENT, s"unknown field $number for ${model.fullName}"))
      if (field.repeated) {
        for (value <- values) {
          encodeValue(out, field, value, file)
        }
      } else if (values.nonEmpty) {
        encodeValue(out, field, values.head, file)
      }
    }
    for (chunk <- message.unknown) {
      out.write(chunk)
    }
    out.toByteArray
  }

  private def encodeValue(out: ByteArrayOutputStream, field: FieldModel, value: Any, file: FileModel): Unit = {
    val wire = wireType(field.fieldType)
    if (wire < 0) {
      throw StatusException(Wire.CODE_INVALID_ARGUMENT, s"unsupported field type ${field.fieldType}")
    }
    encodeVarint(out, (field.number.toLong << 3) | wire.toLong)
    wire match {
      case 0 =>
        var v: Long = 0L
        if (field.fieldType == TYPE_SINT32 || field.fieldType == TYPE_SINT64) {
          v = zigzagEncode(valueAsLong(value))
          if (field.fieldType == TYPE_SINT32) {
            v = v & 0xffffffffL
          }
        } else if (field.fieldType == TYPE_BOOL) {
          v = if (valueAsLong(value) != 0L) 1 else 0
        } else {
          v = valueAsLong(value)
        }
        encodeVarint(out, v)
      case 1 =>
        var v: Long = 0L
        if (field.fieldType == TYPE_DOUBLE) {
          val d = value match { case n: Number => n.doubleValue; case _ => 0.0 }
          v = java.lang.Double.doubleToRawLongBits(d)
        } else {
          v = valueAsLong(value)
        }
        for (i <- 0 until 8) {
          out.write(((v >>> (8 * i)) & 0xff).toInt)
        }
      case 5 =>
        var v: Int = 0
        if (field.fieldType == TYPE_FLOAT) {
          val f = value match { case n: Number => n.floatValue; case _ => 0f }
          v = java.lang.Float.floatToRawIntBits(f)
        } else {
          v = valueAsLong(value).toInt
        }
        for (i <- 0 until 4) {
          out.write((v >>> (8 * i)) & 0xff)
        }
      case _ =>
        val data: Array[Byte] =
          if (field.fieldType == TYPE_STRING && value.isInstanceOf[String]) {
            value.asInstanceOf[String].getBytes(StandardCharsets.UTF_8)
          } else if (field.fieldType == TYPE_MESSAGE && value.isInstanceOf[GenericMessage]) {
            encodeGeneric(file.message(field.typeName), value.asInstanceOf[GenericMessage], file)
          } else if (value.isInstanceOf[Array[Byte]]) {
            value.asInstanceOf[Array[Byte]]
          } else if (value.isInstanceOf[String]) {
            value.asInstanceOf[String].getBytes(StandardCharsets.UTF_8)
          } else {
            throw StatusException(
              Wire.CODE_INVALID_ARGUMENT,
              s"value does not match field ${field.name} type ${field.fieldType}")
          }
        encodeVarint(out, data.length.toLong)
        out.write(data)
    }
  }

  def decodeGeneric(model: MessageModel, data: Array[Byte], file: FileModel): GenericMessage = {
    val message = new GenericMessage(model)
    val reader = new PbReader(data)
    var raw = reader.next()
    while (raw != null) {
      val field = model.fields.getOrElse(raw.number, null)
      if (field == null) {
        // Unknown field: retain the raw encoded chunk verbatim.
        message.unknown += raw.chunk
      } else {
        message.values.getOrElseUpdate(raw.number, scala.collection.mutable.ListBuffer[Any]()) += decodeValue(field, raw, file)
      }
      raw = reader.next()
    }
    message
  }

  private def decodeValue(field: FieldModel, raw: PbField, file: FileModel): Any = {
    raw.wire match {
      case 0 =>
        field.fieldType match {
          case TYPE_BOOL => raw.varint != 0L
          case TYPE_SINT32 | TYPE_SINT64 => zigzagDecode(raw.varint)
          case TYPE_INT32 | TYPE_ENUM => raw.varint.toInt.toLong
          case _ => raw.varint
        }
      case 1 =>
        var v = 0L
        for (i <- 0 until 8) {
          v = v | ((raw.bytes(i).toLong & 0xffL) << (8 * i))
        }
        field.fieldType match {
          case TYPE_DOUBLE => java.lang.Double.longBitsToDouble(v)
          case _ => v
        }
      case 5 =>
        var v = 0
        for (i <- 0 until 4) {
          v = v | ((raw.bytes(i).toInt & 0xff) << (8 * i))
        }
        field.fieldType match {
          case TYPE_FLOAT => java.lang.Float.intBitsToFloat(v).toDouble
          case TYPE_SFIXED32 => v.toLong
          case _ => v.toLong & 0xffffffffL
        }
      case _ =>
        field.fieldType match {
          case TYPE_STRING => new String(raw.bytes, StandardCharsets.UTF_8)
          case TYPE_MESSAGE => decodeGeneric(file.message(field.typeName), raw.bytes, file)
          case _ => raw.bytes
        }
    }
  }

  // ------------------------------------------------------------------
  // Descriptor set parsing
  // ------------------------------------------------------------------

  /** Parse FileDescriptorSet bytes into a FileModel. */
  def parseDescriptorSet(data: Array[Byte]): FileModel = {
    val file = new FileModel()
    val pendingServices = scala.collection.mutable.ListBuffer[(String, Array[Byte])]()
    val reader = new PbReader(data)
    var f = reader.next()
    while (f != null) {
      if (f.number == 1) {
        var pkg = ""
        val messageTypes = scala.collection.mutable.ListBuffer[Array[Byte]]()
        val serviceTypes = scala.collection.mutable.ListBuffer[Array[Byte]]()
        val fr = new PbReader(f.bytes)
        var ff = fr.next()
        while (ff != null) {
          ff.number match {
            case 2 => pkg = asString(ff)
            case 4 => messageTypes += ff.bytes
            case 6 => serviceTypes += ff.bytes
            case _ => ()
          }
          ff = fr.next()
        }
        for (m <- messageTypes) {
          parseMessage(pkg, m, file)
        }
        for (s <- serviceTypes) {
          pendingServices += ((pkg, s))
        }
      }
      f = reader.next()
    }
    for ((pkg, serviceBytes) <- pendingServices) {
      parseService(pkg, serviceBytes, file)
    }
    file
  }

  private def parseMessage(prefix: String, data: Array[Byte], file: FileModel): Unit = {
    var name = ""
    val rawFields = scala.collection.mutable.ListBuffer[Array[Byte]]()
    val nested = scala.collection.mutable.ListBuffer[Array[Byte]]()
    val reader = new PbReader(data)
    var f = reader.next()
    while (f != null) {
      f.number match {
        case 1 => name = asString(f)
        case 2 => rawFields += f.bytes
        case 3 => nested += f.bytes
        case _ => ()
      }
      f = reader.next()
    }
    val fullName = if (prefix.isEmpty) name else s"$prefix.$name"
    val model = new MessageModel(fullName)
    for (fieldBytes <- rawFields) {
      val field = parseField(fieldBytes)
      model.byName(field.name) = field.number
      model.fields(field.number) = field
    }
    file.messages("." + fullName) = model
    for (nestedBytes <- nested) {
      parseMessage(fullName, nestedBytes, file)
    }
  }

  private def parseField(data: Array[Byte]): FieldModel = {
    val field = new FieldModel()
    val reader = new PbReader(data)
    var f = reader.next()
    while (f != null) {
      f.number match {
        case 1 => field.name = asString(f)
        case 3 => field.number = f.varint.toInt
        case 4 => field.repeated = f.varint.toInt == LABEL_REPEATED
        case 5 => field.fieldType = f.varint.toInt
        case 6 => field.typeName = asString(f)
        case _ => ()
      }
      f = reader.next()
    }
    field
  }

  private def kindOf(clientStreaming: Boolean, serverStreaming: Boolean): String = {
    if (clientStreaming && serverStreaming) Server.KIND_BIDI
    else if (serverStreaming) Server.KIND_SERVER_STREAMING
    else if (clientStreaming) Server.KIND_CLIENT_STREAMING
    else Server.KIND_UNARY
  }

  private def parseService(pkg: String, data: Array[Byte], file: FileModel): Unit = {
    var name = ""
    val rawMethods = scala.collection.mutable.ListBuffer[Array[Byte]]()
    val reader = new PbReader(data)
    var f = reader.next()
    while (f != null) {
      f.number match {
        case 1 => name = asString(f)
        case 2 => rawMethods += f.bytes
        case _ => ()
      }
      f = reader.next()
    }
    val fullName = if (pkg.isEmpty) name else s"$pkg.$name"
    val service = new ServiceModel(fullName)
    for (methodBytes <- rawMethods) {
      var mname = ""
      var inputType = ""
      var outputType = ""
      var clientStreaming = false
      var serverStreaming = false
      val mr = new PbReader(methodBytes)
      var mf = mr.next()
      while (mf != null) {
        mf.number match {
          case 1 => mname = asString(mf)
          case 2 => inputType = asString(mf)
          case 3 => outputType = asString(mf)
          case 5 => clientStreaming = mf.varint != 0L
          case 6 => serverStreaming = mf.varint != 0L
          case _ => ()
        }
        mf = mr.next()
      }
      val method = new MethodModel()
      method.name = mname
      method.path = s"/$fullName/$mname"
      method.kind = kindOf(clientStreaming, serverStreaming)
      method.input = file.message(inputType)
      method.output = file.message(outputType)
      service.methods(mname) = method
    }
    file.services(fullName) = service
  }

  // ------------------------------------------------------------------
  // Client / server surfaces
  // ------------------------------------------------------------------

  /** Adapts a (MessageModel, GenericMessage) pair to the Channel
   * marshal/unmarshal contract. */
  private class BoundMessage(
      private val boundModel: MessageModel,
      var generic: GenericMessage,
      private val file: FileModel) extends Marshaler with Unmarshaler {
    def marshalDc(): Array[Byte] = encodeGeneric(boundModel, generic, file)

    def unmarshalDc(data: Array[Byte]): Unit = {
      generic = decodeGeneric(boundModel, data, file)
    }
  }

  /** Runtime-built client: methods resolve from the FileModel. */
  class DynamicClient(private val channel: Channel, private val model: FileModel) {
    private def resolveMethod(serviceName: String, methodName: String): MethodModel = {
      val svc = model.service(serviceName)
      svc.methods.getOrElse(methodName,
        throw StatusException(Wire.CODE_INVALID_ARGUMENT, s"unknown method $serviceName/$methodName"))
    }

    def unary(service: String, method: String, req: GenericMessage, metadata: Map[String, String] = null, timeout: java.time.Duration = null): GenericMessage = {
      val m = resolveMethod(service, method)
      val resp = new BoundMessage(m.output, new GenericMessage(m.output), model)
      channel.unary(m.path, new BoundMessage(m.input, req, model), resp, metadata, timeout)
      resp.generic
    }

    /** Receiving stream of generic responses. */
    class DynamicStream(
        private val stream: Channel#ClientStream,
        private val output: MessageModel,
        private val file: FileModel) {
      /** Next response; EOFException at end. */
      def recv(): GenericMessage = {
        val resp = new BoundMessage(output, new GenericMessage(output), file)
        stream.recv(resp)
        resp.generic
      }

      /** Abandon this stream (RST CANCELLED unless completed). */
      def cancel(): Unit = stream.cancel()

      /** Abandon this stream (RST CANCELLED unless completed). */
      def close(): Unit = stream.close()
    }

    def serverStream(service: String, method: String, req: GenericMessage, metadata: Map[String, String] = null, timeout: java.time.Duration = null): DynamicStream = {
      val m = resolveMethod(service, method)
      new DynamicStream(channel.serverStream(m.path, new BoundMessage(m.input, req, model), metadata, timeout), m.output, model)
    }

    def clientStream(service: String, method: String, reqs: List[GenericMessage], metadata: Map[String, String] = null, timeout: java.time.Duration = null): GenericMessage = {
      val m = resolveMethod(service, method)
      val bound = reqs.map(r => new BoundMessage(m.input, r, model))
      val resp = new BoundMessage(m.output, new GenericMessage(m.output), model)
      channel.clientStreamCall(m.path, bound, resp, metadata, timeout)
      resp.generic
    }

    def bidi(service: String, method: String, reqs: List[GenericMessage], metadata: Map[String, String] = null, timeout: java.time.Duration = null): DynamicStream = {
      val m = resolveMethod(service, method)
      val bound = reqs.map(r => new BoundMessage(m.input, r, model))
      new DynamicStream(channel.bidi(m.path, bound, metadata, timeout), m.output, model)
    }
  }

  /** Receives generic requests; EOFException at half-close. */
  trait RecvFn {
    def recv(): GenericMessage
  }

  /** Sends one generic response. */
  trait SendFn {
    def send(resp: GenericMessage): Unit
  }

  /** Implements a service with generic messages. */
  trait DynamicHandler {
    def unary(ctx: Endpoint#CallContext, method: MethodModel, req: GenericMessage): GenericMessage
    def serverStream(ctx: Endpoint#CallContext, method: MethodModel, req: GenericMessage, send: SendFn): Unit
    def clientStream(ctx: Endpoint#CallContext, method: MethodModel, recv: RecvFn): GenericMessage
    def bidi(ctx: Endpoint#CallContext, method: MethodModel, recv: RecvFn, send: SendFn): Unit
  }

  /** Register a runtime-built service on a Server. */
  def registerDynamicService(server: Server, fileModel: FileModel, serviceName: String, handler: DynamicHandler): Unit = {
    val service = fileModel.service(serviceName)
    val methods = scala.collection.mutable.ListBuffer[Server.Method]()
    for (m <- service.methods.values) {
      methods += Server.Method(m.name, m.path, m.kind, (ctx, reqs, sink) => {
        val recv = new RecvFn {
          def recv(): GenericMessage = decodeGeneric(m.input, reqs.recvRaw(), fileModel)
        }
        val send = new SendFn {
          def send(resp: GenericMessage): Unit = sink.send(encodeGeneric(m.output, resp, fileModel))
        }
        m.kind match {
          case Server.KIND_UNARY => send.send(handler.unary(ctx, m, recv.recv()))
          case Server.KIND_SERVER_STREAMING => handler.serverStream(ctx, m, recv.recv(), send)
          case Server.KIND_CLIENT_STREAMING => send.send(handler.clientStream(ctx, m, recv))
          case _ => handler.bidi(ctx, m, recv, send)
        }
      })
    }
    server.registerService(Server.ServiceDesc(service.fullName, methods.toList))
  }
}
GRPC_RUNTIME_EOF
)

(define (emit-scala-runtime-files)
  (list
   (cons "grpcdc/Status.scala" scala-status-body)
   (cons "grpcdc/Codec.scala" scala-codec-body)
   (cons "grpcdc/Transport.scala" scala-transport-body)
   (cons "grpcdc/Endpoint.scala" scala-endpoint-body)
   (cons "grpcdc/Channel.scala" scala-channel-body)
   (cons "grpcdc/Server.scala" scala-server-body)
   (cons "grpcdc/MemoryTransport.scala" scala-memory-body)
   (cons "grpcdc/SidecarTransport.scala" scala-sidecar-body)
   (cons "grpcdc/Futures.scala" scala-futures-body)
   (cons "grpcdc/Dynamic.scala" scala-dynamic-body)))
