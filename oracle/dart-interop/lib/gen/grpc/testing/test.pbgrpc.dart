//
//  Generated code. Do not modify.
//  source: grpc/testing/test.proto
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

import 'empty.pb.dart' as $0;
import 'messages.pb.dart' as $1;

export 'test.pb.dart';

@$pb.GrpcServiceName('grpc.testing.TestService')
class TestServiceClient extends $grpc.Client {
  static final _$emptyCall = $grpc.ClientMethod<$0.Empty, $0.Empty>(
      '/grpc.testing.TestService/EmptyCall',
      ($0.Empty value) => value.writeToBuffer(),
      ($core.List<$core.int> value) => $0.Empty.fromBuffer(value));
  static final _$unaryCall = $grpc.ClientMethod<$1.SimpleRequest, $1.SimpleResponse>(
      '/grpc.testing.TestService/UnaryCall',
      ($1.SimpleRequest value) => value.writeToBuffer(),
      ($core.List<$core.int> value) => $1.SimpleResponse.fromBuffer(value));
  static final _$cacheableUnaryCall = $grpc.ClientMethod<$1.SimpleRequest, $1.SimpleResponse>(
      '/grpc.testing.TestService/CacheableUnaryCall',
      ($1.SimpleRequest value) => value.writeToBuffer(),
      ($core.List<$core.int> value) => $1.SimpleResponse.fromBuffer(value));
  static final _$streamingOutputCall = $grpc.ClientMethod<$1.StreamingOutputCallRequest, $1.StreamingOutputCallResponse>(
      '/grpc.testing.TestService/StreamingOutputCall',
      ($1.StreamingOutputCallRequest value) => value.writeToBuffer(),
      ($core.List<$core.int> value) => $1.StreamingOutputCallResponse.fromBuffer(value));
  static final _$streamingInputCall = $grpc.ClientMethod<$1.StreamingInputCallRequest, $1.StreamingInputCallResponse>(
      '/grpc.testing.TestService/StreamingInputCall',
      ($1.StreamingInputCallRequest value) => value.writeToBuffer(),
      ($core.List<$core.int> value) => $1.StreamingInputCallResponse.fromBuffer(value));
  static final _$fullDuplexCall = $grpc.ClientMethod<$1.StreamingOutputCallRequest, $1.StreamingOutputCallResponse>(
      '/grpc.testing.TestService/FullDuplexCall',
      ($1.StreamingOutputCallRequest value) => value.writeToBuffer(),
      ($core.List<$core.int> value) => $1.StreamingOutputCallResponse.fromBuffer(value));
  static final _$halfDuplexCall = $grpc.ClientMethod<$1.StreamingOutputCallRequest, $1.StreamingOutputCallResponse>(
      '/grpc.testing.TestService/HalfDuplexCall',
      ($1.StreamingOutputCallRequest value) => value.writeToBuffer(),
      ($core.List<$core.int> value) => $1.StreamingOutputCallResponse.fromBuffer(value));
  static final _$unimplementedCall = $grpc.ClientMethod<$0.Empty, $0.Empty>(
      '/grpc.testing.TestService/UnimplementedCall',
      ($0.Empty value) => value.writeToBuffer(),
      ($core.List<$core.int> value) => $0.Empty.fromBuffer(value));

  TestServiceClient($grpc.ClientChannel channel,
      {$grpc.CallOptions? options,
      $core.Iterable<$grpc.ClientInterceptor>? interceptors})
      : super(channel, options: options,
        interceptors: interceptors);

  $grpc.ResponseFuture<$0.Empty> emptyCall($0.Empty request, {$grpc.CallOptions? options}) {
    return $createUnaryCall(_$emptyCall, request, options: options);
  }

  $grpc.ResponseFuture<$1.SimpleResponse> unaryCall($1.SimpleRequest request, {$grpc.CallOptions? options}) {
    return $createUnaryCall(_$unaryCall, request, options: options);
  }

  $grpc.ResponseFuture<$1.SimpleResponse> cacheableUnaryCall($1.SimpleRequest request, {$grpc.CallOptions? options}) {
    return $createUnaryCall(_$cacheableUnaryCall, request, options: options);
  }

  $grpc.ResponseStream<$1.StreamingOutputCallResponse> streamingOutputCall($1.StreamingOutputCallRequest request, {$grpc.CallOptions? options}) {
    return $createStreamingCall(_$streamingOutputCall, $async.Stream.fromIterable([request]), options: options);
  }

  $grpc.ResponseFuture<$1.StreamingInputCallResponse> streamingInputCall($async.Stream<$1.StreamingInputCallRequest> request, {$grpc.CallOptions? options}) {
    return $createStreamingCall(_$streamingInputCall, request, options: options).single;
  }

  $grpc.ResponseStream<$1.StreamingOutputCallResponse> fullDuplexCall($async.Stream<$1.StreamingOutputCallRequest> request, {$grpc.CallOptions? options}) {
    return $createStreamingCall(_$fullDuplexCall, request, options: options);
  }

  $grpc.ResponseStream<$1.StreamingOutputCallResponse> halfDuplexCall($async.Stream<$1.StreamingOutputCallRequest> request, {$grpc.CallOptions? options}) {
    return $createStreamingCall(_$halfDuplexCall, request, options: options);
  }

  $grpc.ResponseFuture<$0.Empty> unimplementedCall($0.Empty request, {$grpc.CallOptions? options}) {
    return $createUnaryCall(_$unimplementedCall, request, options: options);
  }
}

@$pb.GrpcServiceName('grpc.testing.TestService')
abstract class TestServiceBase extends $grpc.Service {
  $core.String get $name => 'grpc.testing.TestService';

  TestServiceBase() {
    $addMethod($grpc.ServiceMethod<$0.Empty, $0.Empty>(
        'EmptyCall',
        emptyCall_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.Empty.fromBuffer(value),
        ($0.Empty value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$1.SimpleRequest, $1.SimpleResponse>(
        'UnaryCall',
        unaryCall_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $1.SimpleRequest.fromBuffer(value),
        ($1.SimpleResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$1.SimpleRequest, $1.SimpleResponse>(
        'CacheableUnaryCall',
        cacheableUnaryCall_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $1.SimpleRequest.fromBuffer(value),
        ($1.SimpleResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$1.StreamingOutputCallRequest, $1.StreamingOutputCallResponse>(
        'StreamingOutputCall',
        streamingOutputCall_Pre,
        false,
        true,
        ($core.List<$core.int> value) => $1.StreamingOutputCallRequest.fromBuffer(value),
        ($1.StreamingOutputCallResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$1.StreamingInputCallRequest, $1.StreamingInputCallResponse>(
        'StreamingInputCall',
        streamingInputCall,
        true,
        false,
        ($core.List<$core.int> value) => $1.StreamingInputCallRequest.fromBuffer(value),
        ($1.StreamingInputCallResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$1.StreamingOutputCallRequest, $1.StreamingOutputCallResponse>(
        'FullDuplexCall',
        fullDuplexCall,
        true,
        true,
        ($core.List<$core.int> value) => $1.StreamingOutputCallRequest.fromBuffer(value),
        ($1.StreamingOutputCallResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$1.StreamingOutputCallRequest, $1.StreamingOutputCallResponse>(
        'HalfDuplexCall',
        halfDuplexCall,
        true,
        true,
        ($core.List<$core.int> value) => $1.StreamingOutputCallRequest.fromBuffer(value),
        ($1.StreamingOutputCallResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.Empty, $0.Empty>(
        'UnimplementedCall',
        unimplementedCall_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.Empty.fromBuffer(value),
        ($0.Empty value) => value.writeToBuffer()));
  }

  $async.Future<$0.Empty> emptyCall_Pre($grpc.ServiceCall call, $async.Future<$0.Empty> request) async {
    return emptyCall(call, await request);
  }

  $async.Future<$1.SimpleResponse> unaryCall_Pre($grpc.ServiceCall call, $async.Future<$1.SimpleRequest> request) async {
    return unaryCall(call, await request);
  }

  $async.Future<$1.SimpleResponse> cacheableUnaryCall_Pre($grpc.ServiceCall call, $async.Future<$1.SimpleRequest> request) async {
    return cacheableUnaryCall(call, await request);
  }

  $async.Stream<$1.StreamingOutputCallResponse> streamingOutputCall_Pre($grpc.ServiceCall call, $async.Future<$1.StreamingOutputCallRequest> request) async* {
    yield* streamingOutputCall(call, await request);
  }

  $async.Future<$0.Empty> unimplementedCall_Pre($grpc.ServiceCall call, $async.Future<$0.Empty> request) async {
    return unimplementedCall(call, await request);
  }

  $async.Future<$0.Empty> emptyCall($grpc.ServiceCall call, $0.Empty request);
  $async.Future<$1.SimpleResponse> unaryCall($grpc.ServiceCall call, $1.SimpleRequest request);
  $async.Future<$1.SimpleResponse> cacheableUnaryCall($grpc.ServiceCall call, $1.SimpleRequest request);
  $async.Stream<$1.StreamingOutputCallResponse> streamingOutputCall($grpc.ServiceCall call, $1.StreamingOutputCallRequest request);
  $async.Future<$1.StreamingInputCallResponse> streamingInputCall($grpc.ServiceCall call, $async.Stream<$1.StreamingInputCallRequest> request);
  $async.Stream<$1.StreamingOutputCallResponse> fullDuplexCall($grpc.ServiceCall call, $async.Stream<$1.StreamingOutputCallRequest> request);
  $async.Stream<$1.StreamingOutputCallResponse> halfDuplexCall($grpc.ServiceCall call, $async.Stream<$1.StreamingOutputCallRequest> request);
  $async.Future<$0.Empty> unimplementedCall($grpc.ServiceCall call, $0.Empty request);
}
@$pb.GrpcServiceName('grpc.testing.UnimplementedService')
class UnimplementedServiceClient extends $grpc.Client {
  static final _$unimplementedCall = $grpc.ClientMethod<$0.Empty, $0.Empty>(
      '/grpc.testing.UnimplementedService/UnimplementedCall',
      ($0.Empty value) => value.writeToBuffer(),
      ($core.List<$core.int> value) => $0.Empty.fromBuffer(value));

  UnimplementedServiceClient($grpc.ClientChannel channel,
      {$grpc.CallOptions? options,
      $core.Iterable<$grpc.ClientInterceptor>? interceptors})
      : super(channel, options: options,
        interceptors: interceptors);

  $grpc.ResponseFuture<$0.Empty> unimplementedCall($0.Empty request, {$grpc.CallOptions? options}) {
    return $createUnaryCall(_$unimplementedCall, request, options: options);
  }
}

@$pb.GrpcServiceName('grpc.testing.UnimplementedService')
abstract class UnimplementedServiceBase extends $grpc.Service {
  $core.String get $name => 'grpc.testing.UnimplementedService';

  UnimplementedServiceBase() {
    $addMethod($grpc.ServiceMethod<$0.Empty, $0.Empty>(
        'UnimplementedCall',
        unimplementedCall_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.Empty.fromBuffer(value),
        ($0.Empty value) => value.writeToBuffer()));
  }

  $async.Future<$0.Empty> unimplementedCall_Pre($grpc.ServiceCall call, $async.Future<$0.Empty> request) async {
    return unimplementedCall(call, await request);
  }

  $async.Future<$0.Empty> unimplementedCall($grpc.ServiceCall call, $0.Empty request);
}
@$pb.GrpcServiceName('grpc.testing.ReconnectService')
class ReconnectServiceClient extends $grpc.Client {
  static final _$start = $grpc.ClientMethod<$1.ReconnectParams, $0.Empty>(
      '/grpc.testing.ReconnectService/Start',
      ($1.ReconnectParams value) => value.writeToBuffer(),
      ($core.List<$core.int> value) => $0.Empty.fromBuffer(value));
  static final _$stop = $grpc.ClientMethod<$0.Empty, $1.ReconnectInfo>(
      '/grpc.testing.ReconnectService/Stop',
      ($0.Empty value) => value.writeToBuffer(),
      ($core.List<$core.int> value) => $1.ReconnectInfo.fromBuffer(value));

  ReconnectServiceClient($grpc.ClientChannel channel,
      {$grpc.CallOptions? options,
      $core.Iterable<$grpc.ClientInterceptor>? interceptors})
      : super(channel, options: options,
        interceptors: interceptors);

  $grpc.ResponseFuture<$0.Empty> start($1.ReconnectParams request, {$grpc.CallOptions? options}) {
    return $createUnaryCall(_$start, request, options: options);
  }

  $grpc.ResponseFuture<$1.ReconnectInfo> stop($0.Empty request, {$grpc.CallOptions? options}) {
    return $createUnaryCall(_$stop, request, options: options);
  }
}

@$pb.GrpcServiceName('grpc.testing.ReconnectService')
abstract class ReconnectServiceBase extends $grpc.Service {
  $core.String get $name => 'grpc.testing.ReconnectService';

  ReconnectServiceBase() {
    $addMethod($grpc.ServiceMethod<$1.ReconnectParams, $0.Empty>(
        'Start',
        start_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $1.ReconnectParams.fromBuffer(value),
        ($0.Empty value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.Empty, $1.ReconnectInfo>(
        'Stop',
        stop_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.Empty.fromBuffer(value),
        ($1.ReconnectInfo value) => value.writeToBuffer()));
  }

  $async.Future<$0.Empty> start_Pre($grpc.ServiceCall call, $async.Future<$1.ReconnectParams> request) async {
    return start(call, await request);
  }

  $async.Future<$1.ReconnectInfo> stop_Pre($grpc.ServiceCall call, $async.Future<$0.Empty> request) async {
    return stop(call, await request);
  }

  $async.Future<$0.Empty> start($grpc.ServiceCall call, $1.ReconnectParams request);
  $async.Future<$1.ReconnectInfo> stop($grpc.ServiceCall call, $0.Empty request);
}
@$pb.GrpcServiceName('grpc.testing.LoadBalancerStatsService')
class LoadBalancerStatsServiceClient extends $grpc.Client {
  static final _$getClientStats = $grpc.ClientMethod<$1.LoadBalancerStatsRequest, $1.LoadBalancerStatsResponse>(
      '/grpc.testing.LoadBalancerStatsService/GetClientStats',
      ($1.LoadBalancerStatsRequest value) => value.writeToBuffer(),
      ($core.List<$core.int> value) => $1.LoadBalancerStatsResponse.fromBuffer(value));
  static final _$getClientAccumulatedStats = $grpc.ClientMethod<$1.LoadBalancerAccumulatedStatsRequest, $1.LoadBalancerAccumulatedStatsResponse>(
      '/grpc.testing.LoadBalancerStatsService/GetClientAccumulatedStats',
      ($1.LoadBalancerAccumulatedStatsRequest value) => value.writeToBuffer(),
      ($core.List<$core.int> value) => $1.LoadBalancerAccumulatedStatsResponse.fromBuffer(value));

  LoadBalancerStatsServiceClient($grpc.ClientChannel channel,
      {$grpc.CallOptions? options,
      $core.Iterable<$grpc.ClientInterceptor>? interceptors})
      : super(channel, options: options,
        interceptors: interceptors);

  $grpc.ResponseFuture<$1.LoadBalancerStatsResponse> getClientStats($1.LoadBalancerStatsRequest request, {$grpc.CallOptions? options}) {
    return $createUnaryCall(_$getClientStats, request, options: options);
  }

  $grpc.ResponseFuture<$1.LoadBalancerAccumulatedStatsResponse> getClientAccumulatedStats($1.LoadBalancerAccumulatedStatsRequest request, {$grpc.CallOptions? options}) {
    return $createUnaryCall(_$getClientAccumulatedStats, request, options: options);
  }
}

@$pb.GrpcServiceName('grpc.testing.LoadBalancerStatsService')
abstract class LoadBalancerStatsServiceBase extends $grpc.Service {
  $core.String get $name => 'grpc.testing.LoadBalancerStatsService';

  LoadBalancerStatsServiceBase() {
    $addMethod($grpc.ServiceMethod<$1.LoadBalancerStatsRequest, $1.LoadBalancerStatsResponse>(
        'GetClientStats',
        getClientStats_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $1.LoadBalancerStatsRequest.fromBuffer(value),
        ($1.LoadBalancerStatsResponse value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$1.LoadBalancerAccumulatedStatsRequest, $1.LoadBalancerAccumulatedStatsResponse>(
        'GetClientAccumulatedStats',
        getClientAccumulatedStats_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $1.LoadBalancerAccumulatedStatsRequest.fromBuffer(value),
        ($1.LoadBalancerAccumulatedStatsResponse value) => value.writeToBuffer()));
  }

  $async.Future<$1.LoadBalancerStatsResponse> getClientStats_Pre($grpc.ServiceCall call, $async.Future<$1.LoadBalancerStatsRequest> request) async {
    return getClientStats(call, await request);
  }

  $async.Future<$1.LoadBalancerAccumulatedStatsResponse> getClientAccumulatedStats_Pre($grpc.ServiceCall call, $async.Future<$1.LoadBalancerAccumulatedStatsRequest> request) async {
    return getClientAccumulatedStats(call, await request);
  }

  $async.Future<$1.LoadBalancerStatsResponse> getClientStats($grpc.ServiceCall call, $1.LoadBalancerStatsRequest request);
  $async.Future<$1.LoadBalancerAccumulatedStatsResponse> getClientAccumulatedStats($grpc.ServiceCall call, $1.LoadBalancerAccumulatedStatsRequest request);
}
@$pb.GrpcServiceName('grpc.testing.XdsUpdateHealthService')
class XdsUpdateHealthServiceClient extends $grpc.Client {
  static final _$setServing = $grpc.ClientMethod<$0.Empty, $0.Empty>(
      '/grpc.testing.XdsUpdateHealthService/SetServing',
      ($0.Empty value) => value.writeToBuffer(),
      ($core.List<$core.int> value) => $0.Empty.fromBuffer(value));
  static final _$setNotServing = $grpc.ClientMethod<$0.Empty, $0.Empty>(
      '/grpc.testing.XdsUpdateHealthService/SetNotServing',
      ($0.Empty value) => value.writeToBuffer(),
      ($core.List<$core.int> value) => $0.Empty.fromBuffer(value));

  XdsUpdateHealthServiceClient($grpc.ClientChannel channel,
      {$grpc.CallOptions? options,
      $core.Iterable<$grpc.ClientInterceptor>? interceptors})
      : super(channel, options: options,
        interceptors: interceptors);

  $grpc.ResponseFuture<$0.Empty> setServing($0.Empty request, {$grpc.CallOptions? options}) {
    return $createUnaryCall(_$setServing, request, options: options);
  }

  $grpc.ResponseFuture<$0.Empty> setNotServing($0.Empty request, {$grpc.CallOptions? options}) {
    return $createUnaryCall(_$setNotServing, request, options: options);
  }
}

@$pb.GrpcServiceName('grpc.testing.XdsUpdateHealthService')
abstract class XdsUpdateHealthServiceBase extends $grpc.Service {
  $core.String get $name => 'grpc.testing.XdsUpdateHealthService';

  XdsUpdateHealthServiceBase() {
    $addMethod($grpc.ServiceMethod<$0.Empty, $0.Empty>(
        'SetServing',
        setServing_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.Empty.fromBuffer(value),
        ($0.Empty value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.Empty, $0.Empty>(
        'SetNotServing',
        setNotServing_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.Empty.fromBuffer(value),
        ($0.Empty value) => value.writeToBuffer()));
  }

  $async.Future<$0.Empty> setServing_Pre($grpc.ServiceCall call, $async.Future<$0.Empty> request) async {
    return setServing(call, await request);
  }

  $async.Future<$0.Empty> setNotServing_Pre($grpc.ServiceCall call, $async.Future<$0.Empty> request) async {
    return setNotServing(call, await request);
  }

  $async.Future<$0.Empty> setServing($grpc.ServiceCall call, $0.Empty request);
  $async.Future<$0.Empty> setNotServing($grpc.ServiceCall call, $0.Empty request);
}
@$pb.GrpcServiceName('grpc.testing.XdsUpdateClientConfigureService')
class XdsUpdateClientConfigureServiceClient extends $grpc.Client {
  static final _$configure = $grpc.ClientMethod<$1.ClientConfigureRequest, $1.ClientConfigureResponse>(
      '/grpc.testing.XdsUpdateClientConfigureService/Configure',
      ($1.ClientConfigureRequest value) => value.writeToBuffer(),
      ($core.List<$core.int> value) => $1.ClientConfigureResponse.fromBuffer(value));

  XdsUpdateClientConfigureServiceClient($grpc.ClientChannel channel,
      {$grpc.CallOptions? options,
      $core.Iterable<$grpc.ClientInterceptor>? interceptors})
      : super(channel, options: options,
        interceptors: interceptors);

  $grpc.ResponseFuture<$1.ClientConfigureResponse> configure($1.ClientConfigureRequest request, {$grpc.CallOptions? options}) {
    return $createUnaryCall(_$configure, request, options: options);
  }
}

@$pb.GrpcServiceName('grpc.testing.XdsUpdateClientConfigureService')
abstract class XdsUpdateClientConfigureServiceBase extends $grpc.Service {
  $core.String get $name => 'grpc.testing.XdsUpdateClientConfigureService';

  XdsUpdateClientConfigureServiceBase() {
    $addMethod($grpc.ServiceMethod<$1.ClientConfigureRequest, $1.ClientConfigureResponse>(
        'Configure',
        configure_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $1.ClientConfigureRequest.fromBuffer(value),
        ($1.ClientConfigureResponse value) => value.writeToBuffer()));
  }

  $async.Future<$1.ClientConfigureResponse> configure_Pre($grpc.ServiceCall call, $async.Future<$1.ClientConfigureRequest> request) async {
    return configure(call, await request);
  }

  $async.Future<$1.ClientConfigureResponse> configure($grpc.ServiceCall call, $1.ClientConfigureRequest request);
}
