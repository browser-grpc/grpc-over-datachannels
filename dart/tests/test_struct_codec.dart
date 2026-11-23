import '../examples/echo_grpc_dc.dart';
import '../examples/echo_messages.dart';
import '../examples/echo_service_impl.dart';
import '../grpcdc/channel.dart';
import '../grpcdc/memory_transport.dart';
import '../grpcdc/server.dart';
import '../grpcdc/status.dart';
import '../grpcdc/wire.dart';
import 'test_util.dart';

EchoClient setupStruct(bool clientStruct, bool serverStruct) {
  final (a, b) = memoryTransportPair();
  final server = Server();
  server.setStructCodec(serverStruct);
  EchoGrpcDc.registerEchoServer(server, EchoServiceImpl());
  server.serveTransport(b);
  final channel = Channel(a);
  channel.setStructCodec(clientStruct);
  return EchoClient(channel);
}

/// Struct-codec negotiation: struct<->struct roundtrip, mismatch rejected, plain still works.
Future<void> testStructCodec() async {
  final client = setupStruct(true, true);

  final unary = await client.unary(EchoRequest('hello', 0));
  check(unary.message == 'echo: hello', 'struct unary: $unary');

  final stream = await client.serverStream(EchoRequest('tick', 3));
  var n = 0;
  await for (final _ in stream.responses) {
    n++;
  }
  check(n == 3, 'struct server-stream count: $n');

  final joined =
      await client.clientStream([EchoRequest('a', 0), EchoRequest('b', 0)]);
  check(joined.message == 'a+b', 'struct client-stream: $joined');

  final bidi = await client.bidi([EchoRequest('x', 0), EchoRequest('y', 0)]);
  final echoed = <String>[];
  await for (final resp in bidi.responses) {
    echoed.add(resp.message);
  }
  check(echoed.toString() == ['x', 'y'].toString(), 'struct bidi: $echoed');

  final structBytes = EchoRequest('hello', 0).marshalStruct();
  check(
      structBytes.length > 4 &&
          structBytes[0] == 0x44 &&
          structBytes[1] == 0x43 &&
          structBytes[2] == 0x53 &&
          structBytes[3] == 0x31,
      'struct magic missing');
  final back = EchoRequest();
  back.unmarshalStruct(structBytes);
  check(back.message == 'hello', 'struct roundtrip: ${back.message}');

  final mismatch = setupStruct(true, false);
  try {
    await mismatch.unary(EchoRequest('hello', 0));
    check(false, 'struct client vs plain server should fail');
  } on StatusException catch (e) {
    check(e.code == Wire.codeUnimplemented, 'mismatch status: $e');
  }

  final plain = setupStruct(false, true);
  final plainResp = await plain.unary(EchoRequest('hello', 0));
  check(plainResp.message == 'echo: hello', 'plain vs struct server: $plainResp');

  print('TestStructCodec OK');
}
