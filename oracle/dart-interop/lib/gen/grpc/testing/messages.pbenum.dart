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

/// The type of payload that should be returned.
class PayloadType extends $pb.ProtobufEnum {
  static const PayloadType COMPRESSABLE = PayloadType._(0, _omitEnumNames ? '' : 'COMPRESSABLE');

  static const $core.List<PayloadType> values = <PayloadType> [
    COMPRESSABLE,
  ];

  static final $core.Map<$core.int, PayloadType> _byValue = $pb.ProtobufEnum.initByValue(values);
  static PayloadType? valueOf($core.int value) => _byValue[value];

  const PayloadType._($core.int v, $core.String n) : super(v, n);
}

/// The type of route that a client took to reach a server w.r.t. gRPCLB.
/// The server must fill in "fallback" if it detects that the RPC reached
/// the server via the "gRPCLB fallback" path, and "backend" if it detects
/// that the RPC reached the server via "gRPCLB backend" path (i.e. if it got
/// the address of this server from the gRPCLB server BalanceLoad RPC). Exactly
/// how this detection is done is context and server dependent.
class GrpclbRouteType extends $pb.ProtobufEnum {
  static const GrpclbRouteType GRPCLB_ROUTE_TYPE_UNKNOWN = GrpclbRouteType._(0, _omitEnumNames ? '' : 'GRPCLB_ROUTE_TYPE_UNKNOWN');
  static const GrpclbRouteType GRPCLB_ROUTE_TYPE_FALLBACK = GrpclbRouteType._(1, _omitEnumNames ? '' : 'GRPCLB_ROUTE_TYPE_FALLBACK');
  static const GrpclbRouteType GRPCLB_ROUTE_TYPE_BACKEND = GrpclbRouteType._(2, _omitEnumNames ? '' : 'GRPCLB_ROUTE_TYPE_BACKEND');

  static const $core.List<GrpclbRouteType> values = <GrpclbRouteType> [
    GRPCLB_ROUTE_TYPE_UNKNOWN,
    GRPCLB_ROUTE_TYPE_FALLBACK,
    GRPCLB_ROUTE_TYPE_BACKEND,
  ];

  static final $core.Map<$core.int, GrpclbRouteType> _byValue = $pb.ProtobufEnum.initByValue(values);
  static GrpclbRouteType? valueOf($core.int value) => _byValue[value];

  const GrpclbRouteType._($core.int v, $core.String n) : super(v, n);
}

/// Type of RPCs to send.
class ClientConfigureRequest_RpcType extends $pb.ProtobufEnum {
  static const ClientConfigureRequest_RpcType EMPTY_CALL = ClientConfigureRequest_RpcType._(0, _omitEnumNames ? '' : 'EMPTY_CALL');
  static const ClientConfigureRequest_RpcType UNARY_CALL = ClientConfigureRequest_RpcType._(1, _omitEnumNames ? '' : 'UNARY_CALL');

  static const $core.List<ClientConfigureRequest_RpcType> values = <ClientConfigureRequest_RpcType> [
    EMPTY_CALL,
    UNARY_CALL,
  ];

  static final $core.Map<$core.int, ClientConfigureRequest_RpcType> _byValue = $pb.ProtobufEnum.initByValue(values);
  static ClientConfigureRequest_RpcType? valueOf($core.int value) => _byValue[value];

  const ClientConfigureRequest_RpcType._($core.int v, $core.String n) : super(v, n);
}


const _omitEnumNames = $core.bool.fromEnvironment('protobuf.omit_enum_names');
