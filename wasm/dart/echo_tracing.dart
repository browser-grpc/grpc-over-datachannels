// Browser tracing entry point (native Dart runtime, compiled to
// JS or WasmGC): runs a nested call chain entirely in the page —
// client -> front callee -> downstream service over memory
// transports — with a recording span observer, and returns the
// spans as JSON so the Playwright driver can assert the trace.
import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import '../../dart/examples/echo_grpc_dc.dart';
import '../../dart/examples/echo_messages.dart';
import '../../dart/examples/echo_service_impl.dart';
import '../../dart/grpcdc/channel.dart';
import '../../dart/grpcdc/endpoint.dart';
import '../../dart/grpcdc/memory_transport.dart';
import '../../dart/grpcdc/server.dart';
import '../../dart/grpcdc/status.dart';

class _Start {
  final String kind;
  final String traceId;
  final String spanId;
  final String parentSpanId;
  _Start(this.kind, this.traceId, this.spanId, this.parentSpanId);
}

class _Recorder implements Tracer {
  final List<_Start> starts = [];
  final List<String> endKinds = [];

  @override
  void onStart(String kind, String method, String traceId, String spanId,
      String parentSpanId) {
    starts.add(_Start(kind, traceId, spanId, parentSpanId));
  }

  @override
  void onEnd(String kind, String method, String traceId, String spanId,
      String status, double durationMs) {
    endKinds.add(kind);
  }
}

class _Front extends EchoServiceImpl {
  final Channel downstreamChannel;
  String? seenSpan;

  _Front(this.downstreamChannel);

  @override
  Future<EchoResponse> unary(CallContext ctx, EchoRequest req) async {
    seenSpan = ctx.traceContext?.spanId;
    final bound =
        EchoClient(downstreamChannel.withTraceContext(ctx.traceContext));
    return bound.unary(EchoRequest('nested', 0));
  }
}

Future<String> runEchoTracing() async {
  final rec = _Recorder();
  setTracer(rec);
  try {
    final (a2, b2) = memoryTransportPair();
    final back = Server();
    EchoGrpcDc.registerEchoServer(back, EchoServiceImpl());
    back.serveTransport(b2);
    final downstreamChannel = Channel(a2);

    final front = _Front(downstreamChannel);
    final (a, b) = memoryTransportPair();
    final frontServer = Server();
    EchoGrpcDc.registerEchoServer(frontServer, front);
    frontServer.serveTransport(b);
    final client = EchoClient(Channel(a));

    final resp = await client.unary(EchoRequest('hello', 0));
    return jsonEncode({
      'message': resp.message,
      'seenSpan': front.seenSpan,
      'starts': rec.starts
          .map((s) => [s.kind, s.traceId, s.spanId, s.parentSpanId])
          .toList(),
      'ends': rec.endKinds,
    });
  } finally {
    setTracer(null);
  }
}

void main() {
  // Page contract mirrors runDartEchoClient:
  // window.runDartEchoTracing(resolve, reject).
  final entry = (JSFunction resolve, JSFunction reject) {
    runEchoTracing().then(
      (json) => resolve.callAsFunction(null, json.toJS),
      onError: (Object e) => reject.callAsFunction(null, e.toString().toJS),
    );
  };
  globalContext.setProperty('runDartEchoTracing'.toJS, entry.toJS);
}
