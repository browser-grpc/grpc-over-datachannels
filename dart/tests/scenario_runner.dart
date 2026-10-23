import '../examples/echo_grpc_dc.dart';
import '../examples/echo_messages.dart';
import '../grpcdc/dynamic.dart';
import '../grpcdc/status.dart';
import 'oracle_scenarios.dart';
import 'test_util.dart';

String unmsg(String token) => token == '-' ? '' : token;

/// Shared oracle-scenario runner for the typed stub client
/// (TestOracle) and the dynamic client (TestDynamic).
Future<void> runScenarios(EchoClient client) async {
  for (final c in cases) {
    final messages = c.messages.map(unmsg).toList();
    final line = '${c.kind} ${c.messages.join(' ')}';
    switch (c.kind) {
      case 'UNARY':
        try {
          final resp = await client.unary(EchoRequest(messages[0], 0));
          check(c.expectStatus < 0, '$line: expected failure, got $resp');
          check(resp.message == 'echo: ${messages[0]}' && resp.index == 0, '$line: $resp');
        } on StatusException catch (e) {
          check(c.expectStatus >= 0 && e.code == c.expectStatus,
              '$line: status $e, want ${c.expectStatus}');
        }
        break;
      case 'SERVER_STREAM':
        final stream = await client.serverStream(EchoRequest(messages[0], c.count));
        var got = 0;
        await for (final resp in stream.responses) {
          check(resp.message == messages[0] && resp.index == got, '$line: $resp at $got');
          got++;
        }
        check(got == c.count, '$line: got $got, want ${c.count}');
        break;
      case 'CLIENT_STREAM':
        final resp = await client.clientStream(messages.map((m) => EchoRequest(m, 0)).toList());
        check(resp.message == messages.join('+') && resp.index == messages.length, '$line: $resp');
        break;
      case 'BIDI':
        final stream = await client.bidi(messages.map((m) => EchoRequest(m, 0)).toList());
        var got = 0;
        await for (final resp in stream.responses) {
          check(got < messages.length && resp.message == messages[got] && resp.index == got,
              '$line: $resp at $got');
          got++;
        }
        check(got == messages.length, '$line: got $got');
        break;
      default:
        throw StateError('unknown scenario kind: ${c.kind}');
    }
  }
}

Future<void> runDynamicScenarios(DynamicClient client, FileModel model) async {
  GenericMessage req(String message, int count) {
    return GenericMessage(model.message('.echo.EchoRequest')).set(1, message).set(2, count);
  }

  List<GenericMessage> reqs(List<String> messages) =>
      messages.map((m) => req(m, 0)).toList();

  const service = 'echo.Echo';
  for (final c in cases) {
    final messages = c.messages.map(unmsg).toList();
    final line = '${c.kind} ${c.messages.join(' ')}';
    switch (c.kind) {
      case 'UNARY':
        try {
          final resp = await client.unary(service, 'Unary', req(messages[0], 0));
          check(c.expectStatus < 0, '$line: expected failure, got ${resp.values}');
          check(resp.getString(1) == 'echo: ${messages[0]}' && resp.getInt(2) == 0,
              '$line: ${resp.values}');
        } on StatusException catch (e) {
          check(c.expectStatus >= 0 && e.code == c.expectStatus,
              '$line: status $e, want ${c.expectStatus}');
        }
        break;
      case 'SERVER_STREAM':
        final stream = await client.serverStream(service, 'ServerStream', req(messages[0], c.count));
        final responses = await stream.collect();
        check(responses.length == c.count, '$line: got ${responses.length}, want ${c.count}');
        for (var i = 0; i < responses.length; i++) {
          check(responses[i].getString(1) == messages[0] && responses[i].getInt(2) == i,
              '$line: at $i');
        }
        break;
      case 'CLIENT_STREAM':
        final resp = await client.clientStream(service, 'ClientStream', reqs(messages));
        check(resp.getString(1) == messages.join('+') && resp.getInt(2) == messages.length,
            '$line: ${resp.values}');
        break;
      case 'BIDI':
        final stream = await client.bidi(service, 'Bidi', reqs(messages));
        final responses = await stream.collect();
        check(responses.length == messages.length, '$line: got ${responses.length}');
        for (var i = 0; i < responses.length; i++) {
          check(responses[i].getString(1) == messages[i] && responses[i].getInt(2) == i,
              '$line: at $i');
        }
        break;
      default:
        throw StateError('unknown scenario kind: ${c.kind}');
    }
  }
}
