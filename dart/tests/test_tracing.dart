import '../examples/echo_grpc_dc.dart';
import '../examples/echo_messages.dart';
import '../examples/echo_service_impl.dart';
import '../grpcdc/channel.dart';
import '../grpcdc/endpoint.dart';
import '../grpcdc/memory_transport.dart';
import '../grpcdc/server.dart';
import '../grpcdc/status.dart';
import 'test_util.dart';

class _Start {
  final String kind;
  final String traceId;
  final String spanId;
  final String parentSpanId;
  _Start(this.kind, this.traceId, this.spanId, this.parentSpanId);
}

class _Recorder implements Tracer {
  final List<_Start> starts = [];
  final List<double> endDurations = [];

  @override
  void onStart(String kind, String method, String traceId, String spanId,
      String parentSpanId) {
    starts.add(_Start(kind, traceId, spanId, parentSpanId));
  }

  @override
  void onEnd(String kind, String method, String traceId, String spanId,
      String status, double durationMs) {
    endDurations.add(durationMs);
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

/// Tracing: nested callee call joins the trace via the bound channel.
Future<void> testTracing() async {
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
    check(resp.message == 'echo: nested', 'resp ${resp.message}');

    final starts = rec.starts;
    check(starts.length == 4, 'starts ${starts.length}');
    check(
        starts.map((s) => s.kind).join(',') == 'client,server,client,server',
        'kinds');
    check(starts.every((s) => s.traceId == starts[0].traceId), 'trace ids');
    check(starts[1].parentSpanId == starts[0].spanId, 'server parent');
    check(starts[2].parentSpanId == starts[1].spanId, 'inner client parent');
    check(starts[3].parentSpanId == starts[2].spanId, 'inner server parent');
    check(front.seenSpan == starts[1].spanId, 'ctx span');
    check(rec.endDurations.length == 4 &&
        rec.endDurations.every((d) => d >= 0), 'durations');
    print('TestTracing OK');
  } finally {
    setTracer(null);
  }
}
