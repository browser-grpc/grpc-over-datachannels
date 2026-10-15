import '../examples/echo_grpc_dc.dart';
import '../examples/echo_messages.dart';
import '../examples/echo_service_impl.dart';
import '../grpcdc/channel.dart';
import '../grpcdc/memory_transport.dart';
import '../grpcdc/server.dart';
import '../grpcdc/status.dart';
import 'bdd_scenarios.dart';
import 'test_util.dart';

/// BDD: interprets the generated behavior scenarios (bdd_scenarios.dart,
/// stamped from racket/bdd-spec.rkt; prose in BDD.md) against a
/// loopback client+server. These scenarios are the executable
/// examples, so the documentation cannot drift from the behavior.
Future<void> testBdd() async {
  final (a, b) = memoryTransportPair();
  final server = Server();
  EchoGrpcDc.registerEchoServer(server, EchoServiceImpl());
  server.serveTransport(b);
  final channel = Channel(a);
  final client = EchoClient(channel);

  for (final c in bddCases) {
    switch (c.kind) {
      case 'unary':
        try {
          final resp = await client.unary(EchoRequest(c.messages[0], 0),
              metadata: c.metadata.isEmpty ? null : {'x-echo': c.metadata});
          check(c.expectStatus < 0, '${c.name}: expected failure, got $resp');
          check(resp.message == c.expectMessage && resp.index == c.expectNum,
              '${c.name}: $resp');
        } on StatusException catch (e) {
          check(c.expectStatus >= 0 && e.code == c.expectStatus,
              '${c.name}: status $e, want ${c.expectStatus}');
        }
        break;
      case 'server-stream':
        final stream = await client.serverStream(EchoRequest(c.messages[0], c.count));
        var got = 0;
        await for (final resp in stream.responses) {
          check(resp.message == c.expectMessage && resp.index == got,
              '${c.name}: $resp at $got');
          got++;
        }
        check(got == c.expectNum, '${c.name}: got $got, want ${c.expectNum}');
        break;
      case 'client-stream':
        final resp = await client
            .clientStream(c.messages.map((m) => EchoRequest(m, 0)).toList());
        check(resp.message == c.expectMessage && resp.index == c.expectNum,
            '${c.name}: $resp');
        break;
      case 'bidi':
        final stream =
            await client.bidi(c.messages.map((m) => EchoRequest(m, 0)).toList());
        var got = 0;
        await for (final resp in stream.responses) {
          check(got < c.messages.length && resp.message == c.messages[got] && resp.index == got,
              '${c.name}: $resp at $got');
          got++;
        }
        check(got == c.expectNum, '${c.name}: got $got, want ${c.expectNum}');
        break;
      case 'raw-unary':
        try {
          final resp = EchoResponse();
          await channel.unary(c.path, EchoRequest(c.messages[0], 0), resp);
          check(false, '${c.name}: expected failure');
        } on StatusException catch (e) {
          check(e.code == c.expectStatus,
              '${c.name}: status $e, want ${c.expectStatus}');
        }
        break;
      default:
        throw StateError('unknown bdd kind: ${c.kind}');
    }
  }
  print('TestBdd OK');
}
