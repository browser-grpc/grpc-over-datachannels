// Browser entry point (server role): the real Dart grpc_dc
// runtime (frame codec, endpoint multiplexer, generated Echo
// stub) serving over the page's RTCDataChannel bridge. Dart's
// runtime is async (Streams/Futures), so unlike the blocking
// worker runtimes the server runs event-driven on the page
// thread — no SharedArrayBuffer mailbox needed. The page only
// bridges its RTCDataChannel send/receive pair into the Dart
// transport. The Node test's JS client drives the four call
// shapes plus a deadline the slow handler must miss.
// Mirrors wasm/dart/echo_client.dart.

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import '../../dart/grpcdc/endpoint.dart';
import '../../dart/grpcdc/server.dart';
import '../../dart/grpcdc/status.dart';
import '../../dart/grpcdc/web_transport.dart';
import '../../dart/examples/echo_grpc_dc.dart';
import '../../dart/examples/echo_messages.dart';
import '../../dart/examples/echo_service_impl.dart';

/// Echo impl with a delayed Unary so client deadlines fire.
class SlowEcho extends EchoServiceImpl {
  @override
  Future<EchoResponse> unary(CallContext ctx, EchoRequest req) async {
    if (req.delayMs > 0) {
      await Future<void>.delayed(Duration(milliseconds: req.delayMs));
    }
    return super.unary(ctx, req);
  }
}

/// Retained so the server and its endpoint outlive this call.
Server? _server;

void runEchoServer(JSObject jsTransport) {
  final server = Server();
  EchoGrpcDc.registerEchoServer(server, SlowEcho());
  server.serveTransport(WebTransport(jsTransport));
  _server = server;
}

void main() {
  // Page contract mirrors the client's callback style:
  // window.runDartEchoServer(transport).
  final entry = (JSObject transport) {
    runEchoServer(transport);
  };
  globalContext.setProperty('runDartEchoServer'.toJS, entry.toJS);
  final tracingEntry = (JSObject transport) {
    runEchoServerTracing(transport);
  };
  globalContext.setProperty('runDartEchoServerTracing'.toJS, tracingEntry.toJS);
}

// Matrix tracing entry: same server with a recording span
// observer; every span start/end re-reports the cumulative
// spans via window.__dartReportSpans so the page can expose
// them to the matrix driver (window.__spans) while the server
// keeps running.
class _MatrixServerStart {
  final String kind;
  final String traceId;
  final String spanId;
  final String parentSpanId;
  _MatrixServerStart(this.kind, this.traceId, this.spanId, this.parentSpanId);
}

class _MatrixServerRecorder implements Tracer {
  final List<_MatrixServerStart> starts = [];
  final List<String> endKinds = [];

  @override
  void onStart(String kind, String method, String traceId, String spanId,
      String parentSpanId) {
    starts.add(_MatrixServerStart(kind, traceId, spanId, parentSpanId));
    _report();
  }

  @override
  void onEnd(String kind, String method, String traceId, String spanId,
      String status, double durationMs) {
    endKinds.add(kind);
    _report();
  }

  void _report() {
    final json = jsonEncode({
      'starts': starts
          .map((s) => [s.kind, s.traceId, s.spanId, s.parentSpanId])
          .toList(),
      'ends': endKinds,
    });
    final report = globalContext.getProperty('__dartReportSpans'.toJS);
    if (report.isDefinedAndNotNull) {
      (report as JSFunction).callAsFunction(null, json.toJS);
    }
  }
}

void runEchoServerTracing(JSObject jsTransport) {
  setTracer(_MatrixServerRecorder());
  runEchoServer(jsTransport);
}
