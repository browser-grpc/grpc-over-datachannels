import 'dart:io';

import '../../grpcdc/dynamic.dart';
import '../../grpcdc/server.dart';
import '../dynamic_echo_service.dart';
import '../stdio_transport.dart';

// Interop harness: the dynamic (descriptor-driven) Dart echo server
// over stdio. Loads fixtures/echo_descriptor_set.bin at runtime —
// no generated stubs involved. Used by the oracle tests.
Future<void> main() async {
  final model = parseDescriptorSet(File(locateFixtures()).readAsBytesSync());
  final transport = StdioTransport(stdin, stdout.add, onEof: () => exit(0));
  final server = Server();
  registerDynamicService(server, model, 'echo.Echo', DynamicEchoService());
  server.serveTransport(transport);
  await Future.delayed(const Duration(days: 1));
}

String locateFixtures() {
  var dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    final direct = File('${dir.path}/fixtures/echo_descriptor_set.bin');
    if (direct.existsSync()) {
      return direct.path;
    }
    final nested =
        File('${dir.path}/grpc-over-datachannels/fixtures/echo_descriptor_set.bin');
    if (nested.existsSync()) {
      return nested.path;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      break;
    }
    dir = parent;
  }
  stderr.writeln('fixtures/echo_descriptor_set.bin not found');
  exit(1);
}
