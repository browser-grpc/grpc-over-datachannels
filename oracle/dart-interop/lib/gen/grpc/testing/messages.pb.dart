//
//  Generated code. Do not modify.
//  source: grpc/testing/messages.proto
//
// @dart = 2.12

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_final_fields
// ignore_for_file: unnecessary_import, unnecessary_this, unused_import

import 'dart:core' as $core;

import 'package:protobuf/protobuf.dart' as $pb;

import 'messages.pbenum.dart';

export 'messages.pbenum.dart';

/// TODO(dgq): Go back to using well-known types once
/// https://github.com/grpc/grpc/issues/6980 has been fixed.
/// import "google/protobuf/wrappers.proto";
class BoolValue extends $pb.GeneratedMessage {
  factory BoolValue({
    $core.bool? value,
  }) {
    final $result = create();
    if (value != null) {
      $result.value = value;
    }
    return $result;
  }
  BoolValue._() : super();
  factory BoolValue.fromBuffer($core.List<$core.int> i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromBuffer(i, r);
  factory BoolValue.fromJson($core.String i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'BoolValue', package: const $pb.PackageName(_omitMessageNames ? '' : 'grpc.testing'), createEmptyInstance: create)
    ..aOB(1, _omitFieldNames ? '' : 'value')
    ..hasRequiredFields = false
  ;

  @$core.Deprecated(
  'Using this can add significant overhead to your binary. '
  'Use [GeneratedMessageGenericExtensions.deepCopy] instead. '
  'Will be removed in next major version')
  BoolValue clone() => BoolValue()..mergeFromMessage(this);
  @$core.Deprecated(
  'Using this can add significant overhead to your binary. '
  'Use [GeneratedMessageGenericExtensions.rebuild] instead. '
  'Will be removed in next major version')
  BoolValue copyWith(void Function(BoolValue) updates) => super.copyWith((message) => updates(message as BoolValue)) as BoolValue;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static BoolValue create() => BoolValue._();
  BoolValue createEmptyInstance() => create();
  static $pb.PbList<BoolValue> createRepeated() => $pb.PbList<BoolValue>();
  @$core.pragma('dart2js:noInline')
  static BoolValue getDefault() => _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<BoolValue>(create);
  static BoolValue? _defaultInstance;

  /// The bool value.
  @$pb.TagNumber(1)
  $core.bool get value => $_getBF(0);
  @$pb.TagNumber(1)
  set value($core.bool v) { $_setBool(0, v); }
  @$pb.TagNumber(1)
  $core.bool hasValue() => $_has(0);
  @$pb.TagNumber(1)
  void clearValue() => clearField(1);
}

/// A block of data, to simply increase gRPC message size.
class Payload extends $pb.GeneratedMessage {
  factory Payload({
    PayloadType? type,
    $core.List<$core.int>? body,
  }) {
    final $result = create();
    if (type != null) {
      $result.type = type;
    }
    if (body != null) {
      $result.body = body;
    }
    return $result;
  }
  Payload._() : super();
  factory Payload.fromBuffer($core.List<$core.int> i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromBuffer(i, r);
  factory Payload.fromJson($core.String i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'Payload', package: const $pb.PackageName(_omitMessageNames ? '' : 'grpc.testing'), createEmptyInstance: create)
    ..e<PayloadType>(1, _omitFieldNames ? '' : 'type', $pb.PbFieldType.OE, defaultOrMaker: PayloadType.COMPRESSABLE, valueOf: PayloadType.valueOf, enumValues: PayloadType.values)
    ..a<$core.List<$core.int>>(2, _omitFieldNames ? '' : 'body', $pb.PbFieldType.OY)
    ..hasRequiredFields = false
  ;

  @$core.Deprecated(
  'Using this can add significant overhead to your binary. '
  'Use [GeneratedMessageGenericExtensions.deepCopy] instead. '
  'Will be removed in next major version')
  Payload clone() => Payload()..mergeFromMessage(this);
  @$core.Deprecated(
  'Using this can add significant overhead to your binary. '
  'Use [GeneratedMessageGenericExtensions.rebuild] instead. '
  'Will be removed in next major version')
  Payload copyWith(void Function(Payload) updates) => super.copyWith((message) => updates(message as Payload)) as Payload;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static Payload create() => Payload._();
  Payload createEmptyInstance() => create();
  static $pb.PbList<Payload> createRepeated() => $pb.PbList<Payload>();
  @$core.pragma('dart2js:noInline')
  static Payload getDefault() => _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<Payload>(create);
  static Payload? _defaultInstance;

  /// The type of data in body.
  @$pb.TagNumber(1)
  PayloadType get type => $_getN(0);
  @$pb.TagNumber(1)
  set type(PayloadType v) { setField(1, v); }
  @$pb.TagNumber(1)
  $core.bool hasType() => $_has(0);
  @$pb.TagNumber(1)
  void clearType() => clearField(1);

  /// Primary contents of payload.
  @$pb.TagNumber(2)
  $core.List<$core.int> get body => $_getN(1);
  @$pb.TagNumber(2)
  set body($core.List<$core.int> v) { $_setBytes(1, v); }
  @$pb.TagNumber(2)
  $core.bool hasBody() => $_has(1);
  @$pb.TagNumber(2)
  void clearBody() => clearField(2);
}

/// A protobuf representation for grpc status. This is used by test
/// clients to specify a status that the server should attempt to return.
class EchoStatus extends $pb.GeneratedMessage {
  factory EchoStatus({
    $core.int? code,
    $core.String? message,
  }) {
    final $result = create();
    if (code != null) {
      $result.code = code;
    }
    if (message != null) {
      $result.message = message;
    }
    return $result;
  }
  EchoStatus._() : super();
  factory EchoStatus.fromBuffer($core.List<$core.int> i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromBuffer(i, r);
  factory EchoStatus.fromJson($core.String i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'EchoStatus', package: const $pb.PackageName(_omitMessageNames ? '' : 'grpc.testing'), createEmptyInstance: create)
    ..a<$core.int>(1, _omitFieldNames ? '' : 'code', $pb.PbFieldType.O3)
    ..aOS(2, _omitFieldNames ? '' : 'message')
    ..hasRequiredFields = false
  ;

  @$core.Deprecated(
  'Using this can add significant overhead to your binary. '
  'Use [GeneratedMessageGenericExtensions.deepCopy] instead. '
  'Will be removed in next major version')
  EchoStatus clone() => EchoStatus()..mergeFromMessage(this);
  @$core.Deprecated(
  'Using this can add significant overhead to your binary. '
  'Use [GeneratedMessageGenericExtensions.rebuild] instead. '
  'Will be removed in next major version')
  EchoStatus copyWith(void Function(EchoStatus) updates) => super.copyWith((message) => updates(message as EchoStatus)) as EchoStatus;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static EchoStatus create() => EchoStatus._();
  EchoStatus createEmptyInstance() => create();
  static $pb.PbList<EchoStatus> createRepeated() => $pb.PbList<EchoStatus>();
  @$core.pragma('dart2js:noInline')
  static EchoStatus getDefault() => _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<EchoStatus>(create);
  static EchoStatus? _defaultInstance;

  @$pb.TagNumber(1)
  $core.int get code => $_getIZ(0);
  @$pb.TagNumber(1)
  set code($core.int v) { $_setSignedInt32(0, v); }
  @$pb.TagNumber(1)
  $core.bool hasCode() => $_has(0);
  @$pb.TagNumber(1)
  void clearCode() => clearField(1);

  @$pb.TagNumber(2)
  $core.String get message => $_getSZ(1);
  @$pb.TagNumber(2)
  set message($core.String v) { $_setString(1, v); }
  @$pb.TagNumber(2)
  $core.bool hasMessage() => $_has(1);
  @$pb.TagNumber(2)
  void clearMessage() => clearField(2);
}

/// Unary request.
class SimpleRequest extends $pb.GeneratedMessage {
  factory SimpleRequest({
    PayloadType? responseType,
    $core.int? responseSize,
    Payload? payload,
    $core.bool? fillUsername,
    $core.bool? fillOauthScope,
    BoolValue? responseCompressed,
    EchoStatus? responseStatus,
    BoolValue? expectCompressed,
    $core.bool? fillServerId,
    $core.bool? fillGrpclbRouteType,
    TestOrcaReport? orcaPerQueryReport,
  }) {
    final $result = create();
    if (responseType != null) {
      $result.responseType = responseType;
    }
    if (responseSize != null) {
      $result.responseSize = responseSize;
    }
    if (payload != null) {
      $result.payload = payload;
    }
    if (fillUsername != null) {
      $result.fillUsername = fillUsername;
    }
    if (fillOauthScope != null) {
      $result.fillOauthScope = fillOauthScope;
    }
    if (responseCompressed != null) {
      $result.responseCompressed = responseCompressed;
    }
    if (responseStatus != null) {
      $result.responseStatus = responseStatus;
    }
    if (expectCompressed != null) {
      $result.expectCompressed = expectCompressed;
    }
    if (fillServerId != null) {
      $result.fillServerId = fillServerId;
    }
    if (fillGrpclbRouteType != null) {
      $result.fillGrpclbRouteType = fillGrpclbRouteType;
    }
    if (orcaPerQueryReport != null) {
      $result.orcaPerQueryReport = orcaPerQueryReport;
    }
    return $result;
  }
  SimpleRequest._() : super();
  factory SimpleRequest.fromBuffer($core.List<$core.int> i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromBuffer(i, r);
  factory SimpleRequest.fromJson($core.String i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'SimpleRequest', package: const $pb.PackageName(_omitMessageNames ? '' : 'grpc.testing'), createEmptyInstance: create)
    ..e<PayloadType>(1, _omitFieldNames ? '' : 'responseType', $pb.PbFieldType.OE, defaultOrMaker: PayloadType.COMPRESSABLE, valueOf: PayloadType.valueOf, enumValues: PayloadType.values)
    ..a<$core.int>(2, _omitFieldNames ? '' : 'responseSize', $pb.PbFieldType.O3)
    ..aOM<Payload>(3, _omitFieldNames ? '' : 'payload', subBuilder: Payload.create)
    ..aOB(4, _omitFieldNames ? '' : 'fillUsername')
    ..aOB(5, _omitFieldNames ? '' : 'fillOauthScope')
    ..aOM<BoolValue>(6, _omitFieldNames ? '' : 'responseCompressed', subBuilder: BoolValue.create)
    ..aOM<EchoStatus>(7, _omitFieldNames ? '' : 'responseStatus', subBuilder: EchoStatus.create)
    ..aOM<BoolValue>(8, _omitFieldNames ? '' : 'expectCompressed', subBuilder: BoolValue.create)
    ..aOB(9, _omitFieldNames ? '' : 'fillServerId')
    ..aOB(10, _omitFieldNames ? '' : 'fillGrpclbRouteType')
    ..aOM<TestOrcaReport>(11, _omitFieldNames ? '' : 'orcaPerQueryReport', subBuilder: TestOrcaReport.create)
    ..hasRequiredFields = false
  ;

  @$core.Deprecated(
  'Using this can add significant overhead to your binary. '
  'Use [GeneratedMessageGenericExtensions.deepCopy] instead. '
  'Will be removed in next major version')
  SimpleRequest clone() => SimpleRequest()..mergeFromMessage(this);
  @$core.Deprecated(
  'Using this can add significant overhead to your binary. '
  'Use [GeneratedMessageGenericExtensions.rebuild] instead. '
  'Will be removed in next major version')
  SimpleRequest copyWith(void Function(SimpleRequest) updates) => super.copyWith((message) => updates(message as SimpleRequest)) as SimpleRequest;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static SimpleRequest create() => SimpleRequest._();
  SimpleRequest createEmptyInstance() => create();
  static $pb.PbList<SimpleRequest> createRepeated() => $pb.PbList<SimpleRequest>();
  @$core.pragma('dart2js:noInline')
  static SimpleRequest getDefault() => _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<SimpleRequest>(create);
  static SimpleRequest? _defaultInstance;

  /// Desired payload type in the response from the server.
  /// If response_type is RANDOM, server randomly chooses one from other formats.
  @$pb.TagNumber(1)
  PayloadType get responseType => $_getN(0);
  @$pb.TagNumber(1)
  set responseType(PayloadType v) { setField(1, v); }
  @$pb.TagNumber(1)
  $core.bool hasResponseType() => $_has(0);
  @$pb.TagNumber(1)
  void clearResponseType() => clearField(1);

  /// Desired payload size in the response from the server.
  @$pb.TagNumber(2)
  $core.int get responseSize => $_getIZ(1);
  @$pb.TagNumber(2)
  set responseSize($core.int v) { $_setSignedInt32(1, v); }
  @$pb.TagNumber(2)
  $core.bool hasResponseSize() => $_has(1);
  @$pb.TagNumber(2)
  void clearResponseSize() => clearField(2);

  /// Optional input payload sent along with the request.
  @$pb.TagNumber(3)
  Payload get payload => $_getN(2);
  @$pb.TagNumber(3)
  set payload(Payload v) { setField(3, v); }
  @$pb.TagNumber(3)
  $core.bool hasPayload() => $_has(2);
  @$pb.TagNumber(3)
  void clearPayload() => clearField(3);
  @$pb.TagNumber(3)
  Payload ensurePayload() => $_ensure(2);

  /// Whether SimpleResponse should include username.
  @$pb.TagNumber(4)
  $core.bool get fillUsername => $_getBF(3);
  @$pb.TagNumber(4)
  set fillUsername($core.bool v) { $_setBool(3, v); }
  @$pb.TagNumber(4)
  $core.bool hasFillUsername() => $_has(3);
  @$pb.TagNumber(4)
  void clearFillUsername() => clearField(4);

  /// Whether SimpleResponse should include OAuth scope.
  @$pb.TagNumber(5)
  $core.bool get fillOauthScope => $_getBF(4);
  @$pb.TagNumber(5)
  set fillOauthScope($core.bool v) { $_setBool(4, v); }
  @$pb.TagNumber(5)
  $core.bool hasFillOauthScope() => $_has(4);
  @$pb.TagNumber(5)
  void clearFillOauthScope() => clearField(5);

  /// Whether to request the server to compress the response. This field is
  /// "nullable" in order to interoperate seamlessly with clients not able to
  /// implement the full compression tests by introspecting the call to verify
  /// the response's compression status.
  @$pb.TagNumber(6)
  BoolValue get responseCompressed => $_getN(5);
  @$pb.TagNumber(6)
  set responseCompressed(BoolValue v) { setField(6, v); }
  @$pb.TagNumber(6)
  $core.bool hasResponseCompressed() => $_has(5);
  @$pb.TagNumber(6)
  void clearResponseCompressed() => clearField(6);
  @$pb.TagNumber(6)
  BoolValue ensureResponseCompressed() => $_ensure(5);

  /// Whether server should return a given status
  @$pb.TagNumber(7)
  EchoStatus get responseStatus => $_getN(6);
  @$pb.TagNumber(7)
  set responseStatus(EchoStatus v) { setField(7, v); }
  @$pb.TagNumber(7)
  $core.bool hasResponseStatus() => $_has(6);
  @$pb.TagNumber(7)
  void clearResponseStatus() => clearField(7);
  @$pb.TagNumber(7)
  EchoStatus ensureResponseStatus() => $_ensure(6);

  /// Whether the server should expect this request to be compressed.
  @$pb.TagNumber(8)
  BoolValue get expectCompressed => $_getN(7);
  @$pb.TagNumber(8)
  set expectCompressed(BoolValue v) { setField(8, v); }
  @$pb.TagNumber(8)
  $core.bool hasExpectCompressed() => $_has(7);
  @$pb.TagNumber(8)
  void clearExpectCompressed() => clearField(8);
  @$pb.TagNumber(8)
  BoolValue ensureExpectCompressed() => $_ensure(7);

  /// Whether SimpleResponse should include server_id.
  @$pb.TagNumber(9)
  $core.bool get fillServerId => $_getBF(8);
  @$pb.TagNumber(9)
  set fillServerId($core.bool v) { $_setBool(8, v); }
  @$pb.TagNumber(9)
  $core.bool hasFillServerId() => $_has(8);
  @$pb.TagNumber(9)
  void clearFillServerId() => clearField(9);

  /// Whether SimpleResponse should include grpclb_route_type.
  @$pb.TagNumber(10)
  $core.bool get fillGrpclbRouteType => $_getBF(9);
  @$pb.TagNumber(10)
  set fillGrpclbRouteType($core.bool v) { $_setBool(9, v); }
  @$pb.TagNumber(10)
  $core.bool hasFillGrpclbRouteType() => $_has(9);
  @$pb.TagNumber(10)
  void clearFillGrpclbRouteType() => clearField(10);

  /// If set the server should record this metrics report data for the current RPC.
  @$pb.TagNumber(11)
  TestOrcaReport get orcaPerQueryReport => $_getN(10);
  @$pb.TagNumber(11)
  set orcaPerQueryReport(TestOrcaReport v) { setField(11, v); }
  @$pb.TagNumber(11)
  $core.bool hasOrcaPerQueryReport() => $_has(10);
  @$pb.TagNumber(11)
  void clearOrcaPerQueryReport() => clearField(11);
  @$pb.TagNumber(11)
  TestOrcaReport ensureOrcaPerQueryReport() => $_ensure(10);
}

/// Unary response, as configured by the request.
class SimpleResponse extends $pb.GeneratedMessage {
  factory SimpleResponse({
    Payload? payload,
    $core.String? username,
    $core.String? oauthScope,
    $core.String? serverId,
    GrpclbRouteType? grpclbRouteType,
    $core.String? hostname,
  }) {
    final $result = create();
    if (payload != null) {
      $result.payload = payload;
    }
    if (username != null) {
      $result.username = username;
    }
    if (oauthScope != null) {
      $result.oauthScope = oauthScope;
    }
    if (serverId != null) {
      $result.serverId = serverId;
    }
    if (grpclbRouteType != null) {
      $result.grpclbRouteType = grpclbRouteType;
    }
    if (hostname != null) {
      $result.hostname = hostname;
    }
    return $result;
  }
  SimpleResponse._() : super();
  factory SimpleResponse.fromBuffer($core.List<$core.int> i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromBuffer(i, r);
  factory SimpleResponse.fromJson($core.String i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'SimpleResponse', package: const $pb.PackageName(_omitMessageNames ? '' : 'grpc.testing'), createEmptyInstance: create)
    ..aOM<Payload>(1, _omitFieldNames ? '' : 'payload', subBuilder: Payload.create)
    ..aOS(2, _omitFieldNames ? '' : 'username')
    ..aOS(3, _omitFieldNames ? '' : 'oauthScope')
    ..aOS(4, _omitFieldNames ? '' : 'serverId')
    ..e<GrpclbRouteType>(5, _omitFieldNames ? '' : 'grpclbRouteType', $pb.PbFieldType.OE, defaultOrMaker: GrpclbRouteType.GRPCLB_ROUTE_TYPE_UNKNOWN, valueOf: GrpclbRouteType.valueOf, enumValues: GrpclbRouteType.values)
    ..aOS(6, _omitFieldNames ? '' : 'hostname')
    ..hasRequiredFields = false
  ;

  @$core.Deprecated(
  'Using this can add significant overhead to your binary. '
  'Use [GeneratedMessageGenericExtensions.deepCopy] instead. '
  'Will be removed in next major version')
  SimpleResponse clone() => SimpleResponse()..mergeFromMessage(this);
  @$core.Deprecated(
  'Using this can add significant overhead to your binary. '
  'Use [GeneratedMessageGenericExtensions.rebuild] instead. '
  'Will be removed in next major version')
  SimpleResponse copyWith(void Function(SimpleResponse) updates) => super.copyWith((message) => updates(message as SimpleResponse)) as SimpleResponse;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static SimpleResponse create() => SimpleResponse._();
  SimpleResponse createEmptyInstance() => create();
  static $pb.PbList<SimpleResponse> createRepeated() => $pb.PbList<SimpleResponse>();
  @$core.pragma('dart2js:noInline')
  static SimpleResponse getDefault() => _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<SimpleResponse>(create);
  static SimpleResponse? _defaultInstance;

  /// Payload to increase message size.
  @$pb.TagNumber(1)
  Payload get payload => $_getN(0);
  @$pb.TagNumber(1)
  set payload(Payload v) { setField(1, v); }
  @$pb.TagNumber(1)
  $core.bool hasPayload() => $_has(0);
  @$pb.TagNumber(1)
  void clearPayload() => clearField(1);
  @$pb.TagNumber(1)
  Payload ensurePayload() => $_ensure(0);

  /// The user the request came from, for verifying authentication was
  /// successful when the client expected it.
  @$pb.TagNumber(2)
  $core.String get username => $_getSZ(1);
  @$pb.TagNumber(2)
  set username($core.String v) { $_setString(1, v); }
  @$pb.TagNumber(2)
  $core.bool hasUsername() => $_has(1);
  @$pb.TagNumber(2)
  void clearUsername() => clearField(2);

  /// OAuth scope.
  @$pb.TagNumber(3)
  $core.String get oauthScope => $_getSZ(2);
  @$pb.TagNumber(3)
  set oauthScope($core.String v) { $_setString(2, v); }
  @$pb.TagNumber(3)
  $core.bool hasOauthScope() => $_has(2);
  @$pb.TagNumber(3)
  void clearOauthScope() => clearField(3);

  /// Server ID. This must be unique among different server instances,
  /// but the same across all RPC's made to a particular server instance.
  @$pb.TagNumber(4)
  $core.String get serverId => $_getSZ(3);
  @$pb.TagNumber(4)
  set serverId($core.String v) { $_setString(3, v); }
  @$pb.TagNumber(4)
  $core.bool hasServerId() => $_has(3);
  @$pb.TagNumber(4)
  void clearServerId() => clearField(4);

  /// gRPCLB Path.
  @$pb.TagNumber(5)
  GrpclbRouteType get grpclbRouteType => $_getN(4);
  @$pb.TagNumber(5)
  set grpclbRouteType(GrpclbRouteType v) { setField(5, v); }
  @$pb.TagNumber(5)
  $core.bool hasGrpclbRouteType() => $_has(4);
  @$pb.TagNumber(5)
  void clearGrpclbRouteType() => clearField(5);

  /// Server hostname.
  @$pb.TagNumber(6)
  $core.String get hostname => $_getSZ(5);
  @$pb.TagNumber(6)
  set hostname($core.String v) { $_setString(5, v); }
  @$pb.TagNumber(6)
  $core.bool hasHostname() => $_has(5);
  @$pb.TagNumber(6)
  void clearHostname() => clearField(6);
}

/// Client-streaming request.
class StreamingInputCallRequest extends $pb.GeneratedMessage {
  factory StreamingInputCallRequest({
    Payload? payload,
    BoolValue? expectCompressed,
  }) {
    final $result = create();
    if (payload != null) {
      $result.payload = payload;
    }
    if (expectCompressed != null) {
      $result.expectCompressed = expectCompressed;
    }
    return $result;
  }
  StreamingInputCallRequest._() : super();
  factory StreamingInputCallRequest.fromBuffer($core.List<$core.int> i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromBuffer(i, r);
  factory StreamingInputCallRequest.fromJson($core.String i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'StreamingInputCallRequest', package: const $pb.PackageName(_omitMessageNames ? '' : 'grpc.testing'), createEmptyInstance: create)
    ..aOM<Payload>(1, _omitFieldNames ? '' : 'payload', subBuilder: Payload.create)
    ..aOM<BoolValue>(2, _omitFieldNames ? '' : 'expectCompressed', subBuilder: BoolValue.create)
    ..hasRequiredFields = false
  ;

  @$core.Deprecated(
  'Using this can add significant overhead to your binary. '
  'Use [GeneratedMessageGenericExtensions.deepCopy] instead. '
  'Will be removed in next major version')
  StreamingInputCallRequest clone() => StreamingInputCallRequest()..mergeFromMessage(this);
  @$core.Deprecated(
  'Using this can add significant overhead to your binary. '
  'Use [GeneratedMessageGenericExtensions.rebuild] instead. '
  'Will be removed in next major version')
  StreamingInputCallRequest copyWith(void Function(StreamingInputCallRequest) updates) => super.copyWith((message) => updates(message as StreamingInputCallRequest)) as StreamingInputCallRequest;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static StreamingInputCallRequest create() => StreamingInputCallRequest._();
  StreamingInputCallRequest createEmptyInstance() => create();
  static $pb.PbList<StreamingInputCallRequest> createRepeated() => $pb.PbList<StreamingInputCallRequest>();
  @$core.pragma('dart2js:noInline')
  static StreamingInputCallRequest getDefault() => _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<StreamingInputCallRequest>(create);
  static StreamingInputCallRequest? _defaultInstance;

  /// Optional input payload sent along with the request.
  @$pb.TagNumber(1)
  Payload get payload => $_getN(0);
  @$pb.TagNumber(1)
  set payload(Payload v) { setField(1, v); }
  @$pb.TagNumber(1)
  $core.bool hasPayload() => $_has(0);
  @$pb.TagNumber(1)
  void clearPayload() => clearField(1);
  @$pb.TagNumber(1)
  Payload ensurePayload() => $_ensure(0);

  /// Whether the server should expect this request to be compressed. This field
  /// is "nullable" in order to interoperate seamlessly with servers not able to
  /// implement the full compression tests by introspecting the call to verify
  /// the request's compression status.
  @$pb.TagNumber(2)
  BoolValue get expectCompressed => $_getN(1);
  @$pb.TagNumber(2)
  set expectCompressed(BoolValue v) { setField(2, v); }
  @$pb.TagNumber(2)
  $core.bool hasExpectCompressed() => $_has(1);
  @$pb.TagNumber(2)
  void clearExpectCompressed() => clearField(2);
  @$pb.TagNumber(2)
  BoolValue ensureExpectCompressed() => $_ensure(1);
}

/// Client-streaming response.
class StreamingInputCallResponse extends $pb.GeneratedMessage {
  factory StreamingInputCallResponse({
    $core.int? aggregatedPayloadSize,
  }) {
    final $result = create();
    if (aggregatedPayloadSize != null) {
      $result.aggregatedPayloadSize = aggregatedPayloadSize;
    }
    return $result;
  }
  StreamingInputCallResponse._() : super();
  factory StreamingInputCallResponse.fromBuffer($core.List<$core.int> i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromBuffer(i, r);
  factory StreamingInputCallResponse.fromJson($core.String i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'StreamingInputCallResponse', package: const $pb.PackageName(_omitMessageNames ? '' : 'grpc.testing'), createEmptyInstance: create)
    ..a<$core.int>(1, _omitFieldNames ? '' : 'aggregatedPayloadSize', $pb.PbFieldType.O3)
    ..hasRequiredFields = false
  ;

  @$core.Deprecated(
  'Using this can add significant overhead to your binary. '
  'Use [GeneratedMessageGenericExtensions.deepCopy] instead. '
  'Will be removed in next major version')
  StreamingInputCallResponse clone() => StreamingInputCallResponse()..mergeFromMessage(this);
  @$core.Deprecated(
  'Using this can add significant overhead to your binary. '
  'Use [GeneratedMessageGenericExtensions.rebuild] instead. '
  'Will be removed in next major version')
  StreamingInputCallResponse copyWith(void Function(StreamingInputCallResponse) updates) => super.copyWith((message) => updates(message as StreamingInputCallResponse)) as StreamingInputCallResponse;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static StreamingInputCallResponse create() => StreamingInputCallResponse._();
  StreamingInputCallResponse createEmptyInstance() => create();
  static $pb.PbList<StreamingInputCallResponse> createRepeated() => $pb.PbList<StreamingInputCallResponse>();
  @$core.pragma('dart2js:noInline')
  static StreamingInputCallResponse getDefault() => _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<StreamingInputCallResponse>(create);
  static StreamingInputCallResponse? _defaultInstance;

  /// Aggregated size of payloads received from the client.
  @$pb.TagNumber(1)
  $core.int get aggregatedPayloadSize => $_getIZ(0);
  @$pb.TagNumber(1)
  set aggregatedPayloadSize($core.int v) { $_setSignedInt32(0, v); }
  @$pb.TagNumber(1)
  $core.bool hasAggregatedPayloadSize() => $_has(0);
  @$pb.TagNumber(1)
  void clearAggregatedPayloadSize() => clearField(1);
}

/// Configuration for a particular response.
class ResponseParameters extends $pb.GeneratedMessage {
  factory ResponseParameters({
    $core.int? size,
    $core.int? intervalUs,
    BoolValue? compressed,
  }) {
    final $result = create();
    if (size != null) {
      $result.size = size;
    }
    if (intervalUs != null) {
      $result.intervalUs = intervalUs;
    }
    if (compressed != null) {
      $result.compressed = compressed;
    }
    return $result;
  }
  ResponseParameters._() : super();
  factory ResponseParameters.fromBuffer($core.List<$core.int> i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromBuffer(i, r);
  factory ResponseParameters.fromJson($core.String i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'ResponseParameters', package: const $pb.PackageName(_omitMessageNames ? '' : 'grpc.testing'), createEmptyInstance: create)
    ..a<$core.int>(1, _omitFieldNames ? '' : 'size', $pb.PbFieldType.O3)
    ..a<$core.int>(2, _omitFieldNames ? '' : 'intervalUs', $pb.PbFieldType.O3)
    ..aOM<BoolValue>(3, _omitFieldNames ? '' : 'compressed', subBuilder: BoolValue.create)
    ..hasRequiredFields = false
  ;

  @$core.Deprecated(
  'Using this can add significant overhead to your binary. '
  'Use [GeneratedMessageGenericExtensions.deepCopy] instead. '
  'Will be removed in next major version')
  ResponseParameters clone() => ResponseParameters()..mergeFromMessage(this);
  @$core.Deprecated(
  'Using this can add significant overhead to your binary. '
  'Use [GeneratedMessageGenericExtensions.rebuild] instead. '
  'Will be removed in next major version')
  ResponseParameters copyWith(void Function(ResponseParameters) updates) => super.copyWith((message) => updates(message as ResponseParameters)) as ResponseParameters;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static ResponseParameters create() => ResponseParameters._();
  ResponseParameters createEmptyInstance() => create();
  static $pb.PbList<ResponseParameters> createRepeated() => $pb.PbList<ResponseParameters>();
  @$core.pragma('dart2js:noInline')
  static ResponseParameters getDefault() => _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<ResponseParameters>(create);
  static ResponseParameters? _defaultInstance;

  /// Desired payload sizes in responses from the server.
  @$pb.TagNumber(1)
  $core.int get size => $_getIZ(0);
  @$pb.TagNumber(1)
  set size($core.int v) { $_setSignedInt32(0, v); }
  @$pb.TagNumber(1)
  $core.bool hasSize() => $_has(0);
  @$pb.TagNumber(1)
  void clearSize() => clearField(1);

  /// Desired interval between consecutive responses in the response stream in
  /// microseconds.
  @$pb.TagNumber(2)
  $core.int get intervalUs => $_getIZ(1);
  @$pb.TagNumber(2)
  set intervalUs($core.int v) { $_setSignedInt32(1, v); }
  @$pb.TagNumber(2)
  $core.bool hasIntervalUs() => $_has(1);
  @$pb.TagNumber(2)
  void clearIntervalUs() => clearField(2);

  /// Whether to request the server to compress the response. This field is
  /// "nullable" in order to interoperate seamlessly with clients not able to
  /// implement the full compression tests by introspecting the call to verify
  /// the response's compression status.
  @$pb.TagNumber(3)
  BoolValue get compressed => $_getN(2);
  @$pb.TagNumber(3)
  set compressed(BoolValue v) { setField(3, v); }
  @$pb.TagNumber(3)
  $core.bool hasCompressed() => $_has(2);
  @$pb.TagNumber(3)
  void clearCompressed() => clearField(3);
  @$pb.TagNumber(3)
  BoolValue ensureCompressed() => $_ensure(2);
}

/// Server-streaming request.
class StreamingOutputCallRequest extends $pb.GeneratedMessage {
  factory StreamingOutputCallRequest({
    PayloadType? responseType,
    $core.Iterable<ResponseParameters>? responseParameters,
    Payload? payload,
    EchoStatus? responseStatus,
    TestOrcaReport? orcaOobReport,
  }) {
    final $result = create();
    if (responseType != null) {
      $result.responseType = responseType;
    }
    if (responseParameters != null) {
      $result.responseParameters.addAll(responseParameters);
    }
    if (payload != null) {
      $result.payload = payload;
    }
    if (responseStatus != null) {
      $result.responseStatus = responseStatus;
    }
    if (orcaOobReport != null) {
      $result.orcaOobReport = orcaOobReport;
    }
    return $result;
  }
  StreamingOutputCallRequest._() : super();
  factory StreamingOutputCallRequest.fromBuffer($core.List<$core.int> i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromBuffer(i, r);
  factory StreamingOutputCallRequest.fromJson($core.String i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'StreamingOutputCallRequest', package: const $pb.PackageName(_omitMessageNames ? '' : 'grpc.testing'), createEmptyInstance: create)
    ..e<PayloadType>(1, _omitFieldNames ? '' : 'responseType', $pb.PbFieldType.OE, defaultOrMaker: PayloadType.COMPRESSABLE, valueOf: PayloadType.valueOf, enumValues: PayloadType.values)
    ..pc<ResponseParameters>(2, _omitFieldNames ? '' : 'responseParameters', $pb.PbFieldType.PM, subBuilder: ResponseParameters.create)
    ..aOM<Payload>(3, _omitFieldNames ? '' : 'payload', subBuilder: Payload.create)
    ..aOM<EchoStatus>(7, _omitFieldNames ? '' : 'responseStatus', subBuilder: EchoStatus.create)
    ..aOM<TestOrcaReport>(8, _omitFieldNames ? '' : 'orcaOobReport', subBuilder: TestOrcaReport.create)
    ..hasRequiredFields = false
  ;

  @$core.Deprecated(
  'Using this can add significant overhead to your binary. '
  'Use [GeneratedMessageGenericExtensions.deepCopy] instead. '
  'Will be removed in next major version')
  StreamingOutputCallRequest clone() => StreamingOutputCallRequest()..mergeFromMessage(this);
  @$core.Deprecated(
  'Using this can add significant overhead to your binary. '
  'Use [GeneratedMessageGenericExtensions.rebuild] instead. '
  'Will be removed in next major version')
  StreamingOutputCallRequest copyWith(void Function(StreamingOutputCallRequest) updates) => super.copyWith((message) => updates(message as StreamingOutputCallRequest)) as StreamingOutputCallRequest;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static StreamingOutputCallRequest create() => StreamingOutputCallRequest._();
  StreamingOutputCallRequest createEmptyInstance() => create();
  static $pb.PbList<StreamingOutputCallRequest> createRepeated() => $pb.PbList<StreamingOutputCallRequest>();
  @$core.pragma('dart2js:noInline')
  static StreamingOutputCallRequest getDefault() => _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<StreamingOutputCallRequest>(create);
  static StreamingOutputCallRequest? _defaultInstance;

  /// Desired payload type in the response from the server.
  /// If response_type is RANDOM, the payload from each response in the stream
  /// might be of different types. This is to simulate a mixed type of payload
  /// stream.
  @$pb.TagNumber(1)
  PayloadType get responseType => $_getN(0);
  @$pb.TagNumber(1)
  set responseType(PayloadType v) { setField(1, v); }
  @$pb.TagNumber(1)
  $core.bool hasResponseType() => $_has(0);
  @$pb.TagNumber(1)
  void clearResponseType() => clearField(1);

  /// Configuration for each expected response message.
  @$pb.TagNumber(2)
  $core.List<ResponseParameters> get responseParameters => $_getList(1);

  /// Optional input payload sent along with the request.
  @$pb.TagNumber(3)
  Payload get payload => $_getN(2);
  @$pb.TagNumber(3)
  set payload(Payload v) { setField(3, v); }
  @$pb.TagNumber(3)
  $core.bool hasPayload() => $_has(2);
  @$pb.TagNumber(3)
  void clearPayload() => clearField(3);
  @$pb.TagNumber(3)
  Payload ensurePayload() => $_ensure(2);

  /// Whether server should return a given status
  @$pb.TagNumber(7)
  EchoStatus get responseStatus => $_getN(3);
  @$pb.TagNumber(7)
  set responseStatus(EchoStatus v) { setField(7, v); }
  @$pb.TagNumber(7)
  $core.bool hasResponseStatus() => $_has(3);
  @$pb.TagNumber(7)
  void clearResponseStatus() => clearField(7);
  @$pb.TagNumber(7)
  EchoStatus ensureResponseStatus() => $_ensure(3);

  /// If set the server should update this metrics report data at the OOB server.
  @$pb.TagNumber(8)
  TestOrcaReport get orcaOobReport => $_getN(4);
  @$pb.TagNumber(8)
  set orcaOobReport(TestOrcaReport v) { setField(8, v); }
  @$pb.TagNumber(8)
  $core.bool hasOrcaOobReport() => $_has(4);
  @$pb.TagNumber(8)
  void clearOrcaOobReport() => clearField(8);
  @$pb.TagNumber(8)
  TestOrcaReport ensureOrcaOobReport() => $_ensure(4);
}

/// Server-streaming response, as configured by the request and parameters.
class StreamingOutputCallResponse extends $pb.GeneratedMessage {
  factory StreamingOutputCallResponse({
    Payload? payload,
  }) {
    final $result = create();
    if (payload != null) {
      $result.payload = payload;
    }
    return $result;
  }
  StreamingOutputCallResponse._() : super();
  factory StreamingOutputCallResponse.fromBuffer($core.List<$core.int> i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromBuffer(i, r);
  factory StreamingOutputCallResponse.fromJson($core.String i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'StreamingOutputCallResponse', package: const $pb.PackageName(_omitMessageNames ? '' : 'grpc.testing'), createEmptyInstance: create)
    ..aOM<Payload>(1, _omitFieldNames ? '' : 'payload', subBuilder: Payload.create)
    ..hasRequiredFields = false
  ;

  @$core.Deprecated(
  'Using this can add significant overhead to your binary. '
  'Use [GeneratedMessageGenericExtensions.deepCopy] instead. '
  'Will be removed in next major version')
  StreamingOutputCallResponse clone() => StreamingOutputCallResponse()..mergeFromMessage(this);
  @$core.Deprecated(
  'Using this can add significant overhead to your binary. '
  'Use [GeneratedMessageGenericExtensions.rebuild] instead. '
  'Will be removed in next major version')
  StreamingOutputCallResponse copyWith(void Function(StreamingOutputCallResponse) updates) => super.copyWith((message) => updates(message as StreamingOutputCallResponse)) as StreamingOutputCallResponse;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static StreamingOutputCallResponse create() => StreamingOutputCallResponse._();
  StreamingOutputCallResponse createEmptyInstance() => create();
  static $pb.PbList<StreamingOutputCallResponse> createRepeated() => $pb.PbList<StreamingOutputCallResponse>();
  @$core.pragma('dart2js:noInline')
  static StreamingOutputCallResponse getDefault() => _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<StreamingOutputCallResponse>(create);
  static StreamingOutputCallResponse? _defaultInstance;

  /// Payload to increase response size.
  @$pb.TagNumber(1)
  Payload get payload => $_getN(0);
  @$pb.TagNumber(1)
  set payload(Payload v) { setField(1, v); }
  @$pb.TagNumber(1)
  $core.bool hasPayload() => $_has(0);
  @$pb.TagNumber(1)
  void clearPayload() => clearField(1);
  @$pb.TagNumber(1)
  Payload ensurePayload() => $_ensure(0);
}

/// For reconnect interop test only.
/// Client tells server what reconnection parameters it used.
class ReconnectParams extends $pb.GeneratedMessage {
  factory ReconnectParams({
    $core.int? maxReconnectBackoffMs,
  }) {
    final $result = create();
    if (maxReconnectBackoffMs != null) {
      $result.maxReconnectBackoffMs = maxReconnectBackoffMs;
    }
    return $result;
  }
  ReconnectParams._() : super();
  factory ReconnectParams.fromBuffer($core.List<$core.int> i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromBuffer(i, r);
  factory ReconnectParams.fromJson($core.String i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'ReconnectParams', package: const $pb.PackageName(_omitMessageNames ? '' : 'grpc.testing'), createEmptyInstance: create)
    ..a<$core.int>(1, _omitFieldNames ? '' : 'maxReconnectBackoffMs', $pb.PbFieldType.O3)
    ..hasRequiredFields = false
  ;

  @$core.Deprecated(
  'Using this can add significant overhead to your binary. '
  'Use [GeneratedMessageGenericExtensions.deepCopy] instead. '
  'Will be removed in next major version')
  ReconnectParams clone() => ReconnectParams()..mergeFromMessage(this);
  @$core.Deprecated(
  'Using this can add significant overhead to your binary. '
  'Use [GeneratedMessageGenericExtensions.rebuild] instead. '
  'Will be removed in next major version')
  ReconnectParams copyWith(void Function(ReconnectParams) updates) => super.copyWith((message) => updates(message as ReconnectParams)) as ReconnectParams;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static ReconnectParams create() => ReconnectParams._();
  ReconnectParams createEmptyInstance() => create();
  static $pb.PbList<ReconnectParams> createRepeated() => $pb.PbList<ReconnectParams>();
  @$core.pragma('dart2js:noInline')
  static ReconnectParams getDefault() => _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<ReconnectParams>(create);
  static ReconnectParams? _defaultInstance;

  @$pb.TagNumber(1)
  $core.int get maxReconnectBackoffMs => $_getIZ(0);
  @$pb.TagNumber(1)
  set maxReconnectBackoffMs($core.int v) { $_setSignedInt32(0, v); }
  @$pb.TagNumber(1)
  $core.bool hasMaxReconnectBackoffMs() => $_has(0);
  @$pb.TagNumber(1)
  void clearMaxReconnectBackoffMs() => clearField(1);
}

/// For reconnect interop test only.
/// Server tells client whether its reconnects are following the spec and the
/// reconnect backoffs it saw.
class ReconnectInfo extends $pb.GeneratedMessage {
  factory ReconnectInfo({
    $core.bool? passed,
    $core.Iterable<$core.int>? backoffMs,
  }) {
    final $result = create();
    if (passed != null) {
      $result.passed = passed;
    }
    if (backoffMs != null) {
      $result.backoffMs.addAll(backoffMs);
    }
    return $result;
  }
  ReconnectInfo._() : super();
  factory ReconnectInfo.fromBuffer($core.List<$core.int> i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromBuffer(i, r);
  factory ReconnectInfo.fromJson($core.String i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'ReconnectInfo', package: const $pb.PackageName(_omitMessageNames ? '' : 'grpc.testing'), createEmptyInstance: create)
    ..aOB(1, _omitFieldNames ? '' : 'passed')
    ..p<$core.int>(2, _omitFieldNames ? '' : 'backoffMs', $pb.PbFieldType.K3)
    ..hasRequiredFields = false
  ;

  @$core.Deprecated(
  'Using this can add significant overhead to your binary. '
  'Use [GeneratedMessageGenericExtensions.deepCopy] instead. '
  'Will be removed in next major version')
  ReconnectInfo clone() => ReconnectInfo()..mergeFromMessage(this);
  @$core.Deprecated(
  'Using this can add significant overhead to your binary. '
  'Use [GeneratedMessageGenericExtensions.rebuild] instead. '
  'Will be removed in next major version')
  ReconnectInfo copyWith(void Function(ReconnectInfo) updates) => super.copyWith((message) => updates(message as ReconnectInfo)) as ReconnectInfo;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static ReconnectInfo create() => ReconnectInfo._();
  ReconnectInfo createEmptyInstance() => create();
  static $pb.PbList<ReconnectInfo> createRepeated() => $pb.PbList<ReconnectInfo>();
  @$core.pragma('dart2js:noInline')
  static ReconnectInfo getDefault() => _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<ReconnectInfo>(create);
  static ReconnectInfo? _defaultInstance;

  @$pb.TagNumber(1)
  $core.bool get passed => $_getBF(0);
  @$pb.TagNumber(1)
  set passed($core.bool v) { $_setBool(0, v); }
  @$pb.TagNumber(1)
  $core.bool hasPassed() => $_has(0);
  @$pb.TagNumber(1)
  void clearPassed() => clearField(1);

  @$pb.TagNumber(2)
  $core.List<$core.int> get backoffMs => $_getList(1);
}

class LoadBalancerStatsRequest extends $pb.GeneratedMessage {
  factory LoadBalancerStatsRequest({
    $core.int? numRpcs,
    $core.int? timeoutSec,
  }) {
    final $result = create();
    if (numRpcs != null) {
      $result.numRpcs = numRpcs;
    }
    if (timeoutSec != null) {
      $result.timeoutSec = timeoutSec;
    }
    return $result;
  }
  LoadBalancerStatsRequest._() : super();
  factory LoadBalancerStatsRequest.fromBuffer($core.List<$core.int> i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromBuffer(i, r);
  factory LoadBalancerStatsRequest.fromJson($core.String i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'LoadBalancerStatsRequest', package: const $pb.PackageName(_omitMessageNames ? '' : 'grpc.testing'), createEmptyInstance: create)
    ..a<$core.int>(1, _omitFieldNames ? '' : 'numRpcs', $pb.PbFieldType.O3)
    ..a<$core.int>(2, _omitFieldNames ? '' : 'timeoutSec', $pb.PbFieldType.O3)
    ..hasRequiredFields = false
  ;

  @$core.Deprecated(
  'Using this can add significant overhead to your binary. '
  'Use [GeneratedMessageGenericExtensions.deepCopy] instead. '
  'Will be removed in next major version')
  LoadBalancerStatsRequest clone() => LoadBalancerStatsRequest()..mergeFromMessage(this);
  @$core.Deprecated(
  'Using this can add significant overhead to your binary. '
  'Use [GeneratedMessageGenericExtensions.rebuild] instead. '
  'Will be removed in next major version')
  LoadBalancerStatsRequest copyWith(void Function(LoadBalancerStatsRequest) updates) => super.copyWith((message) => updates(message as LoadBalancerStatsRequest)) as LoadBalancerStatsRequest;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static LoadBalancerStatsRequest create() => LoadBalancerStatsRequest._();
  LoadBalancerStatsRequest createEmptyInstance() => create();
  static $pb.PbList<LoadBalancerStatsRequest> createRepeated() => $pb.PbList<LoadBalancerStatsRequest>();
  @$core.pragma('dart2js:noInline')
  static LoadBalancerStatsRequest getDefault() => _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<LoadBalancerStatsRequest>(create);
  static LoadBalancerStatsRequest? _defaultInstance;

  /// Request stats for the next num_rpcs sent by client.
  @$pb.TagNumber(1)
  $core.int get numRpcs => $_getIZ(0);
  @$pb.TagNumber(1)
  set numRpcs($core.int v) { $_setSignedInt32(0, v); }
  @$pb.TagNumber(1)
  $core.bool hasNumRpcs() => $_has(0);
  @$pb.TagNumber(1)
  void clearNumRpcs() => clearField(1);

  /// If num_rpcs have not completed within timeout_sec, return partial results.
  @$pb.TagNumber(2)
  $core.int get timeoutSec => $_getIZ(1);
  @$pb.TagNumber(2)
  set timeoutSec($core.int v) { $_setSignedInt32(1, v); }
  @$pb.TagNumber(2)
  $core.bool hasTimeoutSec() => $_has(1);
  @$pb.TagNumber(2)
  void clearTimeoutSec() => clearField(2);
}

class LoadBalancerStatsResponse_RpcsByPeer extends $pb.GeneratedMessage {
  factory LoadBalancerStatsResponse_RpcsByPeer({
    $core.Map<$core.String, $core.int>? rpcsByPeer,
  }) {
    final $result = create();
    if (rpcsByPeer != null) {
      $result.rpcsByPeer.addAll(rpcsByPeer);
    }
    return $result;
  }
  LoadBalancerStatsResponse_RpcsByPeer._() : super();
  factory LoadBalancerStatsResponse_RpcsByPeer.fromBuffer($core.List<$core.int> i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromBuffer(i, r);
  factory LoadBalancerStatsResponse_RpcsByPeer.fromJson($core.String i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'LoadBalancerStatsResponse.RpcsByPeer', package: const $pb.PackageName(_omitMessageNames ? '' : 'grpc.testing'), createEmptyInstance: create)
    ..m<$core.String, $core.int>(1, _omitFieldNames ? '' : 'rpcsByPeer', entryClassName: 'LoadBalancerStatsResponse.RpcsByPeer.RpcsByPeerEntry', keyFieldType: $pb.PbFieldType.OS, valueFieldType: $pb.PbFieldType.O3, packageName: const $pb.PackageName('grpc.testing'))
    ..hasRequiredFields = false
  ;

  @$core.Deprecated(
  'Using this can add significant overhead to your binary. '
  'Use [GeneratedMessageGenericExtensions.deepCopy] instead. '
  'Will be removed in next major version')
  LoadBalancerStatsResponse_RpcsByPeer clone() => LoadBalancerStatsResponse_RpcsByPeer()..mergeFromMessage(this);
  @$core.Deprecated(
  'Using this can add significant overhead to your binary. '
  'Use [GeneratedMessageGenericExtensions.rebuild] instead. '
  'Will be removed in next major version')
  LoadBalancerStatsResponse_RpcsByPeer copyWith(void Function(LoadBalancerStatsResponse_RpcsByPeer) updates) => super.copyWith((message) => updates(message as LoadBalancerStatsResponse_RpcsByPeer)) as LoadBalancerStatsResponse_RpcsByPeer;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static LoadBalancerStatsResponse_RpcsByPeer create() => LoadBalancerStatsResponse_RpcsByPeer._();
  LoadBalancerStatsResponse_RpcsByPeer createEmptyInstance() => create();
  static $pb.PbList<LoadBalancerStatsResponse_RpcsByPeer> createRepeated() => $pb.PbList<LoadBalancerStatsResponse_RpcsByPeer>();
  @$core.pragma('dart2js:noInline')
  static LoadBalancerStatsResponse_RpcsByPeer getDefault() => _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<LoadBalancerStatsResponse_RpcsByPeer>(create);
  static LoadBalancerStatsResponse_RpcsByPeer? _defaultInstance;

  /// The number of completed RPCs for each peer.
  @$pb.TagNumber(1)
  $core.Map<$core.String, $core.int> get rpcsByPeer => $_getMap(0);
}

class LoadBalancerStatsResponse extends $pb.GeneratedMessage {
  factory LoadBalancerStatsResponse({
    $core.Map<$core.String, $core.int>? rpcsByPeer,
    $core.int? numFailures,
    $core.Map<$core.String, LoadBalancerStatsResponse_RpcsByPeer>? rpcsByMethod,
  }) {
    final $result = create();
    if (rpcsByPeer != null) {
      $result.rpcsByPeer.addAll(rpcsByPeer);
    }
    if (numFailures != null) {
      $result.numFailures = numFailures;
    }
    if (rpcsByMethod != null) {
      $result.rpcsByMethod.addAll(rpcsByMethod);
    }
    return $result;
  }
  LoadBalancerStatsResponse._() : super();
  factory LoadBalancerStatsResponse.fromBuffer($core.List<$core.int> i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromBuffer(i, r);
  factory LoadBalancerStatsResponse.fromJson($core.String i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'LoadBalancerStatsResponse', package: const $pb.PackageName(_omitMessageNames ? '' : 'grpc.testing'), createEmptyInstance: create)
    ..m<$core.String, $core.int>(1, _omitFieldNames ? '' : 'rpcsByPeer', entryClassName: 'LoadBalancerStatsResponse.RpcsByPeerEntry', keyFieldType: $pb.PbFieldType.OS, valueFieldType: $pb.PbFieldType.O3, packageName: const $pb.PackageName('grpc.testing'))
    ..a<$core.int>(2, _omitFieldNames ? '' : 'numFailures', $pb.PbFieldType.O3)
    ..m<$core.String, LoadBalancerStatsResponse_RpcsByPeer>(3, _omitFieldNames ? '' : 'rpcsByMethod', entryClassName: 'LoadBalancerStatsResponse.RpcsByMethodEntry', keyFieldType: $pb.PbFieldType.OS, valueFieldType: $pb.PbFieldType.OM, valueCreator: LoadBalancerStatsResponse_RpcsByPeer.create, valueDefaultOrMaker: LoadBalancerStatsResponse_RpcsByPeer.getDefault, packageName: const $pb.PackageName('grpc.testing'))
    ..hasRequiredFields = false
  ;

  @$core.Deprecated(
  'Using this can add significant overhead to your binary. '
  'Use [GeneratedMessageGenericExtensions.deepCopy] instead. '
  'Will be removed in next major version')
  LoadBalancerStatsResponse clone() => LoadBalancerStatsResponse()..mergeFromMessage(this);
  @$core.Deprecated(
  'Using this can add significant overhead to your binary. '
  'Use [GeneratedMessageGenericExtensions.rebuild] instead. '
  'Will be removed in next major version')
  LoadBalancerStatsResponse copyWith(void Function(LoadBalancerStatsResponse) updates) => super.copyWith((message) => updates(message as LoadBalancerStatsResponse)) as LoadBalancerStatsResponse;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static LoadBalancerStatsResponse create() => LoadBalancerStatsResponse._();
  LoadBalancerStatsResponse createEmptyInstance() => create();
  static $pb.PbList<LoadBalancerStatsResponse> createRepeated() => $pb.PbList<LoadBalancerStatsResponse>();
  @$core.pragma('dart2js:noInline')
  static LoadBalancerStatsResponse getDefault() => _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<LoadBalancerStatsResponse>(create);
  static LoadBalancerStatsResponse? _defaultInstance;

  /// The number of completed RPCs for each peer.
  @$pb.TagNumber(1)
  $core.Map<$core.String, $core.int> get rpcsByPeer => $_getMap(0);

  /// The number of RPCs that failed to record a remote peer.
  @$pb.TagNumber(2)
  $core.int get numFailures => $_getIZ(1);
  @$pb.TagNumber(2)
  set numFailures($core.int v) { $_setSignedInt32(1, v); }
  @$pb.TagNumber(2)
  $core.bool hasNumFailures() => $_has(1);
  @$pb.TagNumber(2)
  void clearNumFailures() => clearField(2);

  @$pb.TagNumber(3)
  $core.Map<$core.String, LoadBalancerStatsResponse_RpcsByPeer> get rpcsByMethod => $_getMap(2);
}

/// Request for retrieving a test client's accumulated stats.
class LoadBalancerAccumulatedStatsRequest extends $pb.GeneratedMessage {
  factory LoadBalancerAccumulatedStatsRequest() => create();
  LoadBalancerAccumulatedStatsRequest._() : super();
  factory LoadBalancerAccumulatedStatsRequest.fromBuffer($core.List<$core.int> i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromBuffer(i, r);
  factory LoadBalancerAccumulatedStatsRequest.fromJson($core.String i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'LoadBalancerAccumulatedStatsRequest', package: const $pb.PackageName(_omitMessageNames ? '' : 'grpc.testing'), createEmptyInstance: create)
    ..hasRequiredFields = false
  ;

  @$core.Deprecated(
  'Using this can add significant overhead to your binary. '
  'Use [GeneratedMessageGenericExtensions.deepCopy] instead. '
  'Will be removed in next major version')
  LoadBalancerAccumulatedStatsRequest clone() => LoadBalancerAccumulatedStatsRequest()..mergeFromMessage(this);
  @$core.Deprecated(
  'Using this can add significant overhead to your binary. '
  'Use [GeneratedMessageGenericExtensions.rebuild] instead. '
  'Will be removed in next major version')
  LoadBalancerAccumulatedStatsRequest copyWith(void Function(LoadBalancerAccumulatedStatsRequest) updates) => super.copyWith((message) => updates(message as LoadBalancerAccumulatedStatsRequest)) as LoadBalancerAccumulatedStatsRequest;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static LoadBalancerAccumulatedStatsRequest create() => LoadBalancerAccumulatedStatsRequest._();
  LoadBalancerAccumulatedStatsRequest createEmptyInstance() => create();
  static $pb.PbList<LoadBalancerAccumulatedStatsRequest> createRepeated() => $pb.PbList<LoadBalancerAccumulatedStatsRequest>();
  @$core.pragma('dart2js:noInline')
  static LoadBalancerAccumulatedStatsRequest getDefault() => _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<LoadBalancerAccumulatedStatsRequest>(create);
  static LoadBalancerAccumulatedStatsRequest? _defaultInstance;
}

class LoadBalancerAccumulatedStatsResponse_MethodStats extends $pb.GeneratedMessage {
  factory LoadBalancerAccumulatedStatsResponse_MethodStats({
    $core.int? rpcsStarted,
    $core.Map<$core.int, $core.int>? result,
  }) {
    final $result = create();
    if (rpcsStarted != null) {
      $result.rpcsStarted = rpcsStarted;
    }
    if (result != null) {
      $result.result.addAll(result);
    }
    return $result;
  }
  LoadBalancerAccumulatedStatsResponse_MethodStats._() : super();
  factory LoadBalancerAccumulatedStatsResponse_MethodStats.fromBuffer($core.List<$core.int> i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromBuffer(i, r);
  factory LoadBalancerAccumulatedStatsResponse_MethodStats.fromJson($core.String i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'LoadBalancerAccumulatedStatsResponse.MethodStats', package: const $pb.PackageName(_omitMessageNames ? '' : 'grpc.testing'), createEmptyInstance: create)
    ..a<$core.int>(1, _omitFieldNames ? '' : 'rpcsStarted', $pb.PbFieldType.O3)
    ..m<$core.int, $core.int>(2, _omitFieldNames ? '' : 'result', entryClassName: 'LoadBalancerAccumulatedStatsResponse.MethodStats.ResultEntry', keyFieldType: $pb.PbFieldType.O3, valueFieldType: $pb.PbFieldType.O3, packageName: const $pb.PackageName('grpc.testing'))
    ..hasRequiredFields = false
  ;

  @$core.Deprecated(
  'Using this can add significant overhead to your binary. '
  'Use [GeneratedMessageGenericExtensions.deepCopy] instead. '
  'Will be removed in next major version')
  LoadBalancerAccumulatedStatsResponse_MethodStats clone() => LoadBalancerAccumulatedStatsResponse_MethodStats()..mergeFromMessage(this);
  @$core.Deprecated(
  'Using this can add significant overhead to your binary. '
  'Use [GeneratedMessageGenericExtensions.rebuild] instead. '
  'Will be removed in next major version')
  LoadBalancerAccumulatedStatsResponse_MethodStats copyWith(void Function(LoadBalancerAccumulatedStatsResponse_MethodStats) updates) => super.copyWith((message) => updates(message as LoadBalancerAccumulatedStatsResponse_MethodStats)) as LoadBalancerAccumulatedStatsResponse_MethodStats;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static LoadBalancerAccumulatedStatsResponse_MethodStats create() => LoadBalancerAccumulatedStatsResponse_MethodStats._();
  LoadBalancerAccumulatedStatsResponse_MethodStats createEmptyInstance() => create();
  static $pb.PbList<LoadBalancerAccumulatedStatsResponse_MethodStats> createRepeated() => $pb.PbList<LoadBalancerAccumulatedStatsResponse_MethodStats>();
  @$core.pragma('dart2js:noInline')
  static LoadBalancerAccumulatedStatsResponse_MethodStats getDefault() => _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<LoadBalancerAccumulatedStatsResponse_MethodStats>(create);
  static LoadBalancerAccumulatedStatsResponse_MethodStats? _defaultInstance;

  /// The number of RPCs that were started for this method.
  @$pb.TagNumber(1)
  $core.int get rpcsStarted => $_getIZ(0);
  @$pb.TagNumber(1)
  set rpcsStarted($core.int v) { $_setSignedInt32(0, v); }
  @$pb.TagNumber(1)
  $core.bool hasRpcsStarted() => $_has(0);
  @$pb.TagNumber(1)
  void clearRpcsStarted() => clearField(1);

  /// The number of RPCs that completed with each status for this method.  The
  /// key is the integral value of a google.rpc.Code; the value is the count.
  @$pb.TagNumber(2)
  $core.Map<$core.int, $core.int> get result => $_getMap(1);
}

/// Accumulated stats for RPCs sent by a test client.
class LoadBalancerAccumulatedStatsResponse extends $pb.GeneratedMessage {
  factory LoadBalancerAccumulatedStatsResponse({
  @$core.Deprecated('This field is deprecated.')
    $core.Map<$core.String, $core.int>? numRpcsStartedByMethod,
  @$core.Deprecated('This field is deprecated.')
    $core.Map<$core.String, $core.int>? numRpcsSucceededByMethod,
  @$core.Deprecated('This field is deprecated.')
    $core.Map<$core.String, $core.int>? numRpcsFailedByMethod,
    $core.Map<$core.String, LoadBalancerAccumulatedStatsResponse_MethodStats>? statsPerMethod,
  }) {
    final $result = create();
    if (numRpcsStartedByMethod != null) {
      // ignore: deprecated_member_use_from_same_package
      $result.numRpcsStartedByMethod.addAll(numRpcsStartedByMethod);
    }
    if (numRpcsSucceededByMethod != null) {
      // ignore: deprecated_member_use_from_same_package
      $result.numRpcsSucceededByMethod.addAll(numRpcsSucceededByMethod);
    }
    if (numRpcsFailedByMethod != null) {
      // ignore: deprecated_member_use_from_same_package
      $result.numRpcsFailedByMethod.addAll(numRpcsFailedByMethod);
    }
    if (statsPerMethod != null) {
      $result.statsPerMethod.addAll(statsPerMethod);
    }
    return $result;
  }
  LoadBalancerAccumulatedStatsResponse._() : super();
  factory LoadBalancerAccumulatedStatsResponse.fromBuffer($core.List<$core.int> i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromBuffer(i, r);
  factory LoadBalancerAccumulatedStatsResponse.fromJson($core.String i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'LoadBalancerAccumulatedStatsResponse', package: const $pb.PackageName(_omitMessageNames ? '' : 'grpc.testing'), createEmptyInstance: create)
    ..m<$core.String, $core.int>(1, _omitFieldNames ? '' : 'numRpcsStartedByMethod', entryClassName: 'LoadBalancerAccumulatedStatsResponse.NumRpcsStartedByMethodEntry', keyFieldType: $pb.PbFieldType.OS, valueFieldType: $pb.PbFieldType.O3, packageName: const $pb.PackageName('grpc.testing'))
    ..m<$core.String, $core.int>(2, _omitFieldNames ? '' : 'numRpcsSucceededByMethod', entryClassName: 'LoadBalancerAccumulatedStatsResponse.NumRpcsSucceededByMethodEntry', keyFieldType: $pb.PbFieldType.OS, valueFieldType: $pb.PbFieldType.O3, packageName: const $pb.PackageName('grpc.testing'))
    ..m<$core.String, $core.int>(3, _omitFieldNames ? '' : 'numRpcsFailedByMethod', entryClassName: 'LoadBalancerAccumulatedStatsResponse.NumRpcsFailedByMethodEntry', keyFieldType: $pb.PbFieldType.OS, valueFieldType: $pb.PbFieldType.O3, packageName: const $pb.PackageName('grpc.testing'))
    ..m<$core.String, LoadBalancerAccumulatedStatsResponse_MethodStats>(4, _omitFieldNames ? '' : 'statsPerMethod', entryClassName: 'LoadBalancerAccumulatedStatsResponse.StatsPerMethodEntry', keyFieldType: $pb.PbFieldType.OS, valueFieldType: $pb.PbFieldType.OM, valueCreator: LoadBalancerAccumulatedStatsResponse_MethodStats.create, valueDefaultOrMaker: LoadBalancerAccumulatedStatsResponse_MethodStats.getDefault, packageName: const $pb.PackageName('grpc.testing'))
    ..hasRequiredFields = false
  ;

  @$core.Deprecated(
  'Using this can add significant overhead to your binary. '
  'Use [GeneratedMessageGenericExtensions.deepCopy] instead. '
  'Will be removed in next major version')
  LoadBalancerAccumulatedStatsResponse clone() => LoadBalancerAccumulatedStatsResponse()..mergeFromMessage(this);
  @$core.Deprecated(
  'Using this can add significant overhead to your binary. '
  'Use [GeneratedMessageGenericExtensions.rebuild] instead. '
  'Will be removed in next major version')
  LoadBalancerAccumulatedStatsResponse copyWith(void Function(LoadBalancerAccumulatedStatsResponse) updates) => super.copyWith((message) => updates(message as LoadBalancerAccumulatedStatsResponse)) as LoadBalancerAccumulatedStatsResponse;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static LoadBalancerAccumulatedStatsResponse create() => LoadBalancerAccumulatedStatsResponse._();
  LoadBalancerAccumulatedStatsResponse createEmptyInstance() => create();
  static $pb.PbList<LoadBalancerAccumulatedStatsResponse> createRepeated() => $pb.PbList<LoadBalancerAccumulatedStatsResponse>();
  @$core.pragma('dart2js:noInline')
  static LoadBalancerAccumulatedStatsResponse getDefault() => _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<LoadBalancerAccumulatedStatsResponse>(create);
  static LoadBalancerAccumulatedStatsResponse? _defaultInstance;

  /// The total number of RPCs have ever issued for each type.
  /// Deprecated: use stats_per_method.rpcs_started instead.
  @$core.Deprecated('This field is deprecated.')
  @$pb.TagNumber(1)
  $core.Map<$core.String, $core.int> get numRpcsStartedByMethod => $_getMap(0);

  /// The total number of RPCs have ever completed successfully for each type.
  /// Deprecated: use stats_per_method.result instead.
  @$core.Deprecated('This field is deprecated.')
  @$pb.TagNumber(2)
  $core.Map<$core.String, $core.int> get numRpcsSucceededByMethod => $_getMap(1);

  /// The total number of RPCs have ever failed for each type.
  /// Deprecated: use stats_per_method.result instead.
  @$core.Deprecated('This field is deprecated.')
  @$pb.TagNumber(3)
  $core.Map<$core.String, $core.int> get numRpcsFailedByMethod => $_getMap(2);

  /// Per-method RPC statistics.  The key is the RpcType in string form; e.g.
  /// 'EMPTY_CALL' or 'UNARY_CALL'
  @$pb.TagNumber(4)
  $core.Map<$core.String, LoadBalancerAccumulatedStatsResponse_MethodStats> get statsPerMethod => $_getMap(3);
}

/// Metadata to be attached for the given type of RPCs.
class ClientConfigureRequest_Metadata extends $pb.GeneratedMessage {
  factory ClientConfigureRequest_Metadata({
    ClientConfigureRequest_RpcType? type,
    $core.String? key,
    $core.String? value,
  }) {
    final $result = create();
    if (type != null) {
      $result.type = type;
    }
    if (key != null) {
      $result.key = key;
    }
    if (value != null) {
      $result.value = value;
    }
    return $result;
  }
  ClientConfigureRequest_Metadata._() : super();
  factory ClientConfigureRequest_Metadata.fromBuffer($core.List<$core.int> i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromBuffer(i, r);
  factory ClientConfigureRequest_Metadata.fromJson($core.String i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'ClientConfigureRequest.Metadata', package: const $pb.PackageName(_omitMessageNames ? '' : 'grpc.testing'), createEmptyInstance: create)
    ..e<ClientConfigureRequest_RpcType>(1, _omitFieldNames ? '' : 'type', $pb.PbFieldType.OE, defaultOrMaker: ClientConfigureRequest_RpcType.EMPTY_CALL, valueOf: ClientConfigureRequest_RpcType.valueOf, enumValues: ClientConfigureRequest_RpcType.values)
    ..aOS(2, _omitFieldNames ? '' : 'key')
    ..aOS(3, _omitFieldNames ? '' : 'value')
    ..hasRequiredFields = false
  ;

  @$core.Deprecated(
  'Using this can add significant overhead to your binary. '
  'Use [GeneratedMessageGenericExtensions.deepCopy] instead. '
  'Will be removed in next major version')
  ClientConfigureRequest_Metadata clone() => ClientConfigureRequest_Metadata()..mergeFromMessage(this);
  @$core.Deprecated(
  'Using this can add significant overhead to your binary. '
  'Use [GeneratedMessageGenericExtensions.rebuild] instead. '
  'Will be removed in next major version')
  ClientConfigureRequest_Metadata copyWith(void Function(ClientConfigureRequest_Metadata) updates) => super.copyWith((message) => updates(message as ClientConfigureRequest_Metadata)) as ClientConfigureRequest_Metadata;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static ClientConfigureRequest_Metadata create() => ClientConfigureRequest_Metadata._();
  ClientConfigureRequest_Metadata createEmptyInstance() => create();
  static $pb.PbList<ClientConfigureRequest_Metadata> createRepeated() => $pb.PbList<ClientConfigureRequest_Metadata>();
  @$core.pragma('dart2js:noInline')
  static ClientConfigureRequest_Metadata getDefault() => _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<ClientConfigureRequest_Metadata>(create);
  static ClientConfigureRequest_Metadata? _defaultInstance;

  @$pb.TagNumber(1)
  ClientConfigureRequest_RpcType get type => $_getN(0);
  @$pb.TagNumber(1)
  set type(ClientConfigureRequest_RpcType v) { setField(1, v); }
  @$pb.TagNumber(1)
  $core.bool hasType() => $_has(0);
  @$pb.TagNumber(1)
  void clearType() => clearField(1);

  @$pb.TagNumber(2)
  $core.String get key => $_getSZ(1);
  @$pb.TagNumber(2)
  set key($core.String v) { $_setString(1, v); }
  @$pb.TagNumber(2)
  $core.bool hasKey() => $_has(1);
  @$pb.TagNumber(2)
  void clearKey() => clearField(2);

  @$pb.TagNumber(3)
  $core.String get value => $_getSZ(2);
  @$pb.TagNumber(3)
  set value($core.String v) { $_setString(2, v); }
  @$pb.TagNumber(3)
  $core.bool hasValue() => $_has(2);
  @$pb.TagNumber(3)
  void clearValue() => clearField(3);
}

/// Configurations for a test client.
class ClientConfigureRequest extends $pb.GeneratedMessage {
  factory ClientConfigureRequest({
    $core.Iterable<ClientConfigureRequest_RpcType>? types,
    $core.Iterable<ClientConfigureRequest_Metadata>? metadata,
    $core.int? timeoutSec,
  }) {
    final $result = create();
    if (types != null) {
      $result.types.addAll(types);
    }
    if (metadata != null) {
      $result.metadata.addAll(metadata);
    }
    if (timeoutSec != null) {
      $result.timeoutSec = timeoutSec;
    }
    return $result;
  }
  ClientConfigureRequest._() : super();
  factory ClientConfigureRequest.fromBuffer($core.List<$core.int> i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromBuffer(i, r);
  factory ClientConfigureRequest.fromJson($core.String i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'ClientConfigureRequest', package: const $pb.PackageName(_omitMessageNames ? '' : 'grpc.testing'), createEmptyInstance: create)
    ..pc<ClientConfigureRequest_RpcType>(1, _omitFieldNames ? '' : 'types', $pb.PbFieldType.KE, valueOf: ClientConfigureRequest_RpcType.valueOf, enumValues: ClientConfigureRequest_RpcType.values, defaultEnumValue: ClientConfigureRequest_RpcType.EMPTY_CALL)
    ..pc<ClientConfigureRequest_Metadata>(2, _omitFieldNames ? '' : 'metadata', $pb.PbFieldType.PM, subBuilder: ClientConfigureRequest_Metadata.create)
    ..a<$core.int>(3, _omitFieldNames ? '' : 'timeoutSec', $pb.PbFieldType.O3)
    ..hasRequiredFields = false
  ;

  @$core.Deprecated(
  'Using this can add significant overhead to your binary. '
  'Use [GeneratedMessageGenericExtensions.deepCopy] instead. '
  'Will be removed in next major version')
  ClientConfigureRequest clone() => ClientConfigureRequest()..mergeFromMessage(this);
  @$core.Deprecated(
  'Using this can add significant overhead to your binary. '
  'Use [GeneratedMessageGenericExtensions.rebuild] instead. '
  'Will be removed in next major version')
  ClientConfigureRequest copyWith(void Function(ClientConfigureRequest) updates) => super.copyWith((message) => updates(message as ClientConfigureRequest)) as ClientConfigureRequest;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static ClientConfigureRequest create() => ClientConfigureRequest._();
  ClientConfigureRequest createEmptyInstance() => create();
  static $pb.PbList<ClientConfigureRequest> createRepeated() => $pb.PbList<ClientConfigureRequest>();
  @$core.pragma('dart2js:noInline')
  static ClientConfigureRequest getDefault() => _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<ClientConfigureRequest>(create);
  static ClientConfigureRequest? _defaultInstance;

  /// The types of RPCs the client sends.
  @$pb.TagNumber(1)
  $core.List<ClientConfigureRequest_RpcType> get types => $_getList(0);

  /// The collection of custom metadata to be attached to RPCs sent by the client.
  @$pb.TagNumber(2)
  $core.List<ClientConfigureRequest_Metadata> get metadata => $_getList(1);

  /// The deadline to use, in seconds, for all RPCs.  If unset or zero, the
  /// client will use the default from the command-line.
  @$pb.TagNumber(3)
  $core.int get timeoutSec => $_getIZ(2);
  @$pb.TagNumber(3)
  set timeoutSec($core.int v) { $_setSignedInt32(2, v); }
  @$pb.TagNumber(3)
  $core.bool hasTimeoutSec() => $_has(2);
  @$pb.TagNumber(3)
  void clearTimeoutSec() => clearField(3);
}

/// Response for updating a test client's configuration.
class ClientConfigureResponse extends $pb.GeneratedMessage {
  factory ClientConfigureResponse() => create();
  ClientConfigureResponse._() : super();
  factory ClientConfigureResponse.fromBuffer($core.List<$core.int> i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromBuffer(i, r);
  factory ClientConfigureResponse.fromJson($core.String i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'ClientConfigureResponse', package: const $pb.PackageName(_omitMessageNames ? '' : 'grpc.testing'), createEmptyInstance: create)
    ..hasRequiredFields = false
  ;

  @$core.Deprecated(
  'Using this can add significant overhead to your binary. '
  'Use [GeneratedMessageGenericExtensions.deepCopy] instead. '
  'Will be removed in next major version')
  ClientConfigureResponse clone() => ClientConfigureResponse()..mergeFromMessage(this);
  @$core.Deprecated(
  'Using this can add significant overhead to your binary. '
  'Use [GeneratedMessageGenericExtensions.rebuild] instead. '
  'Will be removed in next major version')
  ClientConfigureResponse copyWith(void Function(ClientConfigureResponse) updates) => super.copyWith((message) => updates(message as ClientConfigureResponse)) as ClientConfigureResponse;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static ClientConfigureResponse create() => ClientConfigureResponse._();
  ClientConfigureResponse createEmptyInstance() => create();
  static $pb.PbList<ClientConfigureResponse> createRepeated() => $pb.PbList<ClientConfigureResponse>();
  @$core.pragma('dart2js:noInline')
  static ClientConfigureResponse getDefault() => _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<ClientConfigureResponse>(create);
  static ClientConfigureResponse? _defaultInstance;
}

/// Metrics data the server will update and send to the client. It mirrors orca load report
/// https://github.com/cncf/xds/blob/eded343319d09f30032952beda9840bbd3dcf7ac/xds/data/orca/v3/orca_load_report.proto#L15,
/// but avoids orca dependency. Used by both per-query and out-of-band reporting tests.
class TestOrcaReport extends $pb.GeneratedMessage {
  factory TestOrcaReport({
    $core.double? cpuUtilization,
    $core.double? memoryUtilization,
    $core.Map<$core.String, $core.double>? requestCost,
    $core.Map<$core.String, $core.double>? utilization,
  }) {
    final $result = create();
    if (cpuUtilization != null) {
      $result.cpuUtilization = cpuUtilization;
    }
    if (memoryUtilization != null) {
      $result.memoryUtilization = memoryUtilization;
    }
    if (requestCost != null) {
      $result.requestCost.addAll(requestCost);
    }
    if (utilization != null) {
      $result.utilization.addAll(utilization);
    }
    return $result;
  }
  TestOrcaReport._() : super();
  factory TestOrcaReport.fromBuffer($core.List<$core.int> i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromBuffer(i, r);
  factory TestOrcaReport.fromJson($core.String i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'TestOrcaReport', package: const $pb.PackageName(_omitMessageNames ? '' : 'grpc.testing'), createEmptyInstance: create)
    ..a<$core.double>(1, _omitFieldNames ? '' : 'cpuUtilization', $pb.PbFieldType.OD)
    ..a<$core.double>(2, _omitFieldNames ? '' : 'memoryUtilization', $pb.PbFieldType.OD)
    ..m<$core.String, $core.double>(3, _omitFieldNames ? '' : 'requestCost', entryClassName: 'TestOrcaReport.RequestCostEntry', keyFieldType: $pb.PbFieldType.OS, valueFieldType: $pb.PbFieldType.OD, packageName: const $pb.PackageName('grpc.testing'))
    ..m<$core.String, $core.double>(4, _omitFieldNames ? '' : 'utilization', entryClassName: 'TestOrcaReport.UtilizationEntry', keyFieldType: $pb.PbFieldType.OS, valueFieldType: $pb.PbFieldType.OD, packageName: const $pb.PackageName('grpc.testing'))
    ..hasRequiredFields = false
  ;

  @$core.Deprecated(
  'Using this can add significant overhead to your binary. '
  'Use [GeneratedMessageGenericExtensions.deepCopy] instead. '
  'Will be removed in next major version')
  TestOrcaReport clone() => TestOrcaReport()..mergeFromMessage(this);
  @$core.Deprecated(
  'Using this can add significant overhead to your binary. '
  'Use [GeneratedMessageGenericExtensions.rebuild] instead. '
  'Will be removed in next major version')
  TestOrcaReport copyWith(void Function(TestOrcaReport) updates) => super.copyWith((message) => updates(message as TestOrcaReport)) as TestOrcaReport;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static TestOrcaReport create() => TestOrcaReport._();
  TestOrcaReport createEmptyInstance() => create();
  static $pb.PbList<TestOrcaReport> createRepeated() => $pb.PbList<TestOrcaReport>();
  @$core.pragma('dart2js:noInline')
  static TestOrcaReport getDefault() => _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<TestOrcaReport>(create);
  static TestOrcaReport? _defaultInstance;

  @$pb.TagNumber(1)
  $core.double get cpuUtilization => $_getN(0);
  @$pb.TagNumber(1)
  set cpuUtilization($core.double v) { $_setDouble(0, v); }
  @$pb.TagNumber(1)
  $core.bool hasCpuUtilization() => $_has(0);
  @$pb.TagNumber(1)
  void clearCpuUtilization() => clearField(1);

  @$pb.TagNumber(2)
  $core.double get memoryUtilization => $_getN(1);
  @$pb.TagNumber(2)
  set memoryUtilization($core.double v) { $_setDouble(1, v); }
  @$pb.TagNumber(2)
  $core.bool hasMemoryUtilization() => $_has(1);
  @$pb.TagNumber(2)
  void clearMemoryUtilization() => clearField(2);

  @$pb.TagNumber(3)
  $core.Map<$core.String, $core.double> get requestCost => $_getMap(2);

  @$pb.TagNumber(4)
  $core.Map<$core.String, $core.double> get utilization => $_getMap(3);
}


const _omitFieldNames = $core.bool.fromEnvironment('protobuf.omit_field_names');
const _omitMessageNames = $core.bool.fromEnvironment('protobuf.omit_message_names');
