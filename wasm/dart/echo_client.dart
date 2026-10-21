// Browser entry point: the real Dart grpc_dc runtime (frame codec,
// endpoint multiplexer, generated Echo stub — no JS gRPC code).
// The same source builds two ways, since it only uses
// dart:js_interop: `dart compile js` (make test-dart-browser)
// and `dart compile wasm` (make test-dart-wasm-browser). The
// page only bridges its RTCDataChannel send/receive pair into
// the Dart transport, exactly like wasm/rust; unlike wasm/go,
// which is a facade over the JS implementation.
import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import '../../dart/grpcdc/channel.dart';
import '../../dart/grpcdc/status.dart';
import '../../dart/grpcdc/transport.dart';
import '../../dart/examples/echo_grpc_dc.dart';
import '../../dart/examples/echo_messages.dart';

/// The JS-side transport object passed in by the page:
/// `{ send(Uint8Array), setOnMessage(callback) }`.
extension type JsTransportJs._(JSObject _) implements JSObject {
  external void send(JSUint8Array data);
  external void setOnMessage(JSFunction callback);
}

/// DcTransport over the page's RTCDataChannel bridge.
class JsTransport implements Transport {
  final JsTransportJs _js;
  final StreamController<Uint8List> _controller = StreamController<Uint8List>();

  JsTransport(this._js) {
    _js.setOnMessage((JSUint8Array data) {
      if (!_controller.isClosed) {
        _controller.add(Uint8List.fromList(data.toDart));
      }
    }.toJS);
  }

  @override
  Stream<Uint8List> get onMessage => _controller.stream;

  @override
  void send(Uint8List data) => _js.send(data.toJS);

  @override
  Future<void> close() => _controller.close();
}

Future<String> runEcho(JsTransportJs jsTransport) async {
  final channel = Channel(JsTransport(jsTransport));
  final client = EchoClient(channel);

  Future<int> codeOf(Future<void> Function() run) async {
    try {
      await run();
      return 0;
    } on StatusException catch (e) {
      return e.code;
    }
  }

  final unary = await client.unary(EchoRequest('hello', 0));

  final ticks = <String>[];
  final serverStream = await client.serverStream(EchoRequest('tick', 3));
  await for (final resp in serverStream.responses) {
    ticks.add('${resp.message}#${resp.index}');
  }

  final joined = await client.clientStream(
      [EchoRequest('a', 0), EchoRequest('b', 0), EchoRequest('c', 0)]);

  final echoed = <String>[];
  final bidi = await client.bidi([EchoRequest('x', 0), EchoRequest('y', 0)]);
  await for (final resp in bidi.responses) {
    echoed.add(resp.message);
  }

  // BDD deepening: failure, metadata, unknown-method, cancel,
  // and deadline scenarios executed by this module.
  final unaryFailureCode = await codeOf(() async {
    await client.unary(EchoRequest('fail', 0));
  });
  final metadataResp =
      await client.unary(EchoRequest('hello', 0), metadata: {'x-echo': 'meta'});
  final serverStreamFailureCode = await codeOf(() async {
    final s = await client.serverStream(EchoRequest('fail', 3));
    await for (final _ in s.responses) {}
  });
  final bidiFailureCode = await codeOf(() async {
    final s = await client.bidi([EchoRequest('fail', 0)]);
    await for (final _ in s.responses) {}
  });
  final unknownMethodCode = await codeOf(() async {
    await channel.unary('/echo.Echo/Nope', EchoRequest('hello', 0), EchoResponse());
  });
  final cancelStream = await client.serverStream(EchoRequest('tick', 5));
  final cancelIter = StreamIterator(cancelStream.responses);
  final cancelFirst = await cancelIter.moveNext();
  await cancelIter.cancel().timeout(const Duration(seconds: 5));
  final deadlineCode = await codeOf(() async {
    await client.unary(EchoRequest('slow', 0, 600),
        timeout: const Duration(milliseconds: 100));
  });

  return jsonEncode({
    'unary': unary.message,
    'ticks': ticks,
    'joined': joined.message,
    'echoed': echoed,
    'unaryFailureCode': unaryFailureCode,
    'metadataMessage': metadataResp.message,
    'serverStreamFailureCode': serverStreamFailureCode,
    'bidiFailureCode': bidiFailureCode,
    'unknownMethodCode': unknownMethodCode,
    'cancelTerminated': cancelFirst,
    'deadlineCode': deadlineCode,
  });
}

void main() {
  // Page contract mirrors wasm/go's callback style:
  // window.runDartEchoClient(transport, resolve, reject).
  final entry = (JSObject transport, JSFunction resolve, JSFunction reject) {
    runEcho(transport as JsTransportJs).then(
      (json) => resolve.callAsFunction(null, json.toJS),
      onError: (Object e) => reject.callAsFunction(null, e.toString().toJS),
    );
  };
  globalContext.setProperty('runDartEchoClient'.toJS, entry.toJS);
}
