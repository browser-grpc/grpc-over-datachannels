//
//  Generated code. Do not modify.
//  source: xds/service/orca/v3/orca.proto
//
// @dart = 2.12

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_final_fields
// ignore_for_file: unnecessary_import, unnecessary_this, unused_import

import 'dart:async' as $async;
import 'dart:core' as $core;

import 'package:grpc/service_api.dart' as $grpc;
import 'package:protobuf/protobuf.dart' as $pb;

import '../../../data/orca/v3/orca_load_report.pb.dart' as $3;
import 'orca.pb.dart' as $2;

export 'orca.pb.dart';

@$pb.GrpcServiceName('xds.service.orca.v3.OpenRcaService')
class OpenRcaServiceClient extends $grpc.Client {
  static final _$streamCoreMetrics = $grpc.ClientMethod<$2.OrcaLoadReportRequest, $3.OrcaLoadReport>(
      '/xds.service.orca.v3.OpenRcaService/StreamCoreMetrics',
      ($2.OrcaLoadReportRequest value) => value.writeToBuffer(),
      ($core.List<$core.int> value) => $3.OrcaLoadReport.fromBuffer(value));

  OpenRcaServiceClient($grpc.ClientChannel channel,
      {$grpc.CallOptions? options,
      $core.Iterable<$grpc.ClientInterceptor>? interceptors})
      : super(channel, options: options,
        interceptors: interceptors);

  $grpc.ResponseStream<$3.OrcaLoadReport> streamCoreMetrics($2.OrcaLoadReportRequest request, {$grpc.CallOptions? options}) {
    return $createStreamingCall(_$streamCoreMetrics, $async.Stream.fromIterable([request]), options: options);
  }
}

@$pb.GrpcServiceName('xds.service.orca.v3.OpenRcaService')
abstract class OpenRcaServiceBase extends $grpc.Service {
  $core.String get $name => 'xds.service.orca.v3.OpenRcaService';

  OpenRcaServiceBase() {
    $addMethod($grpc.ServiceMethod<$2.OrcaLoadReportRequest, $3.OrcaLoadReport>(
        'StreamCoreMetrics',
        streamCoreMetrics_Pre,
        false,
        true,
        ($core.List<$core.int> value) => $2.OrcaLoadReportRequest.fromBuffer(value),
        ($3.OrcaLoadReport value) => value.writeToBuffer()));
  }

  $async.Stream<$3.OrcaLoadReport> streamCoreMetrics_Pre($grpc.ServiceCall call, $async.Future<$2.OrcaLoadReportRequest> request) async* {
    yield* streamCoreMetrics(call, await request);
  }

  $async.Stream<$3.OrcaLoadReport> streamCoreMetrics($grpc.ServiceCall call, $2.OrcaLoadReportRequest request);
}
