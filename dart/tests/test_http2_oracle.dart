import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../examples/echo_grpc_dc.dart';
import '../examples/echo_messages.dart';
import '../grpcdc/channel.dart';
import '../grpcdc/http2_transport.dart';
import '../grpcdc/status.dart';
import 'scenario_runner.dart';
import 'test_util.dart';

/// HTTP/2 oracle: the generated grpcdc.Http2Transport dials the
/// official grpc-java OracleServer directly over TCP (no bridge).
/// Plus a TLS leg against the Node fixture
/// (js/test/http2_tls_fixture.mjs, ALPN h2). Skips when the
/// oracle or fixtures are unavailable. Mirrors
/// java/tests/TestHttp2Oracle.java.
Future<void> testHttp2Oracle() async {
  final rootPath = root();
  final cp = javaClasspath(rootPath);
  if (cp == null) {
    print('TestHttp2Oracle SKIP (oracle not built)');
    return;
  }
  final port = await freePort();
  final server =
      await Process.start('java', ['-cp', cp, 'dc.oracle.OracleServer', '$port']);
  try {
    // OracleServer prints READY on stderr.
    if (!await waitReady(server.stderr, 'READY')) {
      print('TestHttp2Oracle SKIP (oracle server did not start)');
      return;
    }
    final transport = await Http2Transport.dial('127.0.0.1:$port');
    try {
      final client = EchoClient(Channel(transport));
      await runScenarios(client);
      // Echoed initial metadata proves HEADERS metadata made
      // the round trip.
      final md = await client.unary(EchoRequest('hello', 0, 0),
          metadata: {'x-echo': 'mval'});
      check(md.message == 'echo: hello [mval]', 'metadata echo: ${md.message}');
      // 200 responses x 1500-byte payloads: comfortably past
      // several 64KiB flow-control windows, so the call only
      // completes if stream/connection WINDOW_UPDATE accounting
      // replenishes.
      final big = 'y' * 1500;
      final stream = await client.serverStream(EchoRequest(big, 200, 0));
      var got = 0;
      try {
        while (true) {
          final resp = await stream.recv();
          check(resp.message == big && resp.index == got, 'flow: $got');
          got++;
        }
      } on EndOfStreamError {
        // call completed OK
      }
      check(got == 200, 'flow: got $got, want 200');
    } finally {
      await transport.close();
    }
  } finally {
    server.kill(ProcessSignal.sigkill);
    await server.exitCode;
  }
  await _tlsLeg(rootPath);
  print('TestHttp2Oracle OK');
}

Future<void> _tlsLeg(String rootPath) async {
  final fixture = File('$rootPath/js/test/http2_tls_fixture.mjs');
  if (!fixture.existsSync()) {
    print('TestHttp2Oracle TLS SKIP (fixture missing)');
    return;
  }
  final proc = await Process.start('node', [fixture.path]);
  try {
    // The fixture prints READY on stdout.
    String? line;
    final lines = proc.stdout.transform(utf8.decoder).transform(const LineSplitter());
    await for (final l in lines) {
      line = l;
      break;
    }
    if (line == null || !line.startsWith('READY')) {
      print('TestHttp2Oracle TLS SKIP (fixture did not start)');
      return;
    }
    final fields = line.split(RegExp(r'\s+'));
    final port = int.parse(fields[1]);
    final certPath = fields[2];
    final context = SecurityContext()..setTrustedCertificates(certPath);
    final transport = await Http2Transport.dialTls('localhost:$port', context,
        serverName: 'localhost');
    try {
      final client = EchoClient(Channel(transport));
      final resp = await client.unary(EchoRequest('hello', 0, 0));
      check(resp.message == 'echo: hello', 'tls unary: ${resp.message}');
    } finally {
      await transport.close();
    }
  } finally {
    proc.kill(ProcessSignal.sigkill);
    await proc.exitCode;
  }
}
