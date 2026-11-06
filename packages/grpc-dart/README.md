# grpc_dc (Dart / Flutter)

gRPC over WebRTC DataChannels — a dependency-free generated
Dart runtime: client and server, all four call shapes
(unary, server/client streaming, bidi), deadlines, metadata,
and status over a single DataChannel. No `grpc` or WebRTC
package underneath; stub code is generated from your `.proto`
by the grpc-dc protoc plugins.

Install: `dart pub add grpc_dc` (or `flutter pub add grpc_dc`).

```dart
import 'package:grpc_dc/grpc_dc.dart';
```

See `example/example.dart` for a complete in-memory
client/server call. Transports: the main library is
platform-neutral (Flutter native + web, Dart VM). The
`dart:io` transports (HTTP/2, sidecar, git event bus) live
at `package:grpc_dc/grpcdc/http2_transport.dart` and
friends, imported directly on the VM; on the web (Flutter
web included) import
`package:grpc_dc/grpcdc/web_transport.dart` and hand
`WebTransport` your page's RTCDataChannel bridge
(`{send(Uint8Array), setOnMessage(cb)}`). Kafka stubs
ship separately
in the `kafka_grpc` package, which depends on this one.
