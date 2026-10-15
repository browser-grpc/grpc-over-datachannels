import 'dart:async';
import 'dart:io';

import '../examples/echo_grpc_dc.dart';
import '../examples/echo_messages.dart';
import '../examples/stdio_transport.dart';
import '../grpcdc/channel.dart';
import '../grpcdc/status.dart';
import 'test_util.dart';

Future<bool> buildGo(String rootPath, String output, String pkg) async {
  final proc = await Process.start('go', ['build', '-o', output, pkg],
      workingDirectory: '$rootPath/go');
  return await proc.exitCode == 0;
}

/// Pump raw bytes between two process streams until EOF, line-split
/// on direction boundaries: copies chunk-for-chunk (stream chunks are
/// already message-sized reads from pipes; do not buffer to fill).
Future<void> pump(Stream<List<int>> from, void Function(List<int>) to) async {
  await for (final chunk in from) {
    to(chunk);
  }
}

/// Interop: the Dart runtime against the Go stdio harnesses (cross-
/// language wire compatibility). Skips when Go is unavailable.
/// Mirrors python/tests/test_interop.py.
Future<void> testInterop() async {
  final rootPath = root();
  final tmp = '/tmp/grpcdc_dart_interop';
  Directory(tmp).createSync(recursive: true);
  final serverBin = '$tmp/echo_server_stdio';
  if (!await buildGo(rootPath, serverBin, './examples/echo_server_stdio')) {
    print('TestInterop SKIP (no go)');
    return;
  }

  final server = await Process.start(serverBin, []);
  try {
    final transport = StdioTransport(server.stdout, server.stdin.add);
    final client = EchoClient(Channel(transport));

    final unary = await client.unary(EchoRequest('hello', 0));
    check(unary.message == 'echo: hello', 'unary: $unary');

    final stream = await client.serverStream(EchoRequest('tick', 3));
    final indexes = <int>[];
    await for (final resp in stream.responses) {
      indexes.add(resp.index);
    }
    check(indexes.toString() == [0, 1, 2].toString(), 'server stream: $indexes');

    final joined = await client.clientStream(
        [EchoRequest('a', 0), EchoRequest('b', 0), EchoRequest('c', 0)]);
    check(joined.message == 'a+b+c', 'client stream: $joined');

    final bidi = await client.bidi([EchoRequest('x', 0), EchoRequest('y', 0)]);
    final echoed = <String>[];
    await for (final resp in bidi.responses) {
      echoed.add(resp.message);
    }
    check(echoed.toString() == ['x', 'y'].toString(), 'bidi: $echoed');

    try {
      await client.unary(EchoRequest('fail', 0));
      check(false, 'fail should throw');
    } on StatusException catch (e) {
      check(e.code == 3, 'fail status: $e');
    }
  } finally {
    server.kill(ProcessSignal.sigkill);
    await server.exitCode;
  }

  // Reverse: Go client harness against the Dart stdio server.
  final clientBin = '$tmp/echo_client_stdio';
  if (!await buildGo(rootPath, clientBin, './examples/echo_client_stdio')) {
    print('TestInterop partial SKIP (client build)');
    return;
  }
  final dartServer = '$rootPath/dart/build/echo_server_stdio';
  if (!fileExists(dartServer)) {
    print('TestInterop partial SKIP (dart server not built)');
    return;
  }
  final dart = await Process.start(dartServer, []);
  final goClient = await Process.start(clientBin, []);
  try {
    final pumpA = pump(goClient.stdout, dart.stdin.add);
    final pumpB = pump(dart.stdout, goClient.stdin.add);
    final exitCode = await goClient.exitCode.timeout(const Duration(seconds: 60),
        onTimeout: () {
      goClient.kill(ProcessSignal.sigkill);
      return -1;
    });
    check(exitCode == 0, 'go client harness exit: $exitCode');
    dart.kill(ProcessSignal.sigkill);
    await Future.wait([pumpA, pumpB]).timeout(const Duration(seconds: 10),
        onTimeout: () => []);
    final stderrText = await readAll(goClient.stderr);
    check(stderrText.contains('unary=echo: hello'), 'go client unary: $stderrText');
    check(stderrText.contains('server_stream=tick#0,tick#1,tick#2'),
        'go client stream: $stderrText');
    check(stderrText.contains('client_stream=a+b+c'), 'go client client-stream: $stderrText');
    check(stderrText.contains('bidi=x,y'), 'go client bidi: $stderrText');
  } finally {
    dart.kill(ProcessSignal.sigkill);
    goClient.kill(ProcessSignal.sigkill);
  }
  print('TestInterop OK');
}
