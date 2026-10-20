import 'dart:async';
import 'dart:io';

import '../examples/echo_grpc_dc.dart';
import '../examples/echo_messages.dart';
import '../examples/echo_service_impl.dart';
import '../grpcdc/channel.dart';
import '../grpcdc/server.dart';
import '../grpcdc/sidecar_transport.dart';
import 'test_util.dart';

String get _root =>
    File.fromUri(Platform.script).parent.parent.parent.path;
String get _sidecar =>
    '$_root/webrtc/rust/target/debug/examples/direct_sidecar';

Future<void> _ensureSidecar() async {
  if (await File(_sidecar).exists()) return;
  final result = await Process.run(
    'cargo',
    ['build', '--example', 'direct_sidecar'],
    workingDirectory: '$_root/webrtc/rust',
  );
  check(result.exitCode == 0, 'cargo build direct_sidecar: ${result.stderr}');
}

Future<int> _freePort() async {
  final socket = await ServerSocket.bind('127.0.0.1', 0);
  final port = socket.port;
  await socket.close();
  return port;
}

Future<String> _readLine(Stream<List<int>> stream, String needle) {
  final completer = Completer<String>();
  var buf = '';
  late StreamSubscription<List<int>> sub;
  sub = stream.listen((chunk) {
    buf += String.fromCharCodes(chunk);
    for (final line in buf.split('\n')) {
      if (line.contains(needle) && !completer.isCompleted) {
        completer.complete(line.trim());
        sub.cancel();
      }
    }
  });
  return completer.future.timeout(
    const Duration(seconds: 30),
    onTimeout: () => throw StateError('sidecar did not print $needle'),
  );
}

/// gRPC over WebRTC-Direct via the Rust sidecar, Dart to Dart:
/// two direct_sidecar processes own the WebRTC stack; the Dart
/// server and client only speak length-prefixed TCP to their
/// local sidecar (SidecarTransport).
Future<void> testSidecar() async {
  await _ensureSidecar();

  final langPort = await _freePort();
  final server = Server();
  EchoGrpcDc.registerEchoServer(server, EchoServiceImpl());
  final serverSock = await ServerSocket.bind('127.0.0.1', langPort);
  final serverSub = serverSock.listen((socket) {
    server.serveTransport(SidecarTransport(socket));
  });

  final listen = await Process.start(_sidecar, [
    'listen',
    '--udp',
    '127.0.0.1:0',
    '--tcp',
    '127.0.0.1:$langPort',
  ]);
  final multiaddr =
      (await _readLine(listen.stdout, 'MULTIADDR')).split(' ')[1];
  check(
    multiaddr.contains('/webrtc-direct/certhash/f'),
    'multiaddr: $multiaddr',
  );

  final clientPort = await _freePort();
  final dial = await Process.start(_sidecar, [
    'dial',
    '--multiaddr',
    multiaddr,
    '--tcp',
    '127.0.0.1:$clientPort',
  ]);
  await _readLine(dial.stdout, 'TCP');

  try {
    final client = EchoClient(
      Channel(await SidecarTransport.connect('127.0.0.1', clientPort)),
    );
    final unary = await client.unary(EchoRequest('hello', 0));
    check(unary.message == 'echo: hello', 'sidecar unary: $unary');

    final stream = await client.serverStream(
      EchoRequest('tick', 3),
    );
    final indexes = <int>[];
    await for (final resp in stream.responses) {
      indexes.add(resp.index);
    }
    check(indexes.toString() == [0, 1, 2].toString(), 'stream: $indexes');
    print('TestSidecar OK');
  } finally {
    dial.kill();
    listen.kill();
    await serverSub.cancel();
    await serverSock.close();
  }
}
