import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'test_util.dart';

const _cases = [
  'empty_unary',
  'large_unary',
  'client_streaming',
  'server_streaming',
  'ping_pong',
  'empty_stream',
  'custom_metadata',
  'status_code_and_message',
  'special_status_message',
  'unimplemented_method',
  'unimplemented_service',
  'cancel_after_begin',
  'cancel_after_first_response',
  'timeout_on_sleeping_server',
];

const _javaOnlyCases = [
  'cacheable_unary',
  'client_compressed_unary',
  'client_compressed_streaming',
  'server_compressed_unary',
  'server_compressed_streaming',
];

const _goOnlyCases = ['orca_per_rpc', 'orca_oob'];

Future<String> _runClient(List<String> argv) async {
  final proc = await Process.start(argv[0], argv.sublist(1));
  final out = StringBuffer();
  final stdoutDone = proc.stdout.transform(utf8.decoder).listen(out.write).asFuture();
  final stderrDone = proc.stderr.transform(utf8.decoder).listen(out.write).asFuture();
  final exit = await proc.exitCode.timeout(const Duration(seconds: 120), onTimeout: () {
    proc.kill(ProcessSignal.sigkill);
    throw StateError('client timed out: $argv');
  });
  await stdoutDone;
  await stderrDone;
  check(exit == 0, 'client exit $exit: $argv\n$out');
  return out.toString();
}

/// Interop oracle, Direction B: the OFFICIAL interop clients
/// (grpc-java TestServiceClient, grpc-go interop-client) run the
/// canonical cases against the generated Dart TestService server
/// (examples/InteropServerStdio), reached over HTTP/2 through
/// oracle/bridge.mjs http2-to-dc. Skips when an oracle binary or
/// Node is unavailable. Mirrors
/// java/tests/TestInteropServerOracle.java.
Future<void> testInteropServerOracle() async {
  final rootPath = root();
  final cp = javaClasspath(rootPath);
  if (cp == null) {
    print('TestInteropServerOracle SKIP (oracle not built)');
    return;
  }
  final serverBin = '$rootPath/dart/build/interop_server_stdio';
  if (!fileExists(serverBin)) {
    print('TestInteropServerOracle SKIP (dart server not built)');
    return;
  }
  final port = await freePort();
  final bridge = await Process.start('node', [
    '$rootPath/oracle/bridge.mjs',
    'http2-to-dc',
    '--port',
    '$port',
    '--target-cmd',
    serverBin,
  ]);
  try {
    if (!await waitReady(bridge.stderr, 'listening')) {
      print('TestInteropServerOracle SKIP (bridge did not start)');
      return;
    }
    for (final testCase in [..._cases, ..._javaOnlyCases]) {
      final out = await _runClient([
        'java',
        '-cp',
        cp,
        'io.grpc.testing.integration.TestServiceClient',
        '--server_host=127.0.0.1',
        '--server_port=$port',
        '--test_case=$testCase',
        '--use_tls=false',
      ]);
      check(out.contains('Test completed.'), 'java case $testCase: unexpected output: $out');
      print('interop B case ok: $testCase (java client)');
    }
    final goClient = File('$rootPath/oracle/go-interop/interop-client');
    if (!goClient.existsSync()) {
      print('TestInteropServerOracle GO SKIP (go client not built)');
    } else {
      for (final testCase in [..._cases, ..._goOnlyCases]) {
        final argv = [
          goClient.path,
          '-server_host',
          '127.0.0.1',
          '-server_port',
          '$port',
          '-test_case',
          testCase,
        ];
        if (testCase.startsWith('orca')) {
          argv.add('-service_config_json');
          argv.add('{ "loadBalancingConfig": [{ "test_backend_metrics_load_balancer": {} }]}');
        }
        await _runClient(argv);
        print('interop B case ok: $testCase (go client)');
      }
    }
  } finally {
    bridge.kill(ProcessSignal.sigkill);
    await bridge.exitCode;
  }
  print('TestInteropServerOracle OK');
}
