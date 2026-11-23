// Canonical grpc interop TestService implementation over
// google's grpc-dart runtime (package:grpc), mirroring the
// grpc-java/grpc-go interop servers in oracle/java and
// oracle/go-interop. Covers the shared case set the
// cross-language oracle suites run (the 14 cases in
// _cases lists): empty/large unary, streaming shapes,
// metadata echo, status cases, cancellation, and timeout.

import 'dart:async';
import 'dart:typed_data';

import 'package:grpc/grpc.dart' as $grpc;

import 'gen/grpc/testing/empty.pb.dart';
import 'gen/grpc/testing/messages.pb.dart';
import 'gen/grpc/testing/test.pbgrpc.dart';

Payload _sizedPayload(int size) {
  final p = Payload();
  p.body = Uint8List(size);
  return p;
}

void _throwIfStatus(EchoStatus? status) {
  if (status != null && status.code != 0) {
    throw $grpc.GrpcError.custom(status.code, status.message);
  }
}

/// Echo the canonical custom-metadata keys, if present:
/// x-grpc-test-echo-initial goes to headers,
/// x-grpc-test-echo-trailing-bin goes to trailers.
void _echoMetadata($grpc.ServiceCall call) {
  final md = call.clientMetadata ?? const <String, String>{};
  final initial = md['x-grpc-test-echo-initial'];
  final headers = call.headers;
  if (initial != null && headers != null) {
    headers['x-grpc-test-echo-initial'] = initial;
  }
  final trailing = md['x-grpc-test-echo-trailing-bin'];
  final trailers = call.trailers;
  if (trailing != null && trailers != null) {
    trailers['x-grpc-test-echo-trailing-bin'] = trailing;
  }
}

class TestService extends TestServiceBase {
  @override
  Future<Empty> emptyCall($grpc.ServiceCall call, Empty request) async {
    _echoMetadata(call);
    return Empty();
  }

  @override
  Future<SimpleResponse> unaryCall(
      $grpc.ServiceCall call, SimpleRequest request) async {
    _echoMetadata(call);
    _throwIfStatus(request.hasResponseStatus() ? request.responseStatus : null);
    final resp = SimpleResponse();
    resp.payload = _sizedPayload(request.responseSize);
    if (request.hasFillUsername() && request.fillUsername) {
      resp.username = 'interop-dart';
    }
    if (request.hasFillOauthScope() && request.fillOauthScope) {
      resp.oauthScope = 'interop';
    }
    return resp;
  }

  @override
  Future<SimpleResponse> cacheableUnaryCall(
      $grpc.ServiceCall call, SimpleRequest request) async {
    // No caching proxy in this topology; same as unaryCall.
    return unaryCall(call, request);
  }

  @override
  Stream<StreamingOutputCallResponse> streamingOutputCall(
      $grpc.ServiceCall call, StreamingOutputCallRequest request) async* {
    _echoMetadata(call);
    _throwIfStatus(
        request.hasResponseStatus() ? request.responseStatus : null);
    for (final param in request.responseParameters) {
      if (param.hasIntervalUs() && param.intervalUs > 0) {
        await Future<void>.delayed(
            Duration(microseconds: param.intervalUs));
      }
      final resp = StreamingOutputCallResponse();
      resp.payload = _sizedPayload(param.size);
      yield resp;
    }
  }

  @override
  Future<StreamingInputCallResponse> streamingInputCall(
      $grpc.ServiceCall call, Stream<StreamingInputCallRequest> request) async {
    _echoMetadata(call);
    var total = 0;
    await for (final req in request) {
      total += req.hasPayload() ? req.payload.body.length : 0;
    }
    final resp = StreamingInputCallResponse();
    resp.aggregatedPayloadSize = total;
    return resp;
  }

  @override
  Stream<StreamingOutputCallResponse> fullDuplexCall(
      $grpc.ServiceCall call, Stream<StreamingOutputCallRequest> request) async* {
    _echoMetadata(call);
    await for (final req in request) {
      _throwIfStatus(req.hasResponseStatus() ? req.responseStatus : null);
      for (final param in req.responseParameters) {
        if (param.hasIntervalUs() && param.intervalUs > 0) {
          await Future<void>.delayed(
              Duration(microseconds: param.intervalUs));
        }
        final resp = StreamingOutputCallResponse();
        resp.payload = _sizedPayload(param.size);
        yield resp;
      }
    }
  }

  @override
  Stream<StreamingOutputCallResponse> halfDuplexCall(
      $grpc.ServiceCall call, Stream<StreamingOutputCallRequest> request) async* {
    _echoMetadata(call);
    final reqs = await request.toList();
    for (final req in reqs) {
      _throwIfStatus(req.hasResponseStatus() ? req.responseStatus : null);
      for (final param in req.responseParameters) {
        final resp = StreamingOutputCallResponse();
        resp.payload = _sizedPayload(param.size);
        yield resp;
      }
    }
  }

  @override
  Future<Empty> unimplementedCall(
      $grpc.ServiceCall call, Empty request) async {
    throw $grpc.GrpcError.unimplemented('unimplementedCall not implemented');
  }
}
