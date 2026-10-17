// Browser entry point (server role): the real Dart grpc_dc
// runtime (frame codec, endpoint multiplexer, generated Echo
// stub) serving over the page's RTCDataChannel bridge. Dart's
// runtime is async (Streams/Futures), so unlike the blocking
// worker runtimes the server runs event-driven on the page
// thread — no SharedArrayBuffer mailbox needed. The page only
// bridges its RTCDataChannel send/receive pair into the Dart
// transport. The Node test's JS client drives the four call
// shapes plus a deadline the slow handler must miss.
// Mirrors wasm/dart/echo_client.dart.

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import '../../dart/grpcdc/endpoint.dart';
import '../../dart/grpcdc/server.dart';
import '../../dart/grpcdc/transport.dart';
import '../../dart/examples/echo_grpc_dc.dart';
import '../../dart/examples/echo_messages.dart';
import '../../dart/examples/echo_service_impl.dart';

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

/// Echo impl with a delayed Unary so client deadlines fire.
class SlowEcho extends EchoServiceImpl {
  @override
  Future<EchoResponse> unary(CallContext ctx, EchoRequest req) async {
    if (req.delayMs > 0) {
      await Future<void>.delayed(Duration(milliseconds: req.delayMs));
    }
    return super.unary(ctx, req);
  }
}

/// Retained so the server and its endpoint outlive this call.
Server? _server;

void runEchoServer(JsTransportJs jsTransport) {
  final server = Server();
  EchoGrpcDc.registerEchoServer(server, SlowEcho());
  server.serveTransport(JsTransport(jsTransport));
  _server = server;
}

void main() {
  // Page contract mirrors the client's callback style:
  // window.runDartEchoServer(transport).
  final entry = (JSObject transport) {
    runEchoServer(transport as JsTransportJs);
  };
  globalContext.setProperty('runDartEchoServer'.toJS, entry.toJS);
}
