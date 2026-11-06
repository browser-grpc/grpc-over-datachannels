// In-memory unary call: a Server and a Channel joined by the
// loopback transport pair. Run: dart run example/example.dart
import 'dart:convert';
import 'dart:typed_data';

import 'package:grpc_dc/grpc_dc.dart';

/// One protobuf string field, hand-rolled for the example;
/// real code uses protoc-generated messages (Marshaler /
/// Unmarshaler), which plug in exactly the same way.
class Text implements Marshaler, Unmarshaler {
  String value;
  Text([this.value = '']);
  @override
  Uint8List marshalDc() => utf8.encode(value);
  @override
  void unmarshalDc(List<int> bytes) => value = utf8.decode(bytes);
}

Future<void> main() async {
  final (a, b) = memoryTransportPair();

  final server = Server();
  server.registerService(ServiceDesc('echo.Echo', [
    Method('Unary', '/echo.Echo/Unary', Server.kindUnary,
        (ctx, reqs, sink) async {
      final req = Text();
      await reqs.recvInto(req);
      sink(Text('echo: ' + req.value).marshalDc());
    }),
  ]));
  server.serveTransport(b);

  final channel = Channel(a);
  final resp = Text();
  await channel.unary('/echo.Echo/Unary', Text('hello'), resp);
  print(resp.value); // echo: hello
}
