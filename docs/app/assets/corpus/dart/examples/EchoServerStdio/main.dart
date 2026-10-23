import 'dart:io';

import '../../grpcdc/server.dart';
import '../echo_grpc_dc.dart';
import '../echo_service_impl.dart';
import '../stdio_transport.dart';

// Interop harness: the Dart echo server over stdio. Other languages'
// tests spawn this and drive it with their clients, proving the
// runtimes interoperate on the same frames.
Future<void> main() async {
  final transport = StdioTransport(stdin, stdout.add, onEof: () => exit(0));
  final server = Server();
  EchoGrpcDc.registerEchoServer(server, EchoServiceImpl());
  server.serveTransport(transport);
  // Serve until stdin EOF (above) or the driver kills us.
  await Future.delayed(const Duration(days: 1));
}
