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

  print('TestEcho OK');
}
