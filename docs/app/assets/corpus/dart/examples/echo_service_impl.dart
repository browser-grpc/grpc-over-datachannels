import 'dart:async';
import 'dart:math';

import '../grpcdc/endpoint.dart';
import '../grpcdc/status.dart';
import '../grpcdc/wire.dart';
import 'echo_grpc_dc.dart';
import 'echo_messages.dart';

/// Reference Echo implementation (mirrors the other language demos):
/// "fail" is rejected, everything else echoes.
class EchoServiceImpl implements EchoServer {
  @override
  Future<EchoResponse> unary(CallContext ctx, EchoRequest req) async {
    if (req.message == 'fail') {
      throw StatusException(Wire.codeInvalidArgument, 'asked to fail');
    }
    if (req.delayMs > 0) {
      await Future<void>.delayed(Duration(milliseconds: req.delayMs));
    }
    final marker = ctx.metadata['x-echo'];
    final suffix = (marker != null && marker.isNotEmpty) ? ' [$marker]' : '';
    return EchoResponse('echo: ${req.message}$suffix', 0);
  }

  @override
  Future<void> serverStream(EchoRequest req, EchoServerStreamServer stream) async {
    if (req.message == 'fail') {
      throw StatusException(Wire.codeInvalidArgument, 'asked to fail');
    }
    for (var i = 0; i < max(0, req.count); i++) {
      stream.send(EchoResponse(req.message, i));
    }
  }

  @override
  Future<void> clientStream(EchoClientStreamServer stream) async {
    final parts = <String>[];
    while (true) {
      try {
        final req = await stream.recv();
        if (req.message == 'fail') {
          throw StatusException(Wire.codeInvalidArgument, 'asked to fail');
        }
        parts.add(req.message);
      } on EndOfStreamError {
        break;
      }
    }
    stream.sendAndClose(EchoResponse(parts.join('+'), parts.length));
  }

  @override
  Future<void> bidi(EchoBidiServer stream) async {
    var index = 0;
    while (true) {
      final EchoRequest req;
      try {
        req = await stream.recv();
      } on EndOfStreamError {
        return;
      }
      if (req.message == 'fail') {
        throw StatusException(Wire.codeInvalidArgument, 'asked to fail');
      }
      stream.send(EchoResponse(req.message, index));
      index++;
    }
  }
}
