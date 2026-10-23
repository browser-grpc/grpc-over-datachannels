import 'dart:async';
import 'dart:io';

import '../examples/echo_grpc_dc.dart';
import '../examples/stdio_transport.dart';
import '../grpcdc/channel.dart';
import 'scenario_runner.dart';
import 'test_util.dart';

/// Oracle: official grpc-java, bridged over TCP<->DataChannel by
/// oracle/bridge.mjs, must agree with the Dart runtime on every case
/// of the generated scenario driver. Skips when the Java oracle or
/// Node bridge are unavailable (Dockerfile.ci provides both).
Future<void> testOracle() async {
  final rootPath = root();
  final cp = javaClasspath(rootPath);
  if (cp == null) {
    print('TestOracle SKIP (java oracle not built)');
    return;
  }

  // Direction A: this client -> bridge -> official server.
  final port = await freePort();
  final server = await Process.start('java', ['-cp', cp, 'dc.oracle.OracleServer', '$port']);
  try {
    if (!await waitReady(server.stderr, 'READY')) {
      print('TestOracle SKIP (oracle server did not start)');
      return;
    }
    final bridge = await Process.start(
        'node', ['$rootPath/oracle/bridge.mjs', 'dc-to-http2', '--grpc', '127.0.0.1:$port']);
    try {
      final transport = StdioTransport(bridge.stdout, bridge.stdin.add);
      final client = EchoClient(Channel(transport));
      await runScenarios(client);
    } finally {
      bridge.kill(ProcessSignal.sigkill);
      await bridge.exitCode;
    }
  } finally {
    server.kill(ProcessSignal.sigkill);
    await server.exitCode;
  }

  // Direction B: official client -> bridge -> this runtime's server.
  final serverBin = '$rootPath/dart/build/echo_server_stdio';
  if (!fileExists(serverBin)) {
    print('TestOracle SKIP (dart server not built)');
    return;
  }
  final portB = await freePort();
  final bridge = await Process.start('node', [
    '$rootPath/oracle/bridge.mjs',
    'http2-to-dc',
    '--port',
    '$portB',
    '--target-cmd',
    serverBin,
  ]);
  try {
    if (!await waitReady(bridge.stderr, 'listening')) {
      print('TestOracle SKIP (bridge did not start)');
      return;
    }
    final client = await Process.start('java', [
      '-cp',
      cp,
      'dc.oracle.OracleClient',
      '$portB',
      '$rootPath/fixtures/oracle_scenarios.txt',
    ]);
    final output = await readAll(client.stdout);
    final errOutput = await readAll(client.stderr);
    final exitCode = await client.exitCode.timeout(const Duration(seconds: 120),
        onTimeout: () {
      client.kill(ProcessSignal.sigkill);
      return -1;
    });
    check(exitCode == 0, 'oracle client failed:\n$output$errOutput');
    check(output.contains('ORACLE CLIENT: ALL OK'), 'oracle client output:\n$output$errOutput');
  } finally {
    bridge.kill(ProcessSignal.sigkill);
    await bridge.exitCode;
  }
  print('TestOracle OK');
}
