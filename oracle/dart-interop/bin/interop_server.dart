// grpc-dart (package:grpc) interop TestService server.
// Usage: interop_server [--port N]  (default 50051)

import 'package:grpc/grpc.dart' as $grpc;

import '../lib/test_service.dart';

Future<void> main(List<String> args) async {
  var port = 50051;
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--port' && i + 1 < args.length) {
      port = int.parse(args[i + 1]);
    }
  }
  final server = $grpc.Server.create(services: [TestService()]);
  await server.serve(port: port);
  print('listening on $port');
}
