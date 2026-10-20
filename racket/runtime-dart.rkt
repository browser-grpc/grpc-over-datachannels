#lang racket

;;; runtime-dart.rkt — the Dart gRPC runtime, emitted by metagen.rkt.
;;;
;;; The runtime files under dart/grpcdc/ are GENERATED from the
;;; bodies below plus fragments recursively expanded from spec.rkt's
;;; frame/status tables (see the dispatch generator). Do not edit the
;;; generated runtime files; edit here and run `make generate`.
;;; (Bodies were authored in-language and are kept verbatim so the
;;; generated output stays byte-reviewable in git diffs.)
;;;
;;; Dart SDK only (dart:async/convert/io/typed_data) — no pub
;;; packages. Async is Dart-native: Future/Stream throughout, so the
;;; sync/async split other languages need does not arise.

(require "spec.rkt")
(provide emit-dart-runtime-files)

(define dart-status-body
#<<GRPC_RUNTIME_EOF
import 'dart:math';

import 'wire.dart';

/// Observer for homegrown tracing (W3C traceparent propagation).
abstract class Tracer {
  void onStart(
      String kind, String method, String traceId, String spanId, String parentSpanId);
  void onEnd(String kind, String method, String traceId, String spanId, String status);
}

/// One in-flight span's context.
class TraceContext {
  final String traceId;
  final String spanId;
  final String parentSpanId;
  const TraceContext(this.traceId, this.spanId, this.parentSpanId);
}

Tracer? _tracer;

/// Register the global span observer (null disables tracing).
/// Dormant until set: sampling/export are the app's problem.
void setTracer(Tracer? tracer) {
  _tracer = tracer;
}

List<String> _traceFilter = [];

/// Restrict traced methods: ';'-separated paths, a trailing
/// '*' means prefix match ('/echo.Echo/*'). Empty = trace all.
void setTraceFilter(String patterns) {
  _traceFilter = patterns.split(';').where((p) => p.isNotEmpty).toList();
}

bool _traceAllowed(String method) {
  if (_traceFilter.isEmpty) return true;
  for (final p in _traceFilter) {
    if (p.endsWith('*')) {
      if (method.startsWith(p.substring(0, p.length - 1))) return true;
    } else if (method == p) {
      return true;
    }
  }
  return false;
}

bool get tracingEnabled => _tracer != null;

final _rng = Random.secure();

String _randomHex(int bytes) {
  const digits = '0123456789abcdef';
  final out = StringBuffer();
  for (var i = 0; i < bytes; i++) {
    final b = _rng.nextInt(256);
    out.write(digits[b >> 4]);
    out.write(digits[b & 0xf]);
  }
  return out.toString();
}

String formatTraceparent(String traceId, String spanId) =>
    '00-$traceId-$spanId-01';

({String traceId, String spanId})? parseTraceparent(String? value) {
  if (value == null) return null;
  final parts = value.split('-');
  if (parts.length != 4 || parts[1].length != 32 || parts[2].length != 16) {
    return null;
  }
  final hex = RegExp(r'^[0-9a-f]+$');
  if (!hex.hasMatch(parts[1]) || !hex.hasMatch(parts[2])) return null;
  return (traceId: parts[1], spanId: parts[2]);
}

TraceContext? traceStart(
    String kind, String method, ({String traceId, String spanId})? parent) {
  final tracer = _tracer;
  if (tracer == null || !_traceAllowed(method)) return null;
  final ctx = TraceContext(
    parent?.traceId ?? _randomHex(16),
    _randomHex(8),
    parent?.spanId ?? '',
  );
  try {
    tracer.onStart(kind, method, ctx.traceId, ctx.spanId, ctx.parentSpanId);
  } catch (_) {
    // observers must never break the call
  }
  return ctx;
}

void traceEnd(String kind, String method, TraceContext? ctx, String status) {
  final tracer = _tracer;
  if (ctx == null || tracer == null) return;
  try {
    tracer.onEnd(kind, method, ctx.traceId, ctx.spanId, status);
  } catch (_) {
    // observers must never break the call
  }
}

/// Thrown at end of a receiving stream (call completed OK).
class EndOfStreamError implements Exception {
  @override
  String toString() => 'EndOfStreamError';
}

/// A gRPC status (code + message) carried as an exception.
class StatusException implements Exception {
  final int code;
  final String message;

  StatusException(this.code, this.message);

  @override
  String toString() => '${Wire.statusName(code)}: $message';

  /// Convert any error to a StatusException (OK for null).
  static StatusException toStatus(Object? error) {
    if (error == null) {
      return StatusException(Wire.codeOk, '');
    }
    if (error is StatusException) {
      return error;
    }
    return StatusException(Wire.codeInternal, error.toString());
  }
}
GRPC_RUNTIME_EOF
)

(define dart-codec-body
#<<GRPC_RUNTIME_EOF
import 'dart:convert';
import 'dart:typed_data';

import 'status.dart';
import 'wire.dart';

/// Parsed HEADERS payload: path == null means response headers.
typedef Headers = ({String? path, Map<String, String> metadata});

/// Frame codec for gRPC over WebRTC DataChannels (wire protocol in
/// ../SPEC.md). Frame, status, channel and server semantics mirror the
/// other grpcdc runtimes; the tables in wire.dart are stamped by the
/// Racket metaprogram.
class Codec {
  static const int headerLen = 9;
  static const int maxDataPayload = 16 * 1024 * 1024;

  /// One parsed frame.
  static ({
    int type,
    int streamId,
    Uint8List payload,
  }) decodeFrame(Uint8List data) {
    if (data.length < headerLen) {
      throw StatusException(Wire.codeInvalidArgument,
          'frame shorter than 9-byte header: ${data.length} bytes');
    }
    final length = getU32(data, 5);
    if (length != data.length - headerLen) {
      throw StatusException(Wire.codeInvalidArgument,
          'payload length $length does not match message size ${data.length}');
    }
    return (
      type: data[0],
      streamId: getU32(data, 1),
      payload: Uint8List.sublistView(data, headerLen),
    );
  }

  /// Build one DataChannel message: header + payload.
  static Uint8List encodeFrame(int frameType, int streamId, List<int> payload) {
    if (!Wire.isFrameType(frameType)) {
      throw StatusException(
          Wire.codeInvalidArgument, 'unknown frame type $frameType');
    }
    if (frameType == Wire.frameData && payload.length > maxDataPayload) {
      throw StatusException(
          Wire.codeResourceExhausted, 'DATA payload exceeds 16 MiB');
    }
    final out = Uint8List(headerLen + payload.length);
    out[0] = frameType;
    putU32(out, 1, streamId);
    putU32(out, 5, payload.length);
    out.setRange(headerLen, out.length, payload);
    return out;
  }

  static void putU32(Uint8List out, int offset, int value) {
    out[offset] = (value >> 24) & 0xff;
    out[offset + 1] = (value >> 16) & 0xff;
    out[offset + 2] = (value >> 8) & 0xff;
    out[offset + 3] = value & 0xff;
  }

  static int getU32(Uint8List input, int offset) {
    return (input[offset] << 24) |
        (input[offset + 1] << 16) |
        (input[offset + 2] << 8) |
        input[offset + 3];
  }

  static Headers parseHeaders(List<int> payload) {
    Object? root;
    try {
      root = jsonDecode(utf8.decode(payload));
    } catch (e) {
      throw StatusException(
          Wire.codeInvalidArgument, 'bad HEADERS payload: $e');
    }
    if (root is! Map) {
      throw StatusException(
          Wire.codeInvalidArgument, 'bad HEADERS payload: not an object');
    }
    final metadata = <String, String>{};
    final md = root['metadata'];
    if (md is Map) {
      for (final entry in md.entries) {
        metadata[entry.key.toString()] = entry.value.toString();
      }
    }
    final path = root['path'];
    return (path: path is String ? path : null, metadata: metadata);
  }

  static Uint8List headersFrame(
      int streamId, String? path, Map<String, String>? metadata) {
    final body = <String, Object?>{};
    if (path != null) {
      body['path'] = path;
    }
    if (metadata != null && metadata.isNotEmpty) {
      body['metadata'] = metadata;
    }
    return encodeFrame(
        Wire.frameHeaders, streamId, utf8.encode(jsonEncode(body)));
  }

  /// gRPC timeout grammar (grpc-timeout metadata): <digits><unit>,
  /// units H/M/S/m/u/n (at most 8 digits). Encoding uses
  /// milliseconds (seconds past the digit limit), rounded up.
  static String encodeTimeout(Duration timeout) {
    var ms = timeout.inMilliseconds;
    if (timeout - Duration(milliseconds: ms) > Duration.zero) ms++;
    if (ms <= 99999999) return '${ms}m';
    var secs = timeout.inSeconds;
    if (timeout - Duration(seconds: secs) > Duration.zero) secs++;
    return '${secs}S';
  }

  /// Decoded grpc-timeout, or null when malformed/absent.
  static Duration? parseTimeout(String? text) {
    if (text == null || text.length < 2 || text.length > 9) return null;
    final digits = text.substring(0, text.length - 1);
    final n = int.tryParse(digits);
    if (n == null) return null;
    switch (text[text.length - 1]) {
      case 'H':
        return Duration(hours: n);
      case 'M':
        return Duration(minutes: n);
      case 'S':
        return Duration(seconds: n);
      case 'm':
        return Duration(milliseconds: n);
      case 'u':
        return Duration(microseconds: n);
      case 'n':
        return Duration(microseconds: (n + 999) ~/ 1000);
      default:
        return null;
    }
  }

  static Uint8List statusFrame(
      int frameType, int streamId, StatusException status) {
    final body = jsonEncode({'code': status.code, 'message': status.message});
    return encodeFrame(frameType, streamId, utf8.encode(body));
  }

  static StatusException parseStatus(List<int> payload) {
    try {
      final root = jsonDecode(utf8.decode(payload));
      if (root is Map && root['code'] is num) {
        return StatusException(
            (root['code'] as num).toInt(), root['message']?.toString() ?? '');
      }
    } catch (_) {
      // fall through to malformed
    }
    return StatusException(Wire.codeUnknown, 'malformed trailers');
  }
}
GRPC_RUNTIME_EOF
)

(define dart-transport-body
#<<GRPC_RUNTIME_EOF
import 'dart:typed_data';

/// Carries whole DataChannel messages: one send is one message,
/// boundaries preserved, ordered and reliable — the contract an
/// RTCDataChannel (or the loopback pair) offers. Inbound messages
/// arrive on [onMessage]; the stream completing means the transport
/// closed.
abstract class Transport {
  Stream<Uint8List> get onMessage;
  void send(Uint8List data);
  Future<void> close();
}

/// Implemented by hand-written protobuf message types.
abstract class Marshaler {
  Uint8List marshalDc();
}

/// Implemented by hand-written protobuf message types.
abstract class Unmarshaler {
  void unmarshalDc(List<int> data);
}
GRPC_RUNTIME_EOF
)

(define dart-endpoint-body
#<<GRPC_RUNTIME_EOF
import 'dart:async';
import 'dart:typed_data';

import 'codec.dart';
import 'status.dart';
import 'transport.dart';
import 'wire.dart';

/// Stream event kinds delivered to StreamInput queues.
enum EventKind { headers, data, halfClose, trailers, rst }

class StreamEvent {
  final EventKind kind;
  final Headers? headers;
  final Uint8List? payload;
  final StatusException? status;

  StreamEvent(this.kind, {this.headers, this.payload, this.status});
}

/// Receiving queue of one stream; closed after a terminal event.
class StreamInput {
  final _items = <StreamEvent>[];
  final _waiters = <Completer<StreamEvent?>>[];
  bool _closed = false;

  void put(StreamEvent event) {
    if (_closed) return;
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete(event);
    } else {
      _items.add(event);
    }
  }

  void close() {
    _closed = true;
    for (final waiter in _waiters) {
      waiter.complete(null);
    }
    _waiters.clear();
  }

  /// Next event, or null once the stream is closed and drained.
  Future<StreamEvent?> get() {
    if (_items.isNotEmpty) {
      return Future.value(_items.removeAt(0));
    }
    if (_closed) {
      return Future.value(null);
    }
    final completer = Completer<StreamEvent?>();
    _waiters.add(completer);
    return completer.future;
  }
}

/// Per-call context: metadata sent in HEADERS.
class CallContext {
  final Map<String, String> metadata;

  /// Deadline propagated via grpc-timeout, when the client set one.
  final DateTime? deadline;

  CallContext(this.metadata)
      : deadline = Codec.parseTimeout(metadata['grpc-timeout']) == null
            ? null
            : DateTime.now().add(Codec.parseTimeout(metadata['grpc-timeout'])!);

  /// Time left before the deadline, or null when unbounded.
  Duration? timeRemaining() {
    if (deadline == null) return null;
    final left = deadline!.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  bool get deadlineExceeded => timeRemaining() == Duration.zero;
}

/// Sends response payloads of one inbound call.
class ResponseSink {
  final Endpoint _endpoint;
  final int _streamId;

  ResponseSink(this._endpoint, this._streamId);

  void send(List<int> payload) {
    _endpoint.sendFrame(Codec.encodeFrame(Wire.frameData, _streamId, payload));
  }

  void sendHeaders() {
    _endpoint.sendFrame(Codec.headersFrame(_streamId, null, null));
  }

  void sendTrailers(StatusException status) {
    _endpoint.sendFrame(Codec.statusFrame(Wire.frameTrailers, _streamId, status));
  }
}

/// Server-side call handler installed by Server.
/// Returns the status that becomes the call's TRAILERS (null = OK).
typedef Dispatcher = Future<StatusException?> Function(
    CallContext ctx, Headers headers, StreamInput input, ResponseSink sink);

/// Multiplexes grpc-dc streams over one Transport.
class Endpoint {
  final Transport _transport;
  Dispatcher? dispatcher;
  int _nextId;
  final _streams = <int, StreamInput>{};
  bool _closed = false;
  bool _started = false;
  StreamSubscription<Uint8List>? _subscription;

  /// The side that created the channel allocates odd stream ids, the
  /// answerer even. The read loop starts on [start] — after any
  /// dispatcher is installed, so an early HEADERS can never race
  /// dispatcher setup.
  Endpoint(this._transport, {required bool creator}) : _nextId = creator ? 1 : 2;

  /// Start the read loop (idempotent).
  void start() {
    if (_started) return;
    _started = true;
    _subscription = _transport.onMessage.listen(
      _onBytes,
      onError: (_) => _failAll(),
      onDone: () => _failAll(),
    );
  }

  void sendFrame(Uint8List frame) {
    _transport.send(frame);
  }

  ({int id, StreamInput input}) openStream() {
    final id = _nextId;
    _nextId += 2;
    final input = StreamInput();
    _streams[id] = input;
    return (id: id, input: input);
  }

  void closeStream(int id) {
    _streams.remove(id);
  }

  /// Abort one stream: RST out; a pending recv wakes with CANCELLED.
  void cancelStream(int id) {
    final input = _streams.remove(id);
    if (input != null) {
      input.put(StreamEvent(EventKind.rst,
          status: StatusException(Wire.codeCancelled, 'call cancelled')));
      input.close();
    }
    try {
      sendFrame(Codec.statusFrame(Wire.frameRst, id,
          StatusException(Wire.codeCancelled, 'call cancelled')));
    } catch (_) {
      // Transport already gone; the local abort still stands.
    }
  }

  StreamInput? _stream(int id) => _streams[id];

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _subscription?.cancel();
    await _transport.close();
    _failAll();
  }

  void _failAll() {
    final streams = _streams.values.toList();
    _streams.clear();
    for (final input in streams) {
      input.put(StreamEvent(EventKind.rst,
          status: StatusException(Wire.codeUnavailable, 'data channel closed')));
      input.close();
    }
  }

  void _onBytes(Uint8List data) {
    if (_closed) return;
    final frame = _tryDecode(data);
    if (frame == null) return; // malformed frame: drop, keep the channel up
    final frameType = frame.type;
    final streamId = frame.streamId;
    final payload = frame.payload;
@@FRAME_DISPATCH@@

  }

  ({int type, int streamId, Uint8List payload})? _tryDecode(Uint8List data) {
    try {
      return Codec.decodeFrame(data);
    } on StatusException {
      return null;
    }
  }

  void _onTerminal(int streamId, Uint8List payload, EventKind kind) {
    final input = _stream(streamId);
    if (input != null) {
      input.put(StreamEvent(kind, status: Codec.parseStatus(payload)));
      input.close();
      closeStream(streamId);
    }
  }

  void _pushEvent(int streamId, StreamEvent event) {
    _stream(streamId)?.put(event);
  }

  Future<void> _onHeaders(int streamId, Uint8List payload) async {
    final Headers headers;
    try {
      headers = Codec.parseHeaders(payload);
    } on StatusException catch (e) {
      try {
        sendFrame(Codec.statusFrame(Wire.frameRst, streamId, e));
      } catch (_) {
        // best effort
      }
      return;
    }
    if (headers.path == null) {
      // Server response headers for one of our outbound streams.
      _stream(streamId)?.put(StreamEvent(EventKind.headers, headers: headers));
      return;
    }
    if (_stream(streamId) != null) {
      try {
        sendFrame(Codec.statusFrame(
            Wire.frameRst,
            streamId,
            StatusException(
                Wire.codeInternal, 'HEADERS for stream already in use')));
      } catch (_) {
        // best effort
      }
      return;
    }
    final currentDispatcher = dispatcher;
    if (currentDispatcher == null) {
      try {
        sendFrame(Codec.statusFrame(Wire.frameTrailers, streamId,
            StatusException(Wire.codeUnimplemented, 'unknown method ${headers.path}')));
      } catch (_) {
        // best effort
      }
      return;
    }
    final input = StreamInput();
    _streams[streamId] = input;
    final sink = ResponseSink(this, streamId);
    try {
      try {
        sink.sendHeaders();
      } catch (_) {
        return;
      }
      StatusException status;
      try {
        status = await currentDispatcher(
                CallContext(headers.metadata), headers, input, sink) ??
            StatusException(Wire.codeOk, '');
      } catch (e) {
        status = StatusException.toStatus(e);
      }
      try {
        sink.sendTrailers(status);
      } catch (_) {
        // best effort
      }
    } finally {
      closeStream(streamId);
    }
  }
}
GRPC_RUNTIME_EOF
)

(define dart-channel-body
#<<GRPC_RUNTIME_EOF
import 'dart:async';
import 'dart:typed_data';

import 'codec.dart';
import 'endpoint.dart';
import 'status.dart';
import 'transport.dart';
import 'wire.dart';

/// Receives response messages of one call.
class ClientStream {
  final int streamId;
  final Endpoint _endpoint;
  final StreamInput _input;
  Headers? headers;
  DateTime? deadline;
  TraceContext? traceCtx;
  String? tracePath;
  bool _traceEnded = false;

  ClientStream(this.streamId, this._endpoint, this._input);

  void endTrace(String status) {
    if (!_traceEnded) {
      _traceEnded = true;
      traceEnd('client', tracePath ?? '', traceCtx, status);
    }
  }

  /// Abort this stream (sends RST, wakes a pending recv).
  void cancel() => _endpoint.cancelStream(streamId);

  /// Decode the next response into resp. EndOfStreamError means the
  /// call completed OK; StatusException reports the trailers status.
  Future<void> recv(Unmarshaler resp) async {
    while (true) {
      final StreamEvent? event;
      if (deadline != null) {
        try {
          event = await _input
              .get()
              .timeout(deadline!.difference(DateTime.now()));
        } on TimeoutException {
          _endpoint.cancelStream(streamId);
          throw StatusException(
              Wire.codeDeadlineExceeded, 'deadline exceeded');
        }
      } else {
        event = await _input.get();
      }
      if (event == null) {
        throw StatusException(Wire.codeUnavailable, 'data channel closed');
      }
      switch (event.kind) {
        case EventKind.headers:
          headers = event.headers;
          break;
        case EventKind.data:
          resp.unmarshalDc(event.payload!);
          return;
        case EventKind.trailers:
          final status = event.status;
          endTrace(Wire.statusName(status?.code ?? Wire.codeOk));
          if (status != null && status.code != Wire.codeOk) {
            throw status;
          }
          throw EndOfStreamError();
        case EventKind.rst:
          final status =
              event.status ?? StatusException(Wire.codeUnavailable, 'stream reset');
          endTrace(Wire.statusName(status.code));
          throw status;
        default:
          break;
      }
    }
  }
}

/// Channel: the client side of one Endpoint.
class Channel {
  final Endpoint endpoint;

  /// Wrap a transport, allocating odd stream ids.
  Channel(Transport transport) : endpoint = Endpoint(transport, creator: true) {
    endpoint.start();
  }

  /// Wrap an existing endpoint (bidirectional use; starts its read loop).
  Channel.fromEndpoint(this.endpoint) {
    endpoint.start();
  }

  Future<ClientStream> _open(String path, Map<String, String>? metadata,
      {Duration? timeout}) async {
    DateTime? deadline;
    TraceContext? traceCtx;
    if (timeout != null || tracingEnabled) {
      metadata = {if (metadata != null) ...metadata};
      if (timeout != null) {
        deadline = DateTime.now().add(timeout);
        metadata['grpc-timeout'] = Codec.encodeTimeout(timeout);
      }
      if (tracingEnabled) {
        traceCtx = traceStart('client', path, parseTraceparent(metadata['traceparent']));
        if (traceCtx != null) {
          metadata['traceparent'] =
              formatTraceparent(traceCtx.traceId, traceCtx.spanId);
        }
      }
    }
    final opened = endpoint.openStream();
    try {
      endpoint.sendFrame(Codec.headersFrame(opened.id, path, metadata));
    } catch (_) {
      endpoint.closeStream(opened.id);
      traceEnd('client', path, traceCtx, 'UNAVAILABLE');
      rethrow;
    }
    final stream = ClientStream(opened.id, endpoint, opened.input);
    stream.deadline = deadline;
    stream.traceCtx = traceCtx;
    stream.tracePath = path;
    return stream;
  }

  void _sendMessage(ClientStream stream, Marshaler msg) {
    endpoint.sendFrame(
        Codec.encodeFrame(Wire.frameData, stream.streamId, msg.marshalDc()));
  }

  void _halfClose(ClientStream stream) {
    endpoint.sendFrame(
        Codec.encodeFrame(Wire.frameHalfClose, stream.streamId, Uint8List(0)));
  }

  void _sendAll(ClientStream stream, List<Marshaler> reqs) {
    for (final req in reqs) {
      _sendMessage(stream, req);
    }
    _halfClose(stream);
  }

  Future<void> _collectOne(ClientStream stream, Unmarshaler resp, String what) async {
    var got = false;
    while (true) {
      try {
        await stream.recv(resp);
      } on EndOfStreamError {
        if (!got) {
          throw StatusException(
              Wire.codeInternal, 'call closed with no response');
        }
        return;
      }
      if (got) {
        throw StatusException(
            Wire.codeInternal, '$what received more than one response');
      }
      got = true;
    }
  }

  /// Run a unary call, decoding the single response into resp.
  Future<void> unary(String path, Marshaler req, Unmarshaler resp,
      {Map<String, String>? metadata, Duration? timeout}) async {
    final stream = await _open(path, metadata, timeout: timeout);
    try {
      _sendMessage(stream, req);
      _halfClose(stream);
      await _collectOne(stream, resp, 'unary call');
    } finally {
      endpoint.closeStream(stream.streamId);
    }
  }

  /// Start a server-streaming call.
  Future<ClientStream> serverStream(String path, Marshaler req,
      {Map<String, String>? metadata, Duration? timeout}) async {
    final stream = await _open(path, metadata, timeout: timeout);
    _sendMessage(stream, req);
    _halfClose(stream);
    return stream;
  }

  /// Send all requests, then decode the one response into resp.
  Future<void> clientStreamCall(String path, List<Marshaler> reqs,
      Unmarshaler resp,
      {Map<String, String>? metadata, Duration? timeout}) async {
    final stream = await _open(path, metadata, timeout: timeout);
    try {
      _sendAll(stream, reqs);
      await _collectOne(stream, resp, 'client-streaming call');
    } finally {
      endpoint.closeStream(stream.streamId);
    }
  }

  /// Start a bidi call with all requests sent up front.
  Future<ClientStream> bidi(String path, List<Marshaler> reqs,
      {Map<String, String>? metadata, Duration? timeout}) async {
    final stream = await _open(path, metadata, timeout: timeout);
    _sendAll(stream, reqs);
    return stream;
  }
}
GRPC_RUNTIME_EOF
)

(define dart-server-body
#<<GRPC_RUNTIME_EOF
import 'dart:async';
import 'dart:typed_data';

import 'codec.dart';
import 'endpoint.dart';
import 'status.dart';
import 'transport.dart';
import 'wire.dart';

/// Reads request messages of one inbound call.
class RequestStream {
  final StreamInput _input;

  RequestStream(this._input);

  /// Next request payload; EndOfStreamError at half-close.
  Future<Uint8List> recvRaw() async {
    while (true) {
      final event = await _input.get();
      if (event == null) {
        throw StatusException(Wire.codeUnavailable, 'data channel closed');
      }
      switch (event.kind) {
        case EventKind.data:
          return event.payload!;
        case EventKind.halfClose:
          throw EndOfStreamError();
        case EventKind.trailers:
        case EventKind.rst:
          throw event.status ??
              StatusException(Wire.codeUnavailable, 'stream closed');
        default:
          break; // ignore HEADERS on the request side
      }
    }
  }

  /// Decode the next request message into req.
  Future<void> recvInto(Unmarshaler req) async {
    req.unmarshalDc(await recvRaw());
  }
}

/// Sends response payloads of one inbound call.
typedef ServerSink = void Function(List<int> payload);

/// Implements one method against raw payloads; stubs adapt it.
typedef MethodHandler = Future<void> Function(
    CallContext ctx, RequestStream reqs, ServerSink sink);

/// One entry of a ServiceDesc.
class Method {
  final String name;
  final String path;
  final String kind;
  final MethodHandler handler;

  Method(this.name, this.path, this.kind, this.handler);
}

/// Describes a service for Server.registerService.
class ServiceDesc {
  final String name;
  final List<Method> methods;

  ServiceDesc(this.name, this.methods);
}

/// Server: dispatches inbound calls to registered methods.
class Server {
  static const String kindUnary = 'unary';
  static const String kindServerStreaming = 'server-streaming';
  static const String kindClientStreaming = 'client-streaming';
  static const String kindBidi = 'bidi';

  final _methods = <String, Method>{};
  Endpoint? _endpoint;

  /// The endpoint this server is attached to (retained so it
  /// outlives serveEndpoint; read loops keep it alive regardless).
  Endpoint? get endpoint => _endpoint;

  /// Adds a service's methods (generated code calls it).
  void registerService(ServiceDesc desc) {
    for (final method in desc.methods) {
      _methods[method.path] = method;
    }
  }

  /// Attach to a transport (even stream ids); returns the Endpoint.
  Endpoint serveTransport(Transport transport) {
    final endpoint = Endpoint(transport, creator: false);
    serveEndpoint(endpoint);
    return endpoint;
  }

  /// Attach to an existing endpoint (starts its read loop).
  void serveEndpoint(Endpoint endpoint) {
    _endpoint = endpoint;
    endpoint.dispatcher = _dispatch;
    endpoint.start();
  }

  Future<StatusException?> _dispatch(CallContext ctx, Headers headers,
      StreamInput input, ResponseSink sink) async {
    final method = _methods[headers.path];
    if (method == null) {
      return StatusException(
          Wire.codeUnimplemented, 'unknown method ${headers.path}');
    }
    final traceCtx = traceStart('server', headers.path ?? '',
        parseTraceparent(headers.metadata['traceparent']));
    StatusException? result;
    try {
      await method.handler(ctx, RequestStream(input), sink.send);
    } catch (e) {
      result = StatusException.toStatus(e);
    }
    traceEnd('server', headers.path ?? '', traceCtx,
        result == null ? 'OK' : Wire.statusName(result.code));
    return result;
  }
}
GRPC_RUNTIME_EOF
)

(define dart-loopback-body
#<<GRPC_RUNTIME_EOF
import 'dart:async';
import 'dart:typed_data';

import 'status.dart';
import 'transport.dart';

class _MemoryTransport implements Transport {
  final StreamController<Uint8List> _inbox;
  final StreamController<Uint8List> _outbox;
  bool _closed = false;

  _MemoryTransport(this._inbox, this._outbox);

  @override
  Stream<Uint8List> get onMessage => _inbox.stream;

  @override
  void send(Uint8List data) {
    if (_closed) {
      throw EndOfStreamError();
    }
    _outbox.add(Uint8List.fromList(data));
  }

  @override
  Future<void> close() async {
    _closed = true;
    await _inbox.close();
  }
}

/// In-memory transport pair for tests (one queue per direction).
(Transport, Transport) memoryTransportPair() {
  final aToB = StreamController<Uint8List>();
  final bToA = StreamController<Uint8List>();
  return (
    _MemoryTransport(bToA, aToB),
    _MemoryTransport(aToB, bToA),
  );
}
GRPC_RUNTIME_EOF
)

(define dart-dynamic-body
#<<GRPC_RUNTIME_EOF
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'channel.dart';
import 'endpoint.dart';
import 'server.dart';
import 'status.dart';
import 'transport.dart';
import 'wire.dart';

// FieldDescriptorProto.Type values (descriptor.proto).
const int typeDouble = 1;
const int typeFloat = 2;
const int typeInt64 = 3;
const int typeUint64 = 4;
const int typeInt32 = 5;
const int typeFixed64 = 6;
const int typeFixed32 = 7;
const int typeBool = 8;
const int typeString = 9;
const int typeGroup = 10;
const int typeMessage = 11;
const int typeBytes = 12;
const int typeUint32 = 13;
const int typeEnum = 14;
const int typeSfixed32 = 15;
const int typeSfixed64 = 16;
const int typeSint32 = 17;
const int typeSint64 = 18;

const int _labelRepeated = 3;

class FieldModel {
  int number = 0;
  String name = '';
  int type = 0;
  bool repeated = false;
  String typeName = ''; // for typeMessage, e.g. ".echo.EchoRequest"
}

class MessageModel {
  final String fullName;
  final fields = <int, FieldModel>{};
  final byName = <String, int>{};

  MessageModel(this.fullName);
}

class MethodModel {
  String name = '';
  String path = '';
  String kind = '';
  MessageModel? input;
  MessageModel? output;
}

class ServiceModel {
  final String fullName;
  final methods = <String, MethodModel>{};

  ServiceModel(this.fullName);
}

/// Parsed descriptor set: messages and services by full name.
/// Message keys carry the leading dot (".echo.EchoRequest"), matching
/// FieldDescriptorProto.type_name; service keys do not ("echo.Echo").
class FileModel {
  final messages = <String, MessageModel>{};
  final services = <String, ServiceModel>{};

  MessageModel message(String fullName) {
    final model = messages[fullName];
    if (model == null) {
      throw StatusException(
          Wire.codeInvalidArgument, 'unknown message $fullName');
    }
    return model;
  }

  ServiceModel service(String fullName) {
    final svc = services[fullName];
    if (svc == null) {
      throw StatusException(
          Wire.codeInvalidArgument, 'unknown service $fullName');
    }
    return svc;
  }
}

/// A message as field number -> list of values (descriptor order).
///
/// Generic values: varint family -> int/bool, string -> String,
/// bytes/message -> Uint8List / GenericMessage, fixed/float ->
/// int / double.
///
/// Fields not in the model are retained as raw encoded chunks in
/// [unknown] (protobuf unknown-field retention): a decode -> encode
/// round trip re-emits them after the known fields, so intermediate
/// hops do not strip newer fields.
class GenericMessage {
  final MessageModel? model;
  final values = <int, List<Object?>>{};
  final unknown = <Uint8List>[];

  GenericMessage([this.model]);

  GenericMessage set(int number, Object? value) {
    values[number] = [value];
    return this;
  }

  GenericMessage add(int number, Object? value) {
    values.putIfAbsent(number, () => []).add(value);
    return this;
  }

  Object? get(int number) {
    final list = values[number];
    return (list == null || list.isEmpty) ? null : list[0];
  }

  String getString(int number) {
    final v = get(number);
    return v is String ? v : '';
  }

  int getInt(int number) {
    final v = get(number);
    if (v is bool) return v ? 1 : 0;
    if (v is num) return v.toInt();
    return 0;
  }

  @override
  String toString() => 'GenericMessage$values';
}

// ---------------------------------------------------------------------------
// Generic protobuf codec
// ---------------------------------------------------------------------------

class _PbField {
  int number = 0;
  int wire = 0;
  int varint = 0;
  Uint8List bytes = Uint8List(0);
  Uint8List chunk = Uint8List(0);
}

class _PbReader {
  final Uint8List buf;
  int pos = 0;

  _PbReader(this.buf);

  int varint() {
    var result = 0;
    var shift = 0;
    while (true) {
      if (pos >= buf.length) {
        throw StatusException(Wire.codeInvalidArgument, 'truncated varint');
      }
      final b = buf[pos++];
      result |= (b & 0x7f) << shift;
      if (b & 0x80 == 0) return result;
      shift += 7;
      if (shift >= 70) {
        throw StatusException(Wire.codeInvalidArgument, 'varint too long');
      }
    }
  }

  Uint8List lenBytes() {
    final n = varint();
    if (pos + n > buf.length) {
      throw StatusException(Wire.codeInvalidArgument, 'truncated bytes field');
    }
    final out = Uint8List.sublistView(buf, pos, pos + n);
    pos += n;
    return Uint8List.fromList(out);
  }

  _PbField? next() {
    if (pos >= buf.length) return null;
    final start = pos;
    final tag = varint();
    final field = _PbField();
    field.number = tag >> 3;
    field.wire = tag & 7;
    switch (field.wire) {
      case 0:
        field.varint = varint();
        break;
      case 2:
        field.bytes = lenBytes();
        break;
      case 1:
        if (pos + 8 > buf.length) {
          throw StatusException(Wire.codeInvalidArgument, 'truncated fixed64');
        }
        field.bytes = Uint8List.fromList(buf.sublist(pos, pos + 8));
        pos += 8;
        break;
      case 5:
        if (pos + 4 > buf.length) {
          throw StatusException(Wire.codeInvalidArgument, 'truncated fixed32');
        }
        field.bytes = Uint8List.fromList(buf.sublist(pos, pos + 4));
        pos += 4;
        break;
      default:
        throw StatusException(
            Wire.codeInvalidArgument, 'unsupported wire type ${field.wire}');
    }
    field.chunk = Uint8List.fromList(buf.sublist(start, pos));
    return field;
  }
}

String _asString(_PbField field) => utf8.decode(field.bytes);

int _wireType(int type) {
  switch (type) {
    case typeInt64:
    case typeUint64:
    case typeInt32:
    case typeBool:
    case typeUint32:
    case typeEnum:
    case typeSint32:
    case typeSint64:
      return 0;
    case typeFixed64:
    case typeSfixed64:
    case typeDouble:
      return 1;
    case typeString:
    case typeBytes:
    case typeMessage:
    case typeGroup:
      return 2;
    case typeFixed32:
    case typeSfixed32:
    case typeFloat:
      return 5;
    default:
      return -1;
  }
}

void _encodeVarint(BytesBuilder out, int value) {
  var v = value;
  while ((v & ~0x7f) != 0) {
    out.addByte((v & 0x7f) | 0x80);
    v >>= 7;
  }
  out.addByte(v & 0xff);
}

int _zigzagEncode(int v) => (v << 1) ^ (v >> 63);
int _zigzagDecode(int v) => (v >> 1) ^ -(v & 1);

int _valueAsInt(Object? value) {
  if (value is bool) return value ? 1 : 0;
  if (value is num) return value.toInt();
  return 0;
}

Uint8List encodeGeneric(
    MessageModel model, GenericMessage message, FileModel file) {
  final out = BytesBuilder();
  final numbers = message.values.keys.toList()..sort();
  for (final number in numbers) {
    final field = model.fields[number];
    if (field == null) {
      throw StatusException(Wire.codeInvalidArgument,
          'unknown field $number for ${model.fullName}');
    }
    final values = message.values[number]!;
    if (field.repeated) {
      for (final value in values) {
        _encodeValue(out, field, value, file);
      }
    } else if (values.isNotEmpty) {
      _encodeValue(out, field, values[0], file);
    }
  }
  for (final chunk in message.unknown) {
    out.add(chunk);
  }
  return out.toBytes();
}

void _encodeValue(
    BytesBuilder out, FieldModel field, Object? value, FileModel file) {
  final wire = _wireType(field.type);
  if (wire < 0) {
    throw StatusException(
        Wire.codeInvalidArgument, 'unsupported field type ${field.type}');
  }
  _encodeVarint(out, (field.number << 3) | wire);
  switch (wire) {
    case 0:
      int v;
      if (field.type == typeSint32 || field.type == typeSint64) {
        v = _zigzagEncode(_valueAsInt(value));
        if (field.type == typeSint32) v &= 0xffffffff;
      } else if (field.type == typeBool) {
        v = _valueAsInt(value) != 0 ? 1 : 0;
      } else {
        v = _valueAsInt(value);
      }
      _encodeVarint(out, v);
      break;
    case 1:
      int v;
      if (field.type == typeDouble) {
        final d = value is num ? value.toDouble() : 0.0;
        final bd = ByteData(8)..setFloat64(0, d, Endian.little);
        v = bd.getInt64(0, Endian.little);
      } else {
        v = _valueAsInt(value);
      }
      for (var i = 0; i < 8; i++) {
        out.addByte((v >> (8 * i)) & 0xff);
      }
      break;
    case 5:
      int v;
      if (field.type == typeFloat) {
        final f = value is num ? value.toDouble() : 0.0;
        final bd = ByteData(4)..setFloat32(0, f, Endian.little);
        v = bd.getInt32(0, Endian.little);
      } else {
        v = _valueAsInt(value) & 0xffffffff;
      }
      for (var i = 0; i < 4; i++) {
        out.addByte((v >> (8 * i)) & 0xff);
      }
      break;
    default:
      final Uint8List data;
      if (field.type == typeString && value is String) {
        data = Uint8List.fromList(utf8.encode(value));
      } else if (field.type == typeMessage && value is GenericMessage) {
        data = encodeGeneric(file.message(field.typeName), value, file);
      } else if (value is Uint8List) {
        data = value;
      } else if (value is String) {
        data = Uint8List.fromList(utf8.encode(value));
      } else {
        throw StatusException(Wire.codeInvalidArgument,
            'value does not match field ${field.name} type ${field.type}');
      }
      _encodeVarint(out, data.length);
      out.add(data);
      break;
  }
}

GenericMessage decodeGeneric(
    MessageModel model, List<int> data, FileModel file) {
  final message = GenericMessage(model);
  final reader = _PbReader(Uint8List.fromList(data));
  while (true) {
    final raw = reader.next();
    if (raw == null) break;
    final field = model.fields[raw.number];
    if (field == null) {
      // Unknown field: retain the raw encoded chunk verbatim.
      message.unknown.add(raw.chunk);
      continue;
    }
    message.values.putIfAbsent(raw.number, () => []).add(_decodeValue(field, raw, file));
  }
  return message;
}

Object? _decodeValue(FieldModel field, _PbField raw, FileModel file) {
  switch (raw.wire) {
    case 0:
      if (field.type == typeBool) return raw.varint != 0;
      if (field.type == typeSint32 || field.type == typeSint64) {
        return _zigzagDecode(raw.varint);
      }
      if (field.type == typeInt32 || field.type == typeEnum) {
        return raw.varint.toSigned(32);
      }
      return raw.varint;
    case 1:
      var v = 0;
      for (var i = 0; i < 8; i++) {
        v |= raw.bytes[i] << (8 * i);
      }
      if (field.type == typeDouble) {
        final bd = ByteData(8)..setInt64(0, v, Endian.little);
        return bd.getFloat64(0, Endian.little);
      }
      return v;
    case 5:
      var v = 0;
      for (var i = 0; i < 4; i++) {
        v |= raw.bytes[i] << (8 * i);
      }
      if (field.type == typeFloat) {
        final bd = ByteData(4)..setInt32(0, v.toSigned(32), Endian.little);
        return bd.getFloat32(0, Endian.little).toDouble();
      }
      return v;
    default:
      if (field.type == typeString) {
        return utf8.decode(raw.bytes);
      }
      if (field.type == typeMessage) {
        return decodeGeneric(file.message(field.typeName), raw.bytes, file);
      }
      return raw.bytes;
  }
}

// ---------------------------------------------------------------------------
// Descriptor set parsing
// ---------------------------------------------------------------------------

/// Parse FileDescriptorSet bytes into a FileModel.
FileModel parseDescriptorSet(List<int> data) {
  final file = FileModel();
  final pendingServices = <(String, Uint8List)>[];
  final reader = _PbReader(Uint8List.fromList(data));
  while (true) {
    final f = reader.next();
    if (f == null) break;
    if (f.number != 1) continue;
    var pkg = '';
    final messageTypes = <Uint8List>[];
    final serviceTypes = <Uint8List>[];
    final fr = _PbReader(f.bytes);
    while (true) {
      final ff = fr.next();
      if (ff == null) break;
      switch (ff.number) {
        case 2:
          pkg = _asString(ff);
          break;
        case 4:
          messageTypes.add(ff.bytes);
          break;
        case 6:
          serviceTypes.add(ff.bytes);
          break;
      }
    }
    for (final m in messageTypes) {
      _parseMessage(pkg, m, file);
    }
    for (final s in serviceTypes) {
      pendingServices.add((pkg, s));
    }
  }
  for (final (pkg, serviceBytes) in pendingServices) {
    _parseService(pkg, serviceBytes, file);
  }
  return file;
}

void _parseMessage(String prefix, Uint8List data, FileModel file) {
  var name = '';
  final rawFields = <Uint8List>[];
  final nested = <Uint8List>[];
  final reader = _PbReader(data);
  while (true) {
    final f = reader.next();
    if (f == null) break;
    switch (f.number) {
      case 1:
        name = _asString(f);
        break;
      case 2:
        rawFields.add(f.bytes);
        break;
      case 3:
        nested.add(f.bytes);
        break;
    }
  }
  final fullName = prefix.isEmpty ? name : '$prefix.$name';
  final model = MessageModel(fullName);
  for (final fieldBytes in rawFields) {
    final field = _parseField(fieldBytes);
    model.byName[field.name] = field.number;
    model.fields[field.number] = field;
  }
  file.messages['.$fullName'] = model;
  for (final nestedBytes in nested) {
    _parseMessage(fullName, nestedBytes, file);
  }
}

FieldModel _parseField(Uint8List data) {
  final field = FieldModel();
  final reader = _PbReader(data);
  while (true) {
    final f = reader.next();
    if (f == null) break;
    switch (f.number) {
      case 1:
        field.name = _asString(f);
        break;
      case 3:
        field.number = f.varint;
        break;
      case 4:
        field.repeated = f.varint == _labelRepeated;
        break;
      case 5:
        field.type = f.varint;
        break;
      case 6:
        field.typeName = _asString(f);
        break;
    }
  }
  return field;
}

String _kindOf(bool clientStreaming, bool serverStreaming) {
  if (clientStreaming && serverStreaming) return Server.kindBidi;
  if (serverStreaming) return Server.kindServerStreaming;
  if (clientStreaming) return Server.kindClientStreaming;
  return Server.kindUnary;
}

void _parseService(String pkg, Uint8List data, FileModel file) {
  var name = '';
  final rawMethods = <Uint8List>[];
  final reader = _PbReader(data);
  while (true) {
    final f = reader.next();
    if (f == null) break;
    switch (f.number) {
      case 1:
        name = _asString(f);
        break;
      case 2:
        rawMethods.add(f.bytes);
        break;
    }
  }
  final fullName = pkg.isEmpty ? name : '$pkg.$name';
  final service = ServiceModel(fullName);
  for (final methodBytes in rawMethods) {
    var mname = '';
    var inputType = '';
    var outputType = '';
    var clientStreaming = false;
    var serverStreaming = false;
    final mr = _PbReader(methodBytes);
    while (true) {
      final mf = mr.next();
      if (mf == null) break;
      switch (mf.number) {
        case 1:
          mname = _asString(mf);
          break;
        case 2:
          inputType = _asString(mf);
          break;
        case 3:
          outputType = _asString(mf);
          break;
        case 5:
          clientStreaming = mf.varint != 0;
          break;
        case 6:
          serverStreaming = mf.varint != 0;
          break;
      }
    }
    final method = MethodModel()
      ..name = mname
      ..path = '/$fullName/$mname'
      ..kind = _kindOf(clientStreaming, serverStreaming)
      ..input = file.message(inputType)
      ..output = file.message(outputType);
    service.methods[mname] = method;
  }
  file.services[fullName] = service;
}

// ---------------------------------------------------------------------------
// Client / server surfaces
// ---------------------------------------------------------------------------

/// Adapts a (MessageModel, GenericMessage) pair to the Channel
/// marshal/unmarshal contract.
class _BoundMessage implements Marshaler, Unmarshaler {
  final MessageModel _model;
  final FileModel _file;
  GenericMessage generic;

  _BoundMessage(this._model, this.generic, this._file);

  @override
  Uint8List marshalDc() => encodeGeneric(_model, generic, _file);

  @override
  void unmarshalDc(List<int> data) {
    generic = decodeGeneric(_model, data, _file);
  }
}

/// Receiving stream of generic responses.
class DynamicStream {
  final ClientStream _stream;
  final MessageModel _output;
  final FileModel _file;

  DynamicStream(this._stream, this._output, this._file);

  /// Next response; throws EndOfStreamError at end.
  Future<GenericMessage> recv() async {
    final resp = _BoundMessage(_output, GenericMessage(_output), _file);
    await _stream.recv(resp);
    return resp.generic;
  }

  /// Collect all responses (simplifies scenario drivers).
  Future<List<GenericMessage>> collect() async {
    final out = <GenericMessage>[];
    while (true) {
      try {
        out.add(await recv());
      } on EndOfStreamError {
        return out;
      }
    }
  }
}

/// Runtime-built client: methods resolve from the FileModel.
class DynamicClient {
  final Channel _channel;
  final FileModel _model;

  DynamicClient(this._channel, this._model);

  MethodModel _method(String service, String method) {
    final svc = _model.service(service);
    final m = svc.methods[method];
    if (m == null) {
      throw StatusException(
          Wire.codeInvalidArgument, 'unknown method $service/$method');
    }
    return m;
  }

  Future<GenericMessage> unary(String service, String method,
      GenericMessage req,
      {Map<String, String>? metadata, Duration? timeout}) async {
    final m = _method(service, method);
    final resp = _BoundMessage(m.output!, GenericMessage(m.output), _model);
    await _channel.unary(m.path, _BoundMessage(m.input!, req, _model), resp,
        metadata: metadata, timeout: timeout);
    return resp.generic;
  }

  Future<DynamicStream> serverStream(String service, String method,
      GenericMessage req,
      {Map<String, String>? metadata, Duration? timeout}) async {
    final m = _method(service, method);
    final stream = await _channel.serverStream(
        m.path, _BoundMessage(m.input!, req, _model),
        metadata: metadata, timeout: timeout);
    return DynamicStream(stream, m.output!, _model);
  }

  Future<GenericMessage> clientStream(String service, String method,
      List<GenericMessage> reqs,
      {Map<String, String>? metadata, Duration? timeout}) async {
    final m = _method(service, method);
    final bound = reqs.map((r) => _BoundMessage(m.input!, r, _model)).toList();
    final resp = _BoundMessage(m.output!, GenericMessage(m.output), _model);
    await _channel.clientStreamCall(m.path, bound, resp, metadata: metadata, timeout: timeout);
    return resp.generic;
  }

  Future<DynamicStream> bidi(String service, String method,
      List<GenericMessage> reqs,
      {Map<String, String>? metadata, Duration? timeout}) async {
    final m = _method(service, method);
    final bound = reqs.map((r) => _BoundMessage(m.input!, r, _model)).toList();
    final stream = await _channel.bidi(m.path, bound, metadata: metadata, timeout: timeout);
    return DynamicStream(stream, m.output!, _model);
  }
}

/// Handler signatures for registerDynamicService.
typedef DynamicRecvFn = Future<GenericMessage> Function();
typedef DynamicSendFn = Future<void> Function(GenericMessage resp);

/// Implements a service with generic messages.
abstract class DynamicHandler {
  Future<GenericMessage> unary(
      CallContext ctx, MethodModel method, GenericMessage req);
  Future<void> serverStream(CallContext ctx, MethodModel method,
      GenericMessage req, DynamicSendFn send);
  Future<GenericMessage> clientStream(
      CallContext ctx, MethodModel method, DynamicRecvFn recv);
  Future<void> bidi(CallContext ctx, MethodModel method, DynamicRecvFn recv,
      DynamicSendFn send);
}

/// Register a runtime-built service on a Server.
void registerDynamicService(
    Server server, FileModel fileModel, String serviceName, DynamicHandler handler) {
  final service = fileModel.service(serviceName);
  final methods = <Method>[];
  for (final m in service.methods.values) {
    methods.add(Method(m.name, m.path, m.kind, (ctx, reqs, sink) async {
      Future<GenericMessage> recv() async =>
          decodeGeneric(m.input!, await reqs.recvRaw(), fileModel);
      Future<void> send(GenericMessage resp) async {
        sink(encodeGeneric(m.output!, resp, fileModel));
      }

      switch (m.kind) {
        case Server.kindUnary:
          sink(encodeGeneric(
              m.output!, await handler.unary(ctx, m, await recv()), fileModel));
          break;
        case Server.kindServerStreaming:
          await handler.serverStream(ctx, m, await recv(), send);
          break;
        case Server.kindClientStreaming:
          sink(encodeGeneric(
              m.output!, await handler.clientStream(ctx, m, recv), fileModel));
          break;
        default:
          await handler.bidi(ctx, m, recv, send);
          break;
      }
    }));
  }
  server.registerService(ServiceDesc(service.fullName, methods));
}
GRPC_RUNTIME_EOF
)

(define dart-dispatch-arms
  '((HEADERS    . "_onHeaders(streamId, payload);")
    (DATA       . "_pushEvent(streamId, StreamEvent(EventKind.data, payload: payload));")
    (HALF-CLOSE . "_pushEvent(streamId, StreamEvent(EventKind.halfClose));")
    (TRAILERS   . "_onTerminal(streamId, payload, EventKind.trailers);")
    (RST        . "_onTerminal(streamId, payload, EventKind.rst);")))

(define (pascal-dart sym) ; HALF-CLOSE -> HalfClose
  (apply string-append
         (for/list ([part (in-list (string-split (symbol->string sym) "-"))])
           (string-append (string (char-upcase (string-ref part 0)))
                          (string-downcase (substring part 1))))))

(define (emit-dart-dispatch)
  (string-append
   "    switch (frameType) {\n"
   (apply string-append
          (for/list ([e (in-list frame-table)])
            (define arm (assoc (first e) dart-dispatch-arms))
            (unless arm (error 'runtime-dart "no Dart dispatch arm for ~a" (first e)))
            (format "      case Wire.frame~a:\n        ~a\n        break;\n"
                    (pascal-dart (first e)) (cdr arm))))
   "      default:\n"
   "        break; // Unknown frame type: ignore for forward compatibility.\n"
   "    }"))

(define dart-sidecar-body
#<<GRPC_RUNTIME_EOF
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'transport.dart';

/// Transport over the Rust WebRTC-Direct sidecar: the sidecar
/// owns DTLS/SCTP/TURN and bridges one datachannel to a local
/// TCP socket using u32 big-endian length-prefixed messages
/// (one prefix per DataChannel message). dart:io only.
class SidecarTransport implements Transport {
  final Socket _socket;
  final StreamController<Uint8List> _inbox = StreamController<Uint8List>();
  final BytesBuilder _buf = BytesBuilder();
  bool _closed = false;

  SidecarTransport(this._socket) {
    _socket.listen(
      (chunk) {
        _buf.add(chunk);
        _drain();
      },
      onDone: () {
        if (!_inbox.isClosed) _inbox.close();
      },
      onError: (Object e) {
        if (!_inbox.isClosed) _inbox.addError(e);
      },
    );
  }

  static Future<SidecarTransport> connect(String host, int port) async =>
      SidecarTransport(await Socket.connect(host, port));

  void _drain() {
    while (true) {
      final bytes = _buf.toBytes();
      if (bytes.length < 4) return;
      final length = ByteData.sublistView(bytes, 0, 4).getUint32(0, Endian.big);
      if (bytes.length < 4 + length) return;
      final payload = Uint8List.sublistView(bytes, 4, 4 + length);
      _buf.clear();
      _buf.add(Uint8List.sublistView(bytes, 4 + length));
      _inbox.add(Uint8List.fromList(payload));
    }
  }

  @override
  Stream<Uint8List> get onMessage => _inbox.stream;

  @override
  void send(Uint8List data) {
    if (_closed) throw StateError('transport closed');
    final header = ByteData(4)..setUint32(0, data.length, Endian.big);
    _socket.add(header.buffer.asUint8List());
    _socket.add(data);
  }

  @override
  Future<void> close() async {
    _closed = true;
    await _socket.close();
    if (!_inbox.isClosed) await _inbox.close();
  }
}
GRPC_RUNTIME_EOF
)

(define (emit-dart-runtime-files)
  (list
   (cons "grpcdc/status.dart" dart-status-body)
   (cons "grpcdc/codec.dart" dart-codec-body)
   (cons "grpcdc/transport.dart" dart-transport-body)
   (cons "grpcdc/endpoint.dart"
         (string-replace dart-endpoint-body "@@FRAME_DISPATCH@@" (emit-dart-dispatch)))
   (cons "grpcdc/channel.dart" dart-channel-body)
   (cons "grpcdc/server.dart" dart-server-body)
   (cons "grpcdc/memory_transport.dart" dart-loopback-body)
   (cons "grpcdc/sidecar_transport.dart" dart-sidecar-body)
   (cons "grpcdc/dynamic.dart" dart-dynamic-body)))
