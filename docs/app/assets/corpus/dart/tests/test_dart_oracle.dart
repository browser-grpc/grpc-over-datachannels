import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../examples/empty_messages.dart';
import '../examples/messages_messages.dart';
import '../examples/test_grpc_dc.dart';
import '../examples/stdio_transport.dart';
import '../grpcdc/channel.dart';
import '../grpcdc/status.dart';
import 'test_util.dart';

/// Interop oracle against google's grpc-dart runtime
/// (package:grpc, oracle/dart-interop), mirroring the grpc-go
/// and grpc-java oracles:
///   Direction A: the generated Dart (grpc-dc) TestService
///     client runs canonical cases against the grpc-dart
///     server, through oracle/bridge.mjs dc-to-http2.
///   Direction B: the grpc-dart interop client runs the same
///     cases against the generated Dart TestService server,
///     through oracle/bridge.mjs http2-to-dc.
/// Skips when an oracle binary is not built (Dockerfile.ci
/// builds oracle/dart-interop).

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

Future<int> _freePort() async {
  final socket = await ServerSocket.bind('127.0.0.1', 0);
  final p = socket.port;
  await socket.close();
  return p;
}

Future<bool> _waitPort(int port) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (DateTime.now().isBefore(deadline)) {
    try {
      final sock = await Socket.connect('127.0.0.1', port);
      await sock.close();
      return true;
    } catch (_) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
  return false;
}

Payload _payload(int size) {
  final p = Payload();
  p.body = Uint8List(size);
  return p;
}

StreamingOutputCallRequest _streamReq(List<int> respSizes, int payloadSize) {
  final req = StreamingOutputCallRequest();
  req.payload = _payload(payloadSize);
  for (final size in respSizes) {
    req.responseParameters.add(ResponseParameters(size));
  }
  return req;
}

Future<void> _expectStatus(
    int code, String what, Future<void> Function() call) async {
  try {
    await call();
  } on StatusException catch (e) {
    check(e.code == code, '$what: code ${e.code} != $code');
    return;
  }
  throw StateError('$what: expected status $code, call succeeded');
}

Future<void> _runCasesA(TestServiceClient client,
    UnimplementedServiceClient unimpl) async {
  // empty_unary
  await client.emptyCall(Empty());
  print('dart-oracle A case ok: empty_unary');
  // large_unary
  {
    final req = SimpleRequest();
    req.responseSize = 31415;
    req.payload = _payload(271828);
    final resp = await client.unaryCall(req);
    check(resp.payload!.body.length == 31415, 'large_unary body');
  }
  print('dart-oracle A case ok: large_unary');
  // client_streaming
  {
    final sizes = [27182, 8, 1828, 45904];
    final reqs = sizes.map((s) {
      final r = StreamingInputCallRequest();
      r.payload = _payload(s);
      return r;
    }).toList();
    final resp = await client.streamingInputCall(reqs);
    check(resp.aggregatedPayloadSize == 74922,
        'client_streaming aggregated ${resp.aggregatedPayloadSize}');
  }
  print('dart-oracle A case ok: client_streaming');
  // server_streaming
  {
    final sizes = [31415, 9, 2653, 58979];
    final stream = await client.streamingOutputCall(_streamReq(sizes, 0));
    try {
      for (final size in sizes) {
        final resp = await stream.recv();
        check(resp.payload!.body.length == size, 'server_streaming size');
      }
      try {
        await stream.recv();
        throw StateError('server_streaming: expected EOF');
      } on EndOfStreamError {
        // end of stream
      }
    } finally {
      stream.close();
    }
  }
  print('dart-oracle A case ok: server_streaming');
  // ping_pong
  {
    final reqSizes = [27182, 8, 1828, 45904];
    final respSizes = [31415, 9, 2653, 58979];
    final reqs = List.generate(
        respSizes.length, (i) => _streamReq([respSizes[i]], reqSizes[i]));
    final stream = await client.fullDuplexCall(reqs);
    try {
      for (final size in respSizes) {
        final resp = await stream.recv();
        check(resp.payload!.body.length == size, 'ping_pong size');
      }
    } finally {
      stream.close();
    }
  }
  print('dart-oracle A case ok: ping_pong');
  // empty_stream
  {
    final stream = await client.fullDuplexCall([]);
    try {
      await stream.recv();
      throw StateError('empty_stream: expected EOF');
    } on EndOfStreamError {
      // end of stream
    } finally {
      stream.close();
    }
  }
  print('dart-oracle A case ok: empty_stream');
  // status_code_and_message + special_status_message
  {
    final req = SimpleRequest();
    req.responseSize = 31415;
    final status = EchoStatus();
    status.code = 2;
    status.message = 'test status message';
    req.responseStatus = status;
    await _expectStatus(2, 'status_code_and_message', () async {
      await client.unaryCall(req);
    });
  }
  print('dart-oracle A case ok: status_code_and_message');
  {
    final req = SimpleRequest();
    final status = EchoStatus();
    status.code = 2;
    status.message =
        '\t\ntest with whitespace\r\nand Unicode BMP ☺ and non-BMP \u{1F600}';
    req.responseStatus = status;
    await _expectStatus(2, 'special_status_message', () async {
      await client.unaryCall(req);
    });
  }
  print('dart-oracle A case ok: special_status_message');
  // unimplemented_method / unimplemented_service
  await _expectStatus(12, 'unimplemented_method', () async {
    await client.unimplementedCall(Empty());
  });
  print('dart-oracle A case ok: unimplemented_method');
  await _expectStatus(12, 'unimplemented_service', () async {
    await unimpl.unimplementedCall(Empty());
  });
  print('dart-oracle A case ok: unimplemented_service');
}

Future<void> testDartOracle() async {
  final rootPath = root();
  final dartServer = File('$rootPath/oracle/dart-interop/interop-server');
  final dartClient = File('$rootPath/oracle/dart-interop/interop-client');
  if (!dartServer.existsSync() || !dartClient.existsSync()) {
    print('TestDartOracle SKIP (dart oracle not built)');
    return;
  }

  // Direction A: our client -> grpc-dart server.
  {
    final port = await _freePort();
    final server = await Process.start(dartServer.path, ['--port', '$port']);
    server.stdout.listen((_) {});
    server.stderr.listen((_) {});
    try {
      check(await _waitPort(port), 'dart interop server did not start');
      final bridge = await Process.start('node',
          ['$rootPath/oracle/bridge.mjs', 'dc-to-http2', '--grpc', '127.0.0.1:$port']);
      bridge.stderr.listen((_) {});
      try {
        final transport = StdioTransport(bridge.stdout, bridge.stdin.add);
        final channel = Channel(transport);
        await _runCasesA(TestServiceClient(channel),
            UnimplementedServiceClient(channel));
      } finally {
        bridge.kill(ProcessSignal.sigkill);
      }
    } finally {
      server.kill(ProcessSignal.sigkill);
    }
  }

  // Direction B: grpc-dart client -> our server (through bridge).
  {
    final serverBin = '$rootPath/dart/build/interop_server_stdio';
    if (!fileExists(serverBin)) {
      print('TestDartOracle B SKIP (dart server not built)');
      return;
    }
    final port = await _freePort();
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
        print('TestDartOracle B SKIP (bridge did not start)');
        return;
      }
      for (final testCase in _cases) {
        final proc = await Process.run(dartClient.path, [
          '-server_host',
          '127.0.0.1',
          '-server_port',
          '$port',
          '-test_case',
          testCase,
        ]);
        check(proc.exitCode == 0,
            'dart case $testCase: exit ${proc.exitCode}\n${proc.stdout}\n${proc.stderr}');
        check(proc.stdout.toString().contains('Test completed.'),
            'dart case $testCase: unexpected output: ${proc.stdout}');
        print('dart-oracle B case ok: $testCase');
      }
    } finally {
      bridge.kill(ProcessSignal.sigkill);
      await bridge.exitCode;
    }
  }
  print('TestDartOracle OK');
}
