import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../grpcdc/endpoint.dart';
import '../grpcdc/status.dart';
import '../grpcdc/wire.dart';
import 'empty_messages.dart';
import 'messages_messages.dart';
import 'orca_grpc_dc.dart';
import 'orca_load_report_messages.dart';
import 'orca_messages.dart';
import 'test_grpc_dc.dart';

/// TestService implementation (grpc.testing) over the generated
/// Server, mirroring the reference TestServiceImpl semantics the
/// interop cases grade. Used by the Direction-B interop tests
/// (official clients vs generated servers). Mirrors
/// js/test/interop_service.js.
class InteropServiceImpl implements TestServiceServer, OpenRcaServiceServer {
  /// Latest ORCA out-of-band report (full-duplex updates).
  static OrcaLoadReport? oobReport;

  void _echoMetadata(CallContext ctx) {
    final initial = ctx.metadata['x-grpc-test-echo-initial'];
    if (initial != null) {
      ctx.setHeaders({'x-grpc-test-echo-initial': initial});
    }
    final trailing = ctx.metadata['x-grpc-test-echo-trailing-bin'];
    if (trailing != null) {
      ctx.setTrailers({'x-grpc-test-echo-trailing-bin': trailing});
    }
  }

  void _setOrcaTrailer(CallContext ctx, OrcaLoadReport report) {
    ctx.setTrailers({
      'endpoint-load-metrics-bin': base64Encode(report.marshalDc()),
    });
  }

  // Compression interop (server direction): the bridge
  // terminates gzip at the HTTP/2 hop and surfaces the
  // declared encoding as ordinary metadata.
  void _compressionChecks(CallContext ctx, BoolValue? expectCompressed,
      BoolValue? responseCompressed) {
    if (expectCompressed != null &&
        expectCompressed.value &&
        ctx.metadata['grpc-encoding'] != 'gzip') {
      throw StatusException(Wire.codeInvalidArgument,
          'expected compressed request, got uncompressed');
    }
    if (responseCompressed != null && responseCompressed.value) {
      ctx.setHeaders({'grpc-encoding': 'gzip'});
    }
  }

  void _maybeFail(EchoStatus? status) {
    if (status != null && (status.code != 0 || status.message.isNotEmpty)) {
      throw StatusException(status.code, status.message);
    }
  }

  SimpleResponse _unaryResponse(SimpleRequest req) {
    _maybeFail(req.responseStatus);
    final resp = SimpleResponse();
    resp.payload = Payload(req.responseType)
      ..body = Uint8List(req.responseSize < 0 ? 0 : req.responseSize);
    return resp;
  }

  Future<void> _sendResponses(StreamingOutputCallRequest req,
      void Function(StreamingOutputCallResponse) send) async {
    _maybeFail(req.responseStatus);
    var first = true;
    for (final param in req.responseParameters) {
      if (!first && param.intervalUs > 0) {
        await Future.delayed(Duration(microseconds: param.intervalUs));
      }
      first = false;
      send(StreamingOutputCallResponse(Payload(req.responseType)
        ..body = Uint8List(param.size < 0 ? 0 : param.size)));
    }
  }

  @override
  Future<Empty> emptyCall(CallContext ctx, Empty req) async {
    _echoMetadata(ctx);
    return Empty();
  }

  @override
  Future<SimpleResponse> unaryCall(CallContext ctx, SimpleRequest req) async {
    _echoMetadata(ctx);
    _compressionChecks(ctx, req.expectCompressed, req.responseCompressed);
    final perQuery = req.orcaPerQueryReport;
    if (perQuery != null) {
      _setOrcaTrailer(
          ctx,
          OrcaLoadReport(perQuery.cpuUtilization, perQuery.memoryUtilization, 0)
            ..requestCost = perQuery.requestCost
            ..utilization = perQuery.utilization);
    } else if (oobReport != null) {
      _setOrcaTrailer(ctx, oobReport!);
    }
    return _unaryResponse(req);
  }

  @override
  Future<SimpleResponse> cacheableUnaryCall(
      CallContext ctx, SimpleRequest req) async {
    _echoMetadata(ctx);
    _maybeFail(req.responseStatus);
    final resp = SimpleResponse();
    resp.payload = req.payload ?? Payload();
    return resp;
  }

  @override
  Future<void> streamingOutputCall(StreamingOutputCallRequest req,
      TestServiceStreamingOutputCallServer stream) async {
    _echoMetadata(stream.context);
    await _sendResponses(req, stream.send);
  }

  @override
  Future<void> streamingInputCall(
      TestServiceStreamingInputCallServer stream) async {
    _echoMetadata(stream.context);
    var total = 0;
    while (true) {
      final StreamingInputCallRequest req;
      try {
        req = await stream.recv();
      } on EndOfStreamError {
        break;
      }
      if (req.expectCompressed != null &&
          req.expectCompressed!.value &&
          stream.context.metadata['grpc-encoding'] != 'gzip') {
        throw StatusException(Wire.codeInvalidArgument,
            'expected compressed request, got uncompressed');
      }
      total += req.payload?.body.length ?? 0;
    }
    stream.sendAndClose(StreamingInputCallResponse(total));
  }

  @override
  Future<void> fullDuplexCall(TestServiceFullDuplexCallServer stream) async {
    _echoMetadata(stream.context);
    while (true) {
      final StreamingOutputCallRequest req;
      try {
        req = await stream.recv();
      } on EndOfStreamError {
        return;
      }
      final oob = req.orcaOobReport;
      if (oob != null) {
        oobReport = OrcaLoadReport(oob.cpuUtilization, oob.memoryUtilization, 0)
          ..utilization = oob.utilization;
      }
      await _sendResponses(req, stream.send);
    }
  }

  @override
  Future<void> halfDuplexCall(TestServiceHalfDuplexCallServer stream) async {
    _echoMetadata(stream.context);
    final collected = <StreamingOutputCallRequest>[];
    while (true) {
      try {
        collected.add(await stream.recv());
      } on EndOfStreamError {
        break;
      }
    }
    for (final req in collected) {
      await _sendResponses(req, stream.send);
    }
  }

  @override
  Future<Empty> unimplementedCall(CallContext ctx, Empty req) async {
    throw StatusException(Wire.codeUnimplemented, 'not implemented');
  }

  // OpenRcaService (ORCA out-of-band): stream the current OOB
  // report on an interval until the client goes away.
  @override
  Future<void> streamCoreMetrics(
      OrcaLoadReportRequest req, OpenRcaServiceStreamCoreMetricsServer stream) async {
    while (true) {
      stream.send(oobReport ?? OrcaLoadReport());
      await Future.delayed(const Duration(milliseconds: 200));
    }
  }
}
