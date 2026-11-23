// grpc-dart (package:grpc) interop client: runs one canonical
// case per invocation against a TestService server, mirroring
// the grpc-go interop-client CLI shape.
// Usage: interop_client -server_host H -server_port P -test_case CASE
// Prints "Test completed." on success (grpc-java convention).

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:grpc/grpc.dart' as $grpc;

import '../lib/gen/grpc/testing/empty.pb.dart';
import '../lib/gen/grpc/testing/messages.pb.dart';
import '../lib/gen/grpc/testing/test.pbgrpc.dart';

void _check(bool cond, String what) {
  if (!cond) throw StateError(what);
}

Payload _payload(int size) {
  final p = Payload();
  p.body = Uint8List(size);
  return p;
}

StreamingOutputCallRequest _streamReq(int size, List<int> respSizes) {
  final req = StreamingOutputCallRequest();
  req.payload = _payload(size);
  for (final s in respSizes) {
    final param = ResponseParameters();
    param.size = s;
    req.responseParameters.add(param);
  }
  return req;
}

Future<void> _expectError(
    int code, String what, Future<void> Function() call) async {
  try {
    await call();
  } on $grpc.GrpcError catch (e) {
    _check(e.code == code, '$what: code ${e.code} != $code');
    return;
  }
  throw StateError('$what: call succeeded, expected error $code');
}

Future<void> main(List<String> args) async {
  var host = '127.0.0.1';
  var port = 50051;
  var testCase = '';
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '-server_host':
        host = args[++i];
        break;
      case '--server_host':
        host = args[++i];
        break;
      case '-server_port':
        port = int.parse(args[++i]);
        break;
      case '--server_port':
        port = int.parse(args[++i]);
        break;
      case '-test_case':
        testCase = args[++i];
        break;
      case '--test_case':
        testCase = args[++i];
        break;
    }
  }
  final channel = $grpc.ClientChannel(
    host,
    port: port,
    options: const $grpc.ChannelOptions(
        credentials: $grpc.ChannelCredentials.insecure()),
  );
  final client = TestServiceClient(channel);
  try {
    switch (testCase) {
      case 'empty_unary':
        await client.emptyCall(Empty());
        break;
      case 'large_unary':
        {
          final req = SimpleRequest();
          req.responseSize = 31415;
          req.payload = _payload(271828);
          final resp = await client.unaryCall(req);
          _check(resp.payload.body.length == 31415, 'large_unary body');
        }
        break;
      case 'client_streaming':
        {
          final sizes = [27182, 8, 1828, 45904];
          final stream = Stream.fromIterable(sizes.map((s) {
            final r = StreamingInputCallRequest();
            r.payload = _payload(s);
            return r;
          }));
          final resp = await client.streamingInputCall(stream);
          _check(resp.aggregatedPayloadSize == 74922,
              'client_streaming aggregated ${resp.aggregatedPayloadSize}');
        }
        break;
      case 'server_streaming':
        {
          final sizes = [31415, 9, 2653, 58979];
          final respSizes = <int>[];
          await for (final resp
              in client.streamingOutputCall(_streamReq(0, sizes))) {
            respSizes.add(resp.payload.body.length);
          }
          _check(respSizes.toString() == sizes.toString(),
              'server_streaming sizes $respSizes');
        }
        break;
      case 'ping_pong':
        {
          final reqSizes = [27182, 8, 1828, 45904];
          final respSizes = [31415, 9, 2653, 58979];
          final controller = StreamController<StreamingOutputCallRequest>();
          final responses =
              client.fullDuplexCall(controller.stream).toList();
          for (var i = 0; i < reqSizes.length; i++) {
            controller.add(_streamReq(reqSizes[i], [respSizes[i]]));
          }
          await controller.close();
          final resps = await responses;
          _check(resps.length == respSizes.length, 'ping_pong count');
          for (var i = 0; i < resps.length; i++) {
            _check(resps[i].payload.body.length == respSizes[i],
                'ping_pong size $i');
          }
        }
        break;
      case 'empty_stream':
        {
          final resps = await client
              .fullDuplexCall(Stream<StreamingOutputCallRequest>.empty())
              .toList();
          _check(resps.isEmpty, 'empty_stream not empty');
        }
        break;
      case 'custom_metadata':
        {
          const initialKey = 'x-grpc-test-echo-initial';
          const trailingKey = 'x-grpc-test-echo-trailing-bin';
          final options = $grpc.CallOptions(metadata: {
            initialKey: 'test_initial_metadata_value',
            trailingKey: 'test_trailing_metadata_value',
          });
          String? initialSeen;
          String? trailingSeen;
          final call = client.unaryCall(
            SimpleRequest()..responseSize = 31415,
            options: options,
          );
          call.headers.then((h) => initialSeen = h[initialKey]);
          call.trailers.then((t) => trailingSeen = t[trailingKey]);
          await call;
          await null;
          _check(initialSeen == 'test_initial_metadata_value',
              'custom_metadata initial: $initialSeen');
          _check(trailingSeen == 'test_trailing_metadata_value',
              'custom_metadata trailing: $trailingSeen');
          // Streaming variant: metadata must echo on streams too.
          final streamCall = client.streamingOutputCall(
            _streamReq(0, [31415]),
            options: options,
          );
          await streamCall.toList();
        }
        break;
      case 'status_code_and_message':
        {
          final req = SimpleRequest();
          req.responseSize = 31415;
          req.responseStatus = EchoStatus()
            ..code = 2 // UNKNOWN
            ..message = 'test status message';
          await _expectError(2, 'status_code_and_message', () async {
            await client.unaryCall(req);
          });
          final req2 = _streamReq(0, [31415]);
          req2.responseStatus = EchoStatus()
            ..code = 2
            ..message = 'test status message';
          await _expectError(2, 'status_code_and_message streaming',
              () async {
            await client.streamingOutputCall(req2).toList();
          });
        }
        break;
      case 'special_status_message':
        {
          const msg = '\t\ntest with whitespace\r\nand Unicode BMP ☺ '
              'and non-BMP \u{1F600}';
          final req = SimpleRequest();
          req.responseStatus = EchoStatus()
            ..code = 2
            ..message = msg;
          try {
            await client.unaryCall(req);
            throw StateError('special_status_message: call succeeded');
          } on $grpc.GrpcError catch (e) {
            _check(e.code == 2, 'special_status_message code ${e.code}');
            _check(e.message == msg,
                'special_status_message message: ${e.message}');
          }
        }
        break;
      case 'unimplemented_method':
        await _expectError(12, 'unimplemented_method', () async {
          await client.unimplementedCall(Empty());
        });
        break;
      case 'unimplemented_service':
        {
          final unimpl = UnimplementedServiceClient(channel);
          await _expectError(12, 'unimplemented_service', () async {
            await unimpl.unimplementedCall(Empty());
          });
        }
        break;
      case 'cancel_after_begin':
        {
          final controller =
              StreamController<StreamingInputCallRequest>();
          final call = client.streamingInputCall(controller.stream);
          unawaited(call.cancel());
          await _expectError(1, 'cancel_after_begin', () async {
            await call;
          });
          unawaited(controller.close());
        }
        break;
      case 'cancel_after_first_response':
        {
          final controller = StreamController<StreamingOutputCallRequest>();
          final stream = client.fullDuplexCall(controller.stream);
          controller.add(_streamReq(27182, [31415]));
          final first = await stream.first;
          _check(first.payload.body.length == 31415,
              'cancel_after_first_response first size');
          // Cancelling the subscription must surface CANCELLED
          // on the server side; the client stream just ends.
          await controller.close();
        }
        break;
      case 'timeout_on_sleeping_server':
        {
          final req = _streamReq(27182, [31415]);
          req.responseParameters[0].intervalUs = 200000; // 200ms
          await _expectError(4, 'timeout_on_sleeping_server', () async {
            await client
                .fullDuplexCall(Stream.value(req),
                    options: $grpc.CallOptions(
                        timeout: const Duration(milliseconds: 1)))
                .toList();
          });
        }
        break;
      default:
        stderr.writeln('unknown test case: $testCase');
        exit(2);
    }
    print('Test completed.');
  } finally {
    await channel.shutdown();
  }
}
