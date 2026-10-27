import 'dart:io';

import '../../grpcdc/server.dart';
import '../interop_service_impl.dart';
import '../orca_grpc_dc.dart';
import '../stdio_transport.dart';
import '../test_grpc_dc.dart';

// Interop harness: the generated Dart TestService server over
// stdio. Direction-B oracle tests spawn this and drive it with
// the official grpc-java / grpc-go interop clients through the
// bridge (oracle/bridge.mjs http2-to-dc).
Future<void> main() async {
  final transport = StdioTransport(stdin, stdout.add, onEof: () => exit(0));
  final server = Server();
  final impl = InteropServiceImpl();
  TestGrpcDc.registerTestServiceServer(server, impl);
  OrcaGrpcDc.registerOpenRcaServiceServer(server, impl);
  server.serveTransport(transport);
  // Serve until stdin EOF (above) or the driver kills us.
  await Future.delayed(const Duration(days: 1));
}
