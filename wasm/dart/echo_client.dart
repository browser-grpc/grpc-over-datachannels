// Browser entry point: the real Dart grpc_dc runtime (frame codec,
// endpoint multiplexer, generated Echo stub — no JS gRPC code)
// compiled with `dart compile js`. The page only bridges its
// RTCDataChannel send/receive pair into the Dart transport, exactly
// like wasm/rust; unlike wasm/go, which is a facade over the JS
// implementation. Build: dart compile js wasm/dart/echo_client.dart
// -o browser-test/echo_dart.js (see `make test-dart-browser`).
import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import '../../dart/grpcdc/channel.dart';
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
  final client = EchoClient(Channel(JsTransport(jsTransport)));

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

  return jsonEncode({
    'unary': unary.message,
    'ticks': ticks,
    'joined': joined.message,
    'echoed': echoed,
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
