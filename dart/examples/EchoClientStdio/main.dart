import 'dart:io';

import '../../grpcdc/channel.dart';
import '../../grpcdc/status.dart';
import '../echo_grpc_dc.dart';
import '../echo_messages.dart';
import '../stdio_transport.dart';

// Interop harness: the Dart echo client over stdio. Prints one line
// per call shape to stderr (stdout carries frames) and exits non-zero
// on any failure. Mirrors go/examples/echo_client_stdio.
Future<void> main() async {
  try {
    await run();
  } catch (e) {
    stderr.writeln('error: $e');
    exit(1);
  }
}

EchoRequest req(String message, int count) => EchoRequest(message, count);

Future<void> run() async {
  final transport = StdioTransport(stdin, stdout.add);
  final client = EchoClient(Channel(transport));

  final unary = await client.unary(req('hello', 0));
  stderr.writeln('unary=${unary.message}');

  final stream = await client.serverStream(req('tick', 3));
  final ticks = <String>[];
  await for (final resp in stream.responses) {
    ticks.add('${resp.message}#${resp.index}');
  }
  stderr.writeln('server_stream=${ticks.join(',')}');

  final joined = await client.clientStream([req('a', 0), req('b', 0), req('c', 0)]);
  stderr.writeln('client_stream=${joined.message}');

  final bidi = await client.bidi([req('x', 0), req('y', 0)]);
  final echoed = <String>[];
  await for (final resp in bidi.responses) {
    echoed.add(resp.message);
  }
  stderr.writeln('bidi=${echoed.join(',')}');

  final mdResp = await client.unary(req('hello', 0), metadata: {'x-echo': 'meta'});
  stderr.writeln('metadata=${mdResp.message}');

  try {
    await client.unary(EchoRequest('slow', 0, 400), timeout: Duration(milliseconds: 50));
    stderr.writeln('deadline=no error');
  } on StatusException catch (e) {
    stderr.writeln('deadline=${e.code}');
  }

  try {
    await client.unary(req('fail', 0));
    stderr.writeln('error_case=no error');
    exit(1);
  } on StatusException catch (e) {
    stderr.writeln('error_case=$e');
  }
  exit(0);
}
