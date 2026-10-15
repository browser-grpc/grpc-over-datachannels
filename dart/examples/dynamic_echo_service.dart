import 'dart:async';

import '../grpcdc/dynamic.dart';
import '../grpcdc/endpoint.dart';
import '../grpcdc/status.dart';
import '../grpcdc/wire.dart';

/// Dynamic Echo implementation: the reference Echo semantics built
/// purely on the descriptor-driven runtime (no generated stubs).
/// Field numbers come from proto/echo.proto: EchoRequest{message=1,
/// count=2}, EchoResponse{message=1, index=2}.
class DynamicEchoService implements DynamicHandler {
  GenericMessage _response(MethodModel method, String message, int index) {
    return GenericMessage(method.output).set(1, message).set(2, index);
  }

  @override
  Future<GenericMessage> unary(
      CallContext ctx, MethodModel method, GenericMessage req) async {
    final message = req.getString(1);
    if (message == 'fail') {
      throw StatusException(Wire.codeInvalidArgument, 'asked to fail');
    }
    final marker = ctx.metadata['x-echo'];
    final suffix = (marker != null && marker.isNotEmpty) ? ' [$marker]' : '';
    return _response(method, 'echo: $message$suffix', 0);
  }

  @override
  Future<void> serverStream(CallContext ctx, MethodModel method,
      GenericMessage req, DynamicSendFn send) async {
    final count = req.getInt(2);
    for (var i = 0; i < count; i++) {
      await send(_response(method, req.getString(1), i));
    }
  }

  @override
  Future<GenericMessage> clientStream(
      CallContext ctx, MethodModel method, DynamicRecvFn recv) async {
    final parts = <String>[];
    while (true) {
      try {
        parts.add((await recv()).getString(1));
      } on EndOfStreamError {
        break;
      }
    }
    return _response(method, parts.join('+'), parts.length);
  }

  @override
  Future<void> bidi(CallContext ctx, MethodModel method, DynamicRecvFn recv,
      DynamicSendFn send) async {
    var index = 0;
    while (true) {
      final GenericMessage req;
      try {
        req = await recv();
      } on EndOfStreamError {
        return;
      }
      await send(_response(method, req.getString(1), index));
      index++;
    }
  }
}
