import 'dart:async';

import '../examples/echo_grpc_dc.dart';
import '../examples/echo_messages.dart';
import '../examples/echo_service_impl.dart';
import '../grpcdc/channel.dart';
import '../grpcdc/codec.dart';
import '../grpcdc/endpoint.dart';
import '../grpcdc/memory_transport.dart';
import '../grpcdc/server.dart';
import '../grpcdc/status.dart';
import '../grpcdc/wire.dart';
import 'test_util.dart';

EchoRequest req(String message, int count) => EchoRequest(message, count);

class SlowEcho extends EchoServiceImpl {
  CallContext? seenCtx;

  @override
  Future<EchoResponse> unary(CallContext ctx, EchoRequest req) async {
    seenCtx = ctx;
    await Future<void>.delayed(const Duration(milliseconds: 400));
    return super.unary(ctx, req);
  }

  @override
  Future<void> serverStream(
      EchoRequest req, EchoServerStreamServer stream) async {
    for (var i = 0; i < (req.count < 0 ? 0 : req.count); i++) {
      if (i > 0) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      stream.send(EchoResponse(req.message, i));
    }
  }
}

/// Deadlines: grpc-timeout propagation + DEADLINE_EXCEEDED.
Future<void> testDeadline() async {
  check(Codec.parseTimeout(Codec.encodeTimeout(const Duration(milliseconds: 250))) ==
      const Duration(milliseconds: 250), 'timeout round trip');
  check(Codec.parseTimeout('10x') == null, 'junk timeout');

  final (a, b) = memoryTransportPair();
  final server = Server();
  final slow = SlowEcho();
  EchoGrpcDc.registerEchoServer(server, slow);
  server.serveTransport(b);
  final client = EchoClient(Channel(a));

  final start = DateTime.now();
  try {
    await client.unary(req('hello', 0),
        timeout: const Duration(milliseconds: 50));
    check(false, 'expected deadline');
  } on StatusException catch (e) {
    check(e.code == Wire.codeDeadlineExceeded, 'code ${e.code}');
  }
  check(DateTime.now().difference(start) < const Duration(milliseconds: 350),
      'deadline fires fast');
  check(slow.seenCtx != null, 'handler ran');
  check(slow.seenCtx!.metadata.containsKey('grpc-timeout'), 'grpc-timeout metadata');
  check(slow.seenCtx!.deadline != null, 'ctx deadline');
  check(slow.seenCtx!.timeRemaining() != null, 'ctx remaining');

  final stream = await client.serverStream(req('tick', 5),
      timeout: const Duration(milliseconds: 150));
  final it = StreamIterator(stream.responses);
  check(await it.moveNext(), 'stream first exists');
  check(it.current.index == 0, 'stream first');
  try {
    await it.moveNext();
    check(false, 'expected stream deadline');
  } on StatusException catch (e) {
    check(e.code == Wire.codeDeadlineExceeded, 'stream code ${e.code}');
  }

  final joined = await client.clientStream([req('a', 0), req('b', 0)],
      timeout: const Duration(seconds: 5));
  check(joined.message == 'a+b', 'generous timeout: $joined');

  print('TestDeadline OK');
}
