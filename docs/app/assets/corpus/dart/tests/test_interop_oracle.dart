import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../examples/empty_messages.dart';
import '../examples/messages_messages.dart';
import '../examples/orca_grpc_dc.dart';
import '../examples/orca_load_report_messages.dart';
import '../examples/orca_messages.dart';
import '../examples/test_grpc_dc.dart';
import '../examples/stdio_transport.dart';
import '../grpcdc/channel.dart';
import '../grpcdc/status.dart';
import 'interop_cases.dart';
import 'test_util.dart';

/// Interop client grading: the generated Dart TestService client
/// runs the canonical grpc interop cases (generated table:
/// interop_cases.dart) against the official grpc-go
/// TestServiceServer, through the bridge (dc-to-http2, stdio =
/// DataChannel). Mirrors the Java/C#/Kotlin/Scala/JS/Python/Go/
/// Rust interop oracle suites. Skips when the oracle server
/// binary is not built (Dockerfile.ci builds it).

Payload _payload(int size) {
  final p = Payload();
  p.body = Uint8List(size);
  return p;
}

StreamingOutputCallRequest _streamRequest(List<int> respSizes, int payloadSize) {
  final req = StreamingOutputCallRequest();
  req.payload = _payload(payloadSize);
  for (final size in respSizes) {
    req.responseParameters.add(ResponseParameters(size));
  }
  return req;
}

Future<void> _expectStatus(int code, String message, String what, Future<void> Function() call) async {
  try {
    await call();
  } on StatusException catch (e) {
    check(e.code == code, '$what: code ${e.code} != $code');
    if (message.isNotEmpty) {
      check(e.message == message, "$what: message '${e.message}' != '$message'");
    }
    return;
  }
  throw StateError('$what: expected status $code, call succeeded');
}

Future<void> _runCases(Channel channel, TestServiceClient client, UnimplementedServiceClient unimpl) async {
  for (final row in interopCases) {
    final name = row[0] as String;
    final kind = row[1] as String;
    final reqSizes = row[2] as List<int>;
    final respSizes = row[3] as List<int>;
    final statusCode = row[4] as int;
    final statusMessage = row[5] as String;
    switch (kind) {
      case 'EMPTY':
        await client.emptyCall(Empty());
        break;
      case 'LARGE_UNARY':
        {
          final req = SimpleRequest();
          req.responseSize = respSizes[0];
          req.payload = _payload(reqSizes[0]);
          final resp = await client.unaryCall(req);
          check(resp.payload!.body.length == respSizes[0], '$name: body ${resp.payload!.body.length}');
        }
        break;
      case 'CLIENT_STREAMING':
        {
          final reqs = reqSizes.map((s) {
            final r = StreamingInputCallRequest();
            r.payload = _payload(s);
            return r;
          }).toList();
          final resp = await client.streamingInputCall(reqs);
          final total = reqSizes.fold<int>(0, (a, b) => a + b);
          check(resp.aggregatedPayloadSize == total, '$name: aggregated ${resp.aggregatedPayloadSize} != $total');
        }
        break;
      case 'SERVER_STREAMING':
        {
          final stream = await client.streamingOutputCall(_streamRequest(respSizes, 0));
          try {
            for (final size in respSizes) {
              final resp = await stream.recv();
              check(resp.payload!.body.length == size, '$name: body ${resp.payload!.body.length} != $size');
            }
            try {
              await stream.recv();
              throw StateError('$name: expected EOF');
            } on EndOfStreamError {
              // end of stream
            }
          } finally {
            stream.close();
          }
        }
        break;
      case 'PING_PONG':
        {
          final reqs = List.generate(respSizes.length, (i) => _streamRequest([respSizes[i]], reqSizes[i]));
          final stream = await client.fullDuplexCall(reqs);
          try {
            for (final size in respSizes) {
              final resp = await stream.recv();
              check(resp.payload!.body.length == size, '$name: body ${resp.payload!.body.length} != $size');
            }
          } finally {
            stream.close();
          }
        }
        break;
      case 'EMPTY_STREAM':
        {
          final stream = await client.fullDuplexCall([]);
          try {
            try {
              await stream.recv();
              throw StateError('$name: expected EOF');
            } on EndOfStreamError {
              // end of stream
            }
          } finally {
            stream.close();
          }
        }
        break;
      case 'CUSTOM_METADATA':
        {
          // Upstream custom_metadata, duplex leg (mirrors the Java runner).
          final trailingBin = base64Encode([0x0a, 0x0b, 0x0a, 0x0b, 0x0a, 0x0b]);
          final md = {
            'x-grpc-test-echo-initial': 'test_initial_metadata_value',
            'x-grpc-test-echo-trailing-bin': trailingBin,
          };
          final stream = await client.fullDuplexCall([_streamRequest([1], 1)], metadata: md);
          try {
            final resp = await stream.recv();
            check(resp.payload!.body.length == 1, '$name: body');
            try {
              await stream.recv();
              throw StateError('$name: expected EOF');
            } on EndOfStreamError {
              // end of stream: trailers now readable
            }
            check(stream.headers?['x-grpc-test-echo-initial'] == 'test_initial_metadata_value',
                '$name: initial ${stream.headers}');
            check(stream.trailers?['x-grpc-test-echo-trailing-bin'] == trailingBin,
                '$name: trailing ${stream.trailers}');
          } finally {
            stream.close();
          }
        }
        break;
      case 'STATUS_UNARY':
        {
          final req = SimpleRequest();
          req.responseStatus = EchoStatus(statusCode, statusMessage);
          await _expectStatus(statusCode, statusMessage, name, () async {
            await client.unaryCall(req);
          });
        }
        break;
      case 'STATUS_DUPLEX':
        {
          final req = _streamRequest([0], 0);
          req.responseStatus = EchoStatus(statusCode, statusMessage);
          await _expectStatus(statusCode, statusMessage, name, () async {
            final stream = await client.fullDuplexCall([req]);
            try {
              await stream.recv();
            } finally {
              stream.close();
            }
          });
        }
        break;
      case 'SPECIAL_STATUS':
        {
          final req = SimpleRequest();
          req.responseStatus = EchoStatus(statusCode, statusMessage);
          await _expectStatus(statusCode, statusMessage, name, () async {
            await client.unaryCall(req);
          });
        }
        break;
      case 'CANCEL_AFTER_BEGIN':
        {
          // Begin a client-streaming call and cancel it before
          // sending any request: the pending recv must report
          // CANCELLED.
          final stream = await channel.openStream('/grpc.testing.TestService/StreamingInputCall');
          stream.cancel();
          await _expectStatus(statusCode, '', name, () async {
            await stream.recv(StreamingInputCallResponse());
          });
        }
        break;
      case 'CANCEL_AFTER_FIRST':
        {
          // Duplex call (no half-close): the server answers the
          // one request, then waits for more input, so the cancel
          // deterministically lands mid-call (same shape as the
          // Python/JS suites).
          final stream = await channel.openStream('/grpc.testing.TestService/FullDuplexCall');
          stream.send(_streamRequest([respSizes[0]], 1));
          final resp = StreamingOutputCallResponse();
          await stream.recv(resp);
          check(resp.payload!.body.length == respSizes[0], '$name: body ${resp.payload!.body.length}');
          stream.cancel();
          await _expectStatus(statusCode, '', name, () async {
            await stream.recv(StreamingOutputCallResponse());
          });
        }
        break;
      case 'TIMEOUT_SLEEPING':
        {
          final req = StreamingOutputCallRequest();
          req.payload = _payload(0);
          for (final size in respSizes) {
            req.responseParameters.add(ResponseParameters(size, 1000000));
          }
          await _expectStatus(statusCode, '', name, () async {
            final stream = await client.streamingOutputCall(req,
                timeout: const Duration(milliseconds: 100));
            try {
              await stream.recv();
            } finally {
              stream.close();
            }
          });
        }
        break;
      case 'UNIMPLEMENTED_METHOD':
        await _expectStatus(statusCode, '', name, () async {
          await client.unimplementedCall(Empty());
        });
        break;
      case 'UNIMPLEMENTED_SERVICE':
        await _expectStatus(statusCode, '', name, () async {
          await unimpl.unimplementedCall(Empty());
        });
        break;
      default:
        throw StateError('unknown interop kind $kind');
    }
    print('interop case ok: $name');
  }
}

// Compression rows (upstream client_compressed_unary,
// client_compressed_streaming, server_compressed_unary,
// server_compressed_streaming): the DataChannel wire is
// compression-free; the client declares grpc-encoding: gzip
// and the bridge gzips request messages on the HTTP/2 hop,
// decompressing responses the same way.
Future<void> _runCompressionCases(TestServiceClient client) async {
  const gzip = {'grpc-encoding': 'gzip'};
  {
    final req = SimpleRequest();
    req.responseSize = 31415;
    req.payload = _payload(271828);
    req.expectCompressed = BoolValue(true);
    final resp = await client.unaryCall(req, metadata: gzip);
    check(resp.payload!.body.length == 31415, 'client_compressed_unary: body');
    print('interop case ok: client_compressed_unary');
  }
  {
    final sizes = [27182, 8, 1828, 45904];
    final reqs = sizes.map((s) {
      final r = StreamingInputCallRequest();
      r.payload = _payload(s);
      r.expectCompressed = BoolValue(true);
      return r;
    }).toList();
    final resp = await client.streamingInputCall(reqs, metadata: gzip);
    final total = sizes.fold<int>(0, (a, b) => a + b);
    check(resp.aggregatedPayloadSize == total,
        'client_compressed_streaming: aggregated ${resp.aggregatedPayloadSize}');
    print('interop case ok: client_compressed_streaming');
  }
  {
    final req = SimpleRequest();
    req.responseSize = 31415;
    req.payload = _payload(271828);
    req.responseCompressed = BoolValue(true);
    final resp = await client.unaryCall(req);
    check(resp.payload!.body.length == 31415, 'server_compressed_unary: body');
    print('interop case ok: server_compressed_unary');
  }
  {
    final sizes = [31415, 9, 2653, 58979];
    final req = StreamingOutputCallRequest();
    req.payload = _payload(0);
    for (final size in sizes) {
      req.responseParameters.add(ResponseParameters(size, 0, BoolValue(true)));
    }
    final stream = await client.streamingOutputCall(req);
    try {
      for (final size in sizes) {
        final resp = await stream.recv();
        check(resp.payload!.body.length == size,
            'server_compressed_streaming: body ${resp.payload!.body.length}');
      }
    } finally {
      stream.close();
    }
    print('interop case ok: server_compressed_streaming');
  }
}

// ORCA rows (upstream orca_per_rpc / orca_oob): per-RPC the
// report returns as the serialized OrcaLoadReport in the
// endpoint-load-metrics-bin trailer (base64 -bin value); OOB the
// value fed through FullDuplexCall comes back on the
// OpenRcaService StreamCoreMetrics stream.
Future<void> _runOrcaCases(Channel channel, TestServiceClient client) async {
  final req = SimpleRequest();
  req.orcaPerQueryReport = TestOrcaReport(0.8210, 0.5847)
    ..requestCost['cost'] = 3456.32
    ..utilization['util'] = 0.30499;
  final stream = await channel.serverStream('/grpc.testing.TestService/UnaryCall', req);
  try {
    final resp = SimpleResponse();
    await stream.recv(resp);
    try {
      await stream.recv(SimpleResponse());
      throw StateError('orca_per_rpc: expected EOF');
    } on EndOfStreamError {
      // end of stream: trailers now readable
    }
    final encoded = stream.trailers?['endpoint-load-metrics-bin'];
    check(encoded != null, 'orca_per_rpc: no endpoint-load-metrics-bin trailer');
    final report = OrcaLoadReport();
    report.unmarshalDc(base64Decode(base64.normalize(encoded!)));
    check(
        report.cpuUtilization == 0.8210 &&
            report.memUtilization == 0.5847 &&
            report.requestCost['cost'] == 3456.32 &&
            report.utilization['util'] == 0.30499,
        'orca_per_rpc: report ${report.cpuUtilization}/${report.memUtilization}');
  } finally {
    stream.close();
  }
  print('interop case ok: orca_per_rpc');

  final feedReq = StreamingOutputCallRequest();
  feedReq.orcaOobReport = TestOrcaReport(0.9, 0.85)..utilization['util'] = 0.5;
  final feed = await client.fullDuplexCall([feedReq]);
  try {
    try {
      while (true) {
        await feed.recv();
      }
    } on EndOfStreamError {
      // feed call completed
    }
  } finally {
    feed.close();
  }
  final orca = OpenRcaServiceClient(channel);
  var matched = false;
  final metrics = await orca.streamCoreMetrics(OrcaLoadReportRequest());
  try {
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (!matched && DateTime.now().isBefore(deadline)) {
      final got = await metrics.recv();
      matched = got.cpuUtilization == 0.9 &&
          got.memUtilization == 0.85 &&
          got.utilization['util'] == 0.5;
    }
  } finally {
    metrics.close();
  }
  check(matched, 'orca_oob: no matching OOB report within 30s');
  print('interop case ok: orca_oob');
}

Future<void> testInteropOracle() async {
  final rootPath = root();
  final serverBin = File('$rootPath/oracle/go-interop/interop-server');
  if (!serverBin.existsSync()) {
    print('TestInteropOracle SKIP (go interop server not built)');
    return;
  }
  final port = await () async {
    final socket = await ServerSocket.bind('127.0.0.1', 0);
    final p = socket.port;
    await socket.close();
    return p;
  }();
  final server = await Process.start(serverBin.path, ['-port', '$port']);
  server.stdout.listen((_) {});
  server.stderr.listen((_) {});
  try {
    // The Go server prints no readiness line; poll the port.
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    var ready = false;
    while (DateTime.now().isBefore(deadline)) {
      try {
        final sock = await Socket.connect('127.0.0.1', port);
        await sock.close();
        ready = true;
        break;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    check(ready, 'go interop server did not start');

    final bridge = await Process.start('node', ['$rootPath/oracle/bridge.mjs', 'dc-to-http2', '--grpc', '127.0.0.1:$port']);
    bridge.stderr.listen((_) {});
    try {
      final transport = StdioTransport(bridge.stdout, bridge.stdin.add);
      final channel = Channel(transport);
      final client = TestServiceClient(channel);
      await _runCases(channel, client, UnimplementedServiceClient(channel));
      await _runCompressionCases(client);
      await _runOrcaCases(channel, client);
    } finally {
      bridge.kill(ProcessSignal.sigkill);
    }
  } finally {
    server.kill(ProcessSignal.sigkill);
  }
  print('TestInteropOracle OK');
}
