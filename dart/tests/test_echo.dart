import 'dart:async';

import '../examples/echo_grpc_dc.dart';
import '../examples/echo_messages.dart';
import '../examples/echo_service_impl.dart';
import '../grpcdc/channel.dart';
import '../grpcdc/memory_transport.dart';
import '../grpcdc/server.dart';
import '../grpcdc/status.dart';
import 'test_util.dart';

EchoRequest req(String message, int count) => EchoRequest(message, count);

/// Loopback end-to-end: all four shapes, error status, metadata.
/// Dart's async surface is the native one (Future/Stream), so the
/// sync/async split other languages need does not arise.
Future<void> testEcho() async {
  final (a, b) = memoryTransportPair();
  final server = Server();
  EchoGrpcDc.registerEchoServer(server, EchoServiceImpl());
  server.serveTransport(b);
  final client = EchoClient(Channel(a));

  final unary = await client.unary(req('hello', 0));
  check(unary.message == 'echo: hello' && unary.index == 0, 'unary: $unary');

  final stream = await client.serverStream(req('tick', 3));
  final indexes = <int>[];
  await for (final resp in stream.responses) {
    check(resp.message == 'tick', 'stream message: $resp');
    indexes.add(resp.index);
  }
  check(indexes.toString() == [0, 1, 2].toString(), 'stream indexes: $indexes');

  final joined = await client.clientStream([req('a', 0), req('b', 0), req('c', 0)]);
  check(joined.message == 'a+b+c' && joined.index == 3, 'client stream: $joined');

  final bidi = await client.bidi([req('x', 0), req('y', 0)]);
  final echoed = <String>[];
  await for (final resp in bidi.responses) {
    echoed.add(resp.message);
  }
  check(echoed.toString() == ['x', 'y'].toString(), 'bidi: $echoed');

  try {
    await client.unary(req('fail', 0));
    check(false, 'fail call should throw');
  } on StatusException catch (e) {
    check(e.code == 3, 'fail status: $e');
  }

  final withMd = await client.unary(req('hello', 0), metadata: {'x-echo': 'meta'});
  check(withMd.message == 'echo: hello [meta]', 'metadata: $withMd');

  // Breaking a server stream cancels it server-side: cancelling
  // the Stream subscription must RST the call so the slow handler
  // (forwarding an async generator) stops producing.
  final slow = _SlowEchoService();
  final (a2, b2) = memoryTransportPair();
  final server2 = Server();
  EchoGrpcDc.registerEchoServer(server2, slow);
  server2.serveTransport(b2);
  final client2 = EchoClient(Channel(a2));
  final slowStream = await client2.serverStream(req('tick', 1000));
  var seen = 0;
  await for (final resp in slowStream.responses) {
    check(resp.index == 0, 'stream-break first: $resp');
    seen++;
    break;
  }
  check(seen == 1, 'stream-break seen: $seen');
  await Future<void>.delayed(const Duration(milliseconds: 150));
  final settled = slow.produced;
  await Future<void>.delayed(const Duration(milliseconds: 150));
  check(slow.produced == settled,
      'stream-break kept producing: $settled -> ${slow.produced}');
  check(settled < 100, 'stream-break produced too many: $settled');

  print('TestEcho OK');
}

/// Slow counting handler: forwards an async generator into the
/// sink, so a sink throw must cancel the generator subscription.
class _SlowEchoService extends EchoServiceImpl {
  int produced = 0;

  Stream<int> _ticks(int count) async* {
    for (var i = 0; i < count; i++) {
      yield i;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  @override
  Future<void> serverStream(
      EchoRequest req, EchoServerStreamServer stream) async {
    await for (final i in _ticks(req.count)) {
      produced++;
      stream.send(EchoResponse(req.message, i));
    }
  }
}
