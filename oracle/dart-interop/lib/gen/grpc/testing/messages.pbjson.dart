//
//  Generated code. Do not modify.
//  source: grpc/testing/messages.proto
//
// @dart = 2.12

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_final_fields
// ignore_for_file: unnecessary_import, unnecessary_this, unused_import

import 'dart:convert' as $convert;
import 'dart:core' as $core;
import 'dart:typed_data' as $typed_data;

@$core.Deprecated('Use payloadTypeDescriptor instead')
const PayloadType$json = {
  '1': 'PayloadType',
  '2': [
    {'1': 'COMPRESSABLE', '2': 0},
  ],
};

/// Descriptor for `PayloadType`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List payloadTypeDescriptor = $convert.base64Decode(
    'CgtQYXlsb2FkVHlwZRIQCgxDT01QUkVTU0FCTEUQAA==');

@$core.Deprecated('Use grpclbRouteTypeDescriptor instead')
const GrpclbRouteType$json = {
  '1': 'GrpclbRouteType',
  '2': [
    {'1': 'GRPCLB_ROUTE_TYPE_UNKNOWN', '2': 0},
    {'1': 'GRPCLB_ROUTE_TYPE_FALLBACK', '2': 1},
    {'1': 'GRPCLB_ROUTE_TYPE_BACKEND', '2': 2},
  ],
};

/// Descriptor for `GrpclbRouteType`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List grpclbRouteTypeDescriptor = $convert.base64Decode(
    'Cg9HcnBjbGJSb3V0ZVR5cGUSHQoZR1JQQ0xCX1JPVVRFX1RZUEVfVU5LTk9XThAAEh4KGkdSUE'
    'NMQl9ST1VURV9UWVBFX0ZBTExCQUNLEAESHQoZR1JQQ0xCX1JPVVRFX1RZUEVfQkFDS0VORBAC');

@$core.Deprecated('Use boolValueDescriptor instead')
const BoolValue$json = {
  '1': 'BoolValue',
  '2': [
    {'1': 'value', '3': 1, '4': 1, '5': 8, '10': 'value'},
  ],
};

/// Descriptor for `BoolValue`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List boolValueDescriptor = $convert.base64Decode(
    'CglCb29sVmFsdWUSFAoFdmFsdWUYASABKAhSBXZhbHVl');

@$core.Deprecated('Use payloadDescriptor instead')
const Payload$json = {
  '1': 'Payload',
  '2': [
    {'1': 'type', '3': 1, '4': 1, '5': 14, '6': '.grpc.testing.PayloadType', '10': 'type'},
    {'1': 'body', '3': 2, '4': 1, '5': 12, '10': 'body'},
  ],
};

/// Descriptor for `Payload`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List payloadDescriptor = $convert.base64Decode(
    'CgdQYXlsb2FkEi0KBHR5cGUYASABKA4yGS5ncnBjLnRlc3RpbmcuUGF5bG9hZFR5cGVSBHR5cG'
    'USEgoEYm9keRgCIAEoDFIEYm9keQ==');

@$core.Deprecated('Use echoStatusDescriptor instead')
const EchoStatus$json = {
  '1': 'EchoStatus',
  '2': [
    {'1': 'code', '3': 1, '4': 1, '5': 5, '10': 'code'},
    {'1': 'message', '3': 2, '4': 1, '5': 9, '10': 'message'},
  ],
};

/// Descriptor for `EchoStatus`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List echoStatusDescriptor = $convert.base64Decode(
    'CgpFY2hvU3RhdHVzEhIKBGNvZGUYASABKAVSBGNvZGUSGAoHbWVzc2FnZRgCIAEoCVIHbWVzc2'
    'FnZQ==');

@$core.Deprecated('Use simpleRequestDescriptor instead')
const SimpleRequest$json = {
  '1': 'SimpleRequest',
  '2': [
    {'1': 'response_type', '3': 1, '4': 1, '5': 14, '6': '.grpc.testing.PayloadType', '10': 'responseType'},
    {'1': 'response_size', '3': 2, '4': 1, '5': 5, '10': 'responseSize'},
    {'1': 'payload', '3': 3, '4': 1, '5': 11, '6': '.grpc.testing.Payload', '10': 'payload'},
    {'1': 'fill_username', '3': 4, '4': 1, '5': 8, '10': 'fillUsername'},
    {'1': 'fill_oauth_scope', '3': 5, '4': 1, '5': 8, '10': 'fillOauthScope'},
    {'1': 'response_compressed', '3': 6, '4': 1, '5': 11, '6': '.grpc.testing.BoolValue', '10': 'responseCompressed'},
    {'1': 'response_status', '3': 7, '4': 1, '5': 11, '6': '.grpc.testing.EchoStatus', '10': 'responseStatus'},
    {'1': 'expect_compressed', '3': 8, '4': 1, '5': 11, '6': '.grpc.testing.BoolValue', '10': 'expectCompressed'},
    {'1': 'fill_server_id', '3': 9, '4': 1, '5': 8, '10': 'fillServerId'},
    {'1': 'fill_grpclb_route_type', '3': 10, '4': 1, '5': 8, '10': 'fillGrpclbRouteType'},
    {'1': 'orca_per_query_report', '3': 11, '4': 1, '5': 11, '6': '.grpc.testing.TestOrcaReport', '10': 'orcaPerQueryReport'},
  ],
};

/// Descriptor for `SimpleRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List simpleRequestDescriptor = $convert.base64Decode(
    'Cg1TaW1wbGVSZXF1ZXN0Ej4KDXJlc3BvbnNlX3R5cGUYASABKA4yGS5ncnBjLnRlc3RpbmcuUG'
    'F5bG9hZFR5cGVSDHJlc3BvbnNlVHlwZRIjCg1yZXNwb25zZV9zaXplGAIgASgFUgxyZXNwb25z'
    'ZVNpemUSLwoHcGF5bG9hZBgDIAEoCzIVLmdycGMudGVzdGluZy5QYXlsb2FkUgdwYXlsb2FkEi'
    'MKDWZpbGxfdXNlcm5hbWUYBCABKAhSDGZpbGxVc2VybmFtZRIoChBmaWxsX29hdXRoX3Njb3Bl'
    'GAUgASgIUg5maWxsT2F1dGhTY29wZRJIChNyZXNwb25zZV9jb21wcmVzc2VkGAYgASgLMhcuZ3'
    'JwYy50ZXN0aW5nLkJvb2xWYWx1ZVIScmVzcG9uc2VDb21wcmVzc2VkEkEKD3Jlc3BvbnNlX3N0'
    'YXR1cxgHIAEoCzIYLmdycGMudGVzdGluZy5FY2hvU3RhdHVzUg5yZXNwb25zZVN0YXR1cxJECh'
    'FleHBlY3RfY29tcHJlc3NlZBgIIAEoCzIXLmdycGMudGVzdGluZy5Cb29sVmFsdWVSEGV4cGVj'
    'dENvbXByZXNzZWQSJAoOZmlsbF9zZXJ2ZXJfaWQYCSABKAhSDGZpbGxTZXJ2ZXJJZBIzChZmaW'
    'xsX2dycGNsYl9yb3V0ZV90eXBlGAogASgIUhNmaWxsR3JwY2xiUm91dGVUeXBlEk8KFW9yY2Ff'
    'cGVyX3F1ZXJ5X3JlcG9ydBgLIAEoCzIcLmdycGMudGVzdGluZy5UZXN0T3JjYVJlcG9ydFISb3'
    'JjYVBlclF1ZXJ5UmVwb3J0');

@$core.Deprecated('Use simpleResponseDescriptor instead')
const SimpleResponse$json = {
  '1': 'SimpleResponse',
  '2': [
    {'1': 'payload', '3': 1, '4': 1, '5': 11, '6': '.grpc.testing.Payload', '10': 'payload'},
    {'1': 'username', '3': 2, '4': 1, '5': 9, '10': 'username'},
    {'1': 'oauth_scope', '3': 3, '4': 1, '5': 9, '10': 'oauthScope'},
    {'1': 'server_id', '3': 4, '4': 1, '5': 9, '10': 'serverId'},
    {'1': 'grpclb_route_type', '3': 5, '4': 1, '5': 14, '6': '.grpc.testing.GrpclbRouteType', '10': 'grpclbRouteType'},
    {'1': 'hostname', '3': 6, '4': 1, '5': 9, '10': 'hostname'},
  ],
};

/// Descriptor for `SimpleResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List simpleResponseDescriptor = $convert.base64Decode(
    'Cg5TaW1wbGVSZXNwb25zZRIvCgdwYXlsb2FkGAEgASgLMhUuZ3JwYy50ZXN0aW5nLlBheWxvYW'
    'RSB3BheWxvYWQSGgoIdXNlcm5hbWUYAiABKAlSCHVzZXJuYW1lEh8KC29hdXRoX3Njb3BlGAMg'
    'ASgJUgpvYXV0aFNjb3BlEhsKCXNlcnZlcl9pZBgEIAEoCVIIc2VydmVySWQSSQoRZ3JwY2xiX3'
    'JvdXRlX3R5cGUYBSABKA4yHS5ncnBjLnRlc3RpbmcuR3JwY2xiUm91dGVUeXBlUg9ncnBjbGJS'
    'b3V0ZVR5cGUSGgoIaG9zdG5hbWUYBiABKAlSCGhvc3RuYW1l');

@$core.Deprecated('Use streamingInputCallRequestDescriptor instead')
const StreamingInputCallRequest$json = {
  '1': 'StreamingInputCallRequest',
  '2': [
    {'1': 'payload', '3': 1, '4': 1, '5': 11, '6': '.grpc.testing.Payload', '10': 'payload'},
    {'1': 'expect_compressed', '3': 2, '4': 1, '5': 11, '6': '.grpc.testing.BoolValue', '10': 'expectCompressed'},
  ],
};

/// Descriptor for `StreamingInputCallRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List streamingInputCallRequestDescriptor = $convert.base64Decode(
    'ChlTdHJlYW1pbmdJbnB1dENhbGxSZXF1ZXN0Ei8KB3BheWxvYWQYASABKAsyFS5ncnBjLnRlc3'
    'RpbmcuUGF5bG9hZFIHcGF5bG9hZBJEChFleHBlY3RfY29tcHJlc3NlZBgCIAEoCzIXLmdycGMu'
    'dGVzdGluZy5Cb29sVmFsdWVSEGV4cGVjdENvbXByZXNzZWQ=');

@$core.Deprecated('Use streamingInputCallResponseDescriptor instead')
const StreamingInputCallResponse$json = {
  '1': 'StreamingInputCallResponse',
  '2': [
    {'1': 'aggregated_payload_size', '3': 1, '4': 1, '5': 5, '10': 'aggregatedPayloadSize'},
  ],
};

/// Descriptor for `StreamingInputCallResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List streamingInputCallResponseDescriptor = $convert.base64Decode(
    'ChpTdHJlYW1pbmdJbnB1dENhbGxSZXNwb25zZRI2ChdhZ2dyZWdhdGVkX3BheWxvYWRfc2l6ZR'
    'gBIAEoBVIVYWdncmVnYXRlZFBheWxvYWRTaXpl');

@$core.Deprecated('Use responseParametersDescriptor instead')
const ResponseParameters$json = {
  '1': 'ResponseParameters',
  '2': [
    {'1': 'size', '3': 1, '4': 1, '5': 5, '10': 'size'},
    {'1': 'interval_us', '3': 2, '4': 1, '5': 5, '10': 'intervalUs'},
    {'1': 'compressed', '3': 3, '4': 1, '5': 11, '6': '.grpc.testing.BoolValue', '10': 'compressed'},
  ],
};

/// Descriptor for `ResponseParameters`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List responseParametersDescriptor = $convert.base64Decode(
    'ChJSZXNwb25zZVBhcmFtZXRlcnMSEgoEc2l6ZRgBIAEoBVIEc2l6ZRIfCgtpbnRlcnZhbF91cx'
    'gCIAEoBVIKaW50ZXJ2YWxVcxI3Cgpjb21wcmVzc2VkGAMgASgLMhcuZ3JwYy50ZXN0aW5nLkJv'
    'b2xWYWx1ZVIKY29tcHJlc3NlZA==');

@$core.Deprecated('Use streamingOutputCallRequestDescriptor instead')
const StreamingOutputCallRequest$json = {
  '1': 'StreamingOutputCallRequest',
  '2': [
    {'1': 'response_type', '3': 1, '4': 1, '5': 14, '6': '.grpc.testing.PayloadType', '10': 'responseType'},
    {'1': 'response_parameters', '3': 2, '4': 3, '5': 11, '6': '.grpc.testing.ResponseParameters', '10': 'responseParameters'},
    {'1': 'payload', '3': 3, '4': 1, '5': 11, '6': '.grpc.testing.Payload', '10': 'payload'},
    {'1': 'response_status', '3': 7, '4': 1, '5': 11, '6': '.grpc.testing.EchoStatus', '10': 'responseStatus'},
    {'1': 'orca_oob_report', '3': 8, '4': 1, '5': 11, '6': '.grpc.testing.TestOrcaReport', '10': 'orcaOobReport'},
  ],
};

/// Descriptor for `StreamingOutputCallRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List streamingOutputCallRequestDescriptor = $convert.base64Decode(
    'ChpTdHJlYW1pbmdPdXRwdXRDYWxsUmVxdWVzdBI+Cg1yZXNwb25zZV90eXBlGAEgASgOMhkuZ3'
    'JwYy50ZXN0aW5nLlBheWxvYWRUeXBlUgxyZXNwb25zZVR5cGUSUQoTcmVzcG9uc2VfcGFyYW1l'
    'dGVycxgCIAMoCzIgLmdycGMudGVzdGluZy5SZXNwb25zZVBhcmFtZXRlcnNSEnJlc3BvbnNlUG'
    'FyYW1ldGVycxIvCgdwYXlsb2FkGAMgASgLMhUuZ3JwYy50ZXN0aW5nLlBheWxvYWRSB3BheWxv'
    'YWQSQQoPcmVzcG9uc2Vfc3RhdHVzGAcgASgLMhguZ3JwYy50ZXN0aW5nLkVjaG9TdGF0dXNSDn'
    'Jlc3BvbnNlU3RhdHVzEkQKD29yY2Ffb29iX3JlcG9ydBgIIAEoCzIcLmdycGMudGVzdGluZy5U'
    'ZXN0T3JjYVJlcG9ydFINb3JjYU9vYlJlcG9ydA==');

@$core.Deprecated('Use streamingOutputCallResponseDescriptor instead')
const StreamingOutputCallResponse$json = {
  '1': 'StreamingOutputCallResponse',
  '2': [
    {'1': 'payload', '3': 1, '4': 1, '5': 11, '6': '.grpc.testing.Payload', '10': 'payload'},
  ],
};

/// Descriptor for `StreamingOutputCallResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List streamingOutputCallResponseDescriptor = $convert.base64Decode(
    'ChtTdHJlYW1pbmdPdXRwdXRDYWxsUmVzcG9uc2USLwoHcGF5bG9hZBgBIAEoCzIVLmdycGMudG'
    'VzdGluZy5QYXlsb2FkUgdwYXlsb2Fk');

@$core.Deprecated('Use reconnectParamsDescriptor instead')
const ReconnectParams$json = {
  '1': 'ReconnectParams',
  '2': [
    {'1': 'max_reconnect_backoff_ms', '3': 1, '4': 1, '5': 5, '10': 'maxReconnectBackoffMs'},
  ],
};

/// Descriptor for `ReconnectParams`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List reconnectParamsDescriptor = $convert.base64Decode(
    'Cg9SZWNvbm5lY3RQYXJhbXMSNwoYbWF4X3JlY29ubmVjdF9iYWNrb2ZmX21zGAEgASgFUhVtYX'
    'hSZWNvbm5lY3RCYWNrb2ZmTXM=');

@$core.Deprecated('Use reconnectInfoDescriptor instead')
const ReconnectInfo$json = {
  '1': 'ReconnectInfo',
  '2': [
    {'1': 'passed', '3': 1, '4': 1, '5': 8, '10': 'passed'},
    {'1': 'backoff_ms', '3': 2, '4': 3, '5': 5, '10': 'backoffMs'},
  ],
};

/// Descriptor for `ReconnectInfo`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List reconnectInfoDescriptor = $convert.base64Decode(
    'Cg1SZWNvbm5lY3RJbmZvEhYKBnBhc3NlZBgBIAEoCFIGcGFzc2VkEh0KCmJhY2tvZmZfbXMYAi'
    'ADKAVSCWJhY2tvZmZNcw==');

@$core.Deprecated('Use loadBalancerStatsRequestDescriptor instead')
const LoadBalancerStatsRequest$json = {
  '1': 'LoadBalancerStatsRequest',
  '2': [
    {'1': 'num_rpcs', '3': 1, '4': 1, '5': 5, '10': 'numRpcs'},
    {'1': 'timeout_sec', '3': 2, '4': 1, '5': 5, '10': 'timeoutSec'},
  ],
};

/// Descriptor for `LoadBalancerStatsRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List loadBalancerStatsRequestDescriptor = $convert.base64Decode(
    'ChhMb2FkQmFsYW5jZXJTdGF0c1JlcXVlc3QSGQoIbnVtX3JwY3MYASABKAVSB251bVJwY3MSHw'
    'oLdGltZW91dF9zZWMYAiABKAVSCnRpbWVvdXRTZWM=');

@$core.Deprecated('Use loadBalancerStatsResponseDescriptor instead')
const LoadBalancerStatsResponse$json = {
  '1': 'LoadBalancerStatsResponse',
  '2': [
    {'1': 'rpcs_by_peer', '3': 1, '4': 3, '5': 11, '6': '.grpc.testing.LoadBalancerStatsResponse.RpcsByPeerEntry', '10': 'rpcsByPeer'},
    {'1': 'num_failures', '3': 2, '4': 1, '5': 5, '10': 'numFailures'},
    {'1': 'rpcs_by_method', '3': 3, '4': 3, '5': 11, '6': '.grpc.testing.LoadBalancerStatsResponse.RpcsByMethodEntry', '10': 'rpcsByMethod'},
  ],
  '3': [LoadBalancerStatsResponse_RpcsByPeer$json, LoadBalancerStatsResponse_RpcsByPeerEntry$json, LoadBalancerStatsResponse_RpcsByMethodEntry$json],
};

@$core.Deprecated('Use loadBalancerStatsResponseDescriptor instead')
const LoadBalancerStatsResponse_RpcsByPeer$json = {
  '1': 'RpcsByPeer',
  '2': [
    {'1': 'rpcs_by_peer', '3': 1, '4': 3, '5': 11, '6': '.grpc.testing.LoadBalancerStatsResponse.RpcsByPeer.RpcsByPeerEntry', '10': 'rpcsByPeer'},
  ],
  '3': [LoadBalancerStatsResponse_RpcsByPeer_RpcsByPeerEntry$json],
};

@$core.Deprecated('Use loadBalancerStatsResponseDescriptor instead')
const LoadBalancerStatsResponse_RpcsByPeer_RpcsByPeerEntry$json = {
  '1': 'RpcsByPeerEntry',
  '2': [
    {'1': 'key', '3': 1, '4': 1, '5': 9, '10': 'key'},
    {'1': 'value', '3': 2, '4': 1, '5': 5, '10': 'value'},
  ],
  '7': {'7': true},
};

@$core.Deprecated('Use loadBalancerStatsResponseDescriptor instead')
const LoadBalancerStatsResponse_RpcsByPeerEntry$json = {
  '1': 'RpcsByPeerEntry',
  '2': [
    {'1': 'key', '3': 1, '4': 1, '5': 9, '10': 'key'},
    {'1': 'value', '3': 2, '4': 1, '5': 5, '10': 'value'},
  ],
  '7': {'7': true},
};

@$core.Deprecated('Use loadBalancerStatsResponseDescriptor instead')
const LoadBalancerStatsResponse_RpcsByMethodEntry$json = {
  '1': 'RpcsByMethodEntry',
  '2': [
    {'1': 'key', '3': 1, '4': 1, '5': 9, '10': 'key'},
    {'1': 'value', '3': 2, '4': 1, '5': 11, '6': '.grpc.testing.LoadBalancerStatsResponse.RpcsByPeer', '10': 'value'},
  ],
  '7': {'7': true},
};

/// Descriptor for `LoadBalancerStatsResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List loadBalancerStatsResponseDescriptor = $convert.base64Decode(
    'ChlMb2FkQmFsYW5jZXJTdGF0c1Jlc3BvbnNlElkKDHJwY3NfYnlfcGVlchgBIAMoCzI3LmdycG'
    'MudGVzdGluZy5Mb2FkQmFsYW5jZXJTdGF0c1Jlc3BvbnNlLlJwY3NCeVBlZXJFbnRyeVIKcnBj'
    'c0J5UGVlchIhCgxudW1fZmFpbHVyZXMYAiABKAVSC251bUZhaWx1cmVzEl8KDnJwY3NfYnlfbW'
    'V0aG9kGAMgAygLMjkuZ3JwYy50ZXN0aW5nLkxvYWRCYWxhbmNlclN0YXRzUmVzcG9uc2UuUnBj'
    'c0J5TWV0aG9kRW50cnlSDHJwY3NCeU1ldGhvZBqxAQoKUnBjc0J5UGVlchJkCgxycGNzX2J5X3'
    'BlZXIYASADKAsyQi5ncnBjLnRlc3RpbmcuTG9hZEJhbGFuY2VyU3RhdHNSZXNwb25zZS5ScGNz'
    'QnlQZWVyLlJwY3NCeVBlZXJFbnRyeVIKcnBjc0J5UGVlcho9Cg9ScGNzQnlQZWVyRW50cnkSEA'
    'oDa2V5GAEgASgJUgNrZXkSFAoFdmFsdWUYAiABKAVSBXZhbHVlOgI4ARo9Cg9ScGNzQnlQZWVy'
    'RW50cnkSEAoDa2V5GAEgASgJUgNrZXkSFAoFdmFsdWUYAiABKAVSBXZhbHVlOgI4ARpzChFScG'
    'NzQnlNZXRob2RFbnRyeRIQCgNrZXkYASABKAlSA2tleRJICgV2YWx1ZRgCIAEoCzIyLmdycGMu'
    'dGVzdGluZy5Mb2FkQmFsYW5jZXJTdGF0c1Jlc3BvbnNlLlJwY3NCeVBlZXJSBXZhbHVlOgI4AQ'
    '==');

@$core.Deprecated('Use loadBalancerAccumulatedStatsRequestDescriptor instead')
const LoadBalancerAccumulatedStatsRequest$json = {
  '1': 'LoadBalancerAccumulatedStatsRequest',
};

/// Descriptor for `LoadBalancerAccumulatedStatsRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List loadBalancerAccumulatedStatsRequestDescriptor = $convert.base64Decode(
    'CiNMb2FkQmFsYW5jZXJBY2N1bXVsYXRlZFN0YXRzUmVxdWVzdA==');

@$core.Deprecated('Use loadBalancerAccumulatedStatsResponseDescriptor instead')
const LoadBalancerAccumulatedStatsResponse$json = {
  '1': 'LoadBalancerAccumulatedStatsResponse',
  '2': [
    {
      '1': 'num_rpcs_started_by_method',
      '3': 1,
      '4': 3,
      '5': 11,
      '6': '.grpc.testing.LoadBalancerAccumulatedStatsResponse.NumRpcsStartedByMethodEntry',
      '8': {'3': true},
      '10': 'numRpcsStartedByMethod',
    },
    {
      '1': 'num_rpcs_succeeded_by_method',
      '3': 2,
      '4': 3,
      '5': 11,
      '6': '.grpc.testing.LoadBalancerAccumulatedStatsResponse.NumRpcsSucceededByMethodEntry',
      '8': {'3': true},
      '10': 'numRpcsSucceededByMethod',
    },
    {
      '1': 'num_rpcs_failed_by_method',
      '3': 3,
      '4': 3,
      '5': 11,
      '6': '.grpc.testing.LoadBalancerAccumulatedStatsResponse.NumRpcsFailedByMethodEntry',
      '8': {'3': true},
      '10': 'numRpcsFailedByMethod',
    },
    {'1': 'stats_per_method', '3': 4, '4': 3, '5': 11, '6': '.grpc.testing.LoadBalancerAccumulatedStatsResponse.StatsPerMethodEntry', '10': 'statsPerMethod'},
  ],
  '3': [LoadBalancerAccumulatedStatsResponse_NumRpcsStartedByMethodEntry$json, LoadBalancerAccumulatedStatsResponse_NumRpcsSucceededByMethodEntry$json, LoadBalancerAccumulatedStatsResponse_NumRpcsFailedByMethodEntry$json, LoadBalancerAccumulatedStatsResponse_MethodStats$json, LoadBalancerAccumulatedStatsResponse_StatsPerMethodEntry$json],
};

@$core.Deprecated('Use loadBalancerAccumulatedStatsResponseDescriptor instead')
const LoadBalancerAccumulatedStatsResponse_NumRpcsStartedByMethodEntry$json = {
  '1': 'NumRpcsStartedByMethodEntry',
  '2': [
    {'1': 'key', '3': 1, '4': 1, '5': 9, '10': 'key'},
    {'1': 'value', '3': 2, '4': 1, '5': 5, '10': 'value'},
  ],
  '7': {'7': true},
};

@$core.Deprecated('Use loadBalancerAccumulatedStatsResponseDescriptor instead')
const LoadBalancerAccumulatedStatsResponse_NumRpcsSucceededByMethodEntry$json = {
  '1': 'NumRpcsSucceededByMethodEntry',
  '2': [
    {'1': 'key', '3': 1, '4': 1, '5': 9, '10': 'key'},
    {'1': 'value', '3': 2, '4': 1, '5': 5, '10': 'value'},
  ],
  '7': {'7': true},
};

@$core.Deprecated('Use loadBalancerAccumulatedStatsResponseDescriptor instead')
const LoadBalancerAccumulatedStatsResponse_NumRpcsFailedByMethodEntry$json = {
  '1': 'NumRpcsFailedByMethodEntry',
  '2': [
    {'1': 'key', '3': 1, '4': 1, '5': 9, '10': 'key'},
    {'1': 'value', '3': 2, '4': 1, '5': 5, '10': 'value'},
  ],
  '7': {'7': true},
};

@$core.Deprecated('Use loadBalancerAccumulatedStatsResponseDescriptor instead')
const LoadBalancerAccumulatedStatsResponse_MethodStats$json = {
  '1': 'MethodStats',
  '2': [
    {'1': 'rpcs_started', '3': 1, '4': 1, '5': 5, '10': 'rpcsStarted'},
    {'1': 'result', '3': 2, '4': 3, '5': 11, '6': '.grpc.testing.LoadBalancerAccumulatedStatsResponse.MethodStats.ResultEntry', '10': 'result'},
  ],
  '3': [LoadBalancerAccumulatedStatsResponse_MethodStats_ResultEntry$json],
};

@$core.Deprecated('Use loadBalancerAccumulatedStatsResponseDescriptor instead')
const LoadBalancerAccumulatedStatsResponse_MethodStats_ResultEntry$json = {
  '1': 'ResultEntry',
  '2': [
    {'1': 'key', '3': 1, '4': 1, '5': 5, '10': 'key'},
    {'1': 'value', '3': 2, '4': 1, '5': 5, '10': 'value'},
  ],
  '7': {'7': true},
};

@$core.Deprecated('Use loadBalancerAccumulatedStatsResponseDescriptor instead')
const LoadBalancerAccumulatedStatsResponse_StatsPerMethodEntry$json = {
  '1': 'StatsPerMethodEntry',
  '2': [
    {'1': 'key', '3': 1, '4': 1, '5': 9, '10': 'key'},
    {'1': 'value', '3': 2, '4': 1, '5': 11, '6': '.grpc.testing.LoadBalancerAccumulatedStatsResponse.MethodStats', '10': 'value'},
  ],
  '7': {'7': true},
};

/// Descriptor for `LoadBalancerAccumulatedStatsResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List loadBalancerAccumulatedStatsResponseDescriptor = $convert.base64Decode(
    'CiRMb2FkQmFsYW5jZXJBY2N1bXVsYXRlZFN0YXRzUmVzcG9uc2USjgEKGm51bV9ycGNzX3N0YX'
    'J0ZWRfYnlfbWV0aG9kGAEgAygLMk4uZ3JwYy50ZXN0aW5nLkxvYWRCYWxhbmNlckFjY3VtdWxh'
    'dGVkU3RhdHNSZXNwb25zZS5OdW1ScGNzU3RhcnRlZEJ5TWV0aG9kRW50cnlCAhgBUhZudW1ScG'
    'NzU3RhcnRlZEJ5TWV0aG9kEpQBChxudW1fcnBjc19zdWNjZWVkZWRfYnlfbWV0aG9kGAIgAygL'
    'MlAuZ3JwYy50ZXN0aW5nLkxvYWRCYWxhbmNlckFjY3VtdWxhdGVkU3RhdHNSZXNwb25zZS5OdW'
    '1ScGNzU3VjY2VlZGVkQnlNZXRob2RFbnRyeUICGAFSGG51bVJwY3NTdWNjZWVkZWRCeU1ldGhv'
    'ZBKLAQoZbnVtX3JwY3NfZmFpbGVkX2J5X21ldGhvZBgDIAMoCzJNLmdycGMudGVzdGluZy5Mb2'
    'FkQmFsYW5jZXJBY2N1bXVsYXRlZFN0YXRzUmVzcG9uc2UuTnVtUnBjc0ZhaWxlZEJ5TWV0aG9k'
    'RW50cnlCAhgBUhVudW1ScGNzRmFpbGVkQnlNZXRob2QScAoQc3RhdHNfcGVyX21ldGhvZBgEIA'
    'MoCzJGLmdycGMudGVzdGluZy5Mb2FkQmFsYW5jZXJBY2N1bXVsYXRlZFN0YXRzUmVzcG9uc2Uu'
    'U3RhdHNQZXJNZXRob2RFbnRyeVIOc3RhdHNQZXJNZXRob2QaSQobTnVtUnBjc1N0YXJ0ZWRCeU'
    '1ldGhvZEVudHJ5EhAKA2tleRgBIAEoCVIDa2V5EhQKBXZhbHVlGAIgASgFUgV2YWx1ZToCOAEa'
    'SwodTnVtUnBjc1N1Y2NlZWRlZEJ5TWV0aG9kRW50cnkSEAoDa2V5GAEgASgJUgNrZXkSFAoFdm'
    'FsdWUYAiABKAVSBXZhbHVlOgI4ARpIChpOdW1ScGNzRmFpbGVkQnlNZXRob2RFbnRyeRIQCgNr'
    'ZXkYASABKAlSA2tleRIUCgV2YWx1ZRgCIAEoBVIFdmFsdWU6AjgBGs8BCgtNZXRob2RTdGF0cx'
    'IhCgxycGNzX3N0YXJ0ZWQYASABKAVSC3JwY3NTdGFydGVkEmIKBnJlc3VsdBgCIAMoCzJKLmdy'
    'cGMudGVzdGluZy5Mb2FkQmFsYW5jZXJBY2N1bXVsYXRlZFN0YXRzUmVzcG9uc2UuTWV0aG9kU3'
    'RhdHMuUmVzdWx0RW50cnlSBnJlc3VsdBo5CgtSZXN1bHRFbnRyeRIQCgNrZXkYASABKAVSA2tl'
    'eRIUCgV2YWx1ZRgCIAEoBVIFdmFsdWU6AjgBGoEBChNTdGF0c1Blck1ldGhvZEVudHJ5EhAKA2'
    'tleRgBIAEoCVIDa2V5ElQKBXZhbHVlGAIgASgLMj4uZ3JwYy50ZXN0aW5nLkxvYWRCYWxhbmNl'
    'ckFjY3VtdWxhdGVkU3RhdHNSZXNwb25zZS5NZXRob2RTdGF0c1IFdmFsdWU6AjgB');

@$core.Deprecated('Use clientConfigureRequestDescriptor instead')
const ClientConfigureRequest$json = {
  '1': 'ClientConfigureRequest',
  '2': [
    {'1': 'types', '3': 1, '4': 3, '5': 14, '6': '.grpc.testing.ClientConfigureRequest.RpcType', '10': 'types'},
    {'1': 'metadata', '3': 2, '4': 3, '5': 11, '6': '.grpc.testing.ClientConfigureRequest.Metadata', '10': 'metadata'},
    {'1': 'timeout_sec', '3': 3, '4': 1, '5': 5, '10': 'timeoutSec'},
  ],
  '3': [ClientConfigureRequest_Metadata$json],
  '4': [ClientConfigureRequest_RpcType$json],
};

@$core.Deprecated('Use clientConfigureRequestDescriptor instead')
const ClientConfigureRequest_Metadata$json = {
  '1': 'Metadata',
  '2': [
    {'1': 'type', '3': 1, '4': 1, '5': 14, '6': '.grpc.testing.ClientConfigureRequest.RpcType', '10': 'type'},
    {'1': 'key', '3': 2, '4': 1, '5': 9, '10': 'key'},
    {'1': 'value', '3': 3, '4': 1, '5': 9, '10': 'value'},
  ],
};

@$core.Deprecated('Use clientConfigureRequestDescriptor instead')
const ClientConfigureRequest_RpcType$json = {
  '1': 'RpcType',
  '2': [
    {'1': 'EMPTY_CALL', '2': 0},
    {'1': 'UNARY_CALL', '2': 1},
  ],
};

/// Descriptor for `ClientConfigureRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List clientConfigureRequestDescriptor = $convert.base64Decode(
    'ChZDbGllbnRDb25maWd1cmVSZXF1ZXN0EkIKBXR5cGVzGAEgAygOMiwuZ3JwYy50ZXN0aW5nLk'
    'NsaWVudENvbmZpZ3VyZVJlcXVlc3QuUnBjVHlwZVIFdHlwZXMSSQoIbWV0YWRhdGEYAiADKAsy'
    'LS5ncnBjLnRlc3RpbmcuQ2xpZW50Q29uZmlndXJlUmVxdWVzdC5NZXRhZGF0YVIIbWV0YWRhdG'
    'ESHwoLdGltZW91dF9zZWMYAyABKAVSCnRpbWVvdXRTZWMadAoITWV0YWRhdGESQAoEdHlwZRgB'
    'IAEoDjIsLmdycGMudGVzdGluZy5DbGllbnRDb25maWd1cmVSZXF1ZXN0LlJwY1R5cGVSBHR5cG'
    'USEAoDa2V5GAIgASgJUgNrZXkSFAoFdmFsdWUYAyABKAlSBXZhbHVlIikKB1JwY1R5cGUSDgoK'
    'RU1QVFlfQ0FMTBAAEg4KClVOQVJZX0NBTEwQAQ==');

@$core.Deprecated('Use clientConfigureResponseDescriptor instead')
const ClientConfigureResponse$json = {
  '1': 'ClientConfigureResponse',
};

/// Descriptor for `ClientConfigureResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List clientConfigureResponseDescriptor = $convert.base64Decode(
    'ChdDbGllbnRDb25maWd1cmVSZXNwb25zZQ==');

@$core.Deprecated('Use testOrcaReportDescriptor instead')
const TestOrcaReport$json = {
  '1': 'TestOrcaReport',
  '2': [
    {'1': 'cpu_utilization', '3': 1, '4': 1, '5': 1, '10': 'cpuUtilization'},
    {'1': 'memory_utilization', '3': 2, '4': 1, '5': 1, '10': 'memoryUtilization'},
    {'1': 'request_cost', '3': 3, '4': 3, '5': 11, '6': '.grpc.testing.TestOrcaReport.RequestCostEntry', '10': 'requestCost'},
    {'1': 'utilization', '3': 4, '4': 3, '5': 11, '6': '.grpc.testing.TestOrcaReport.UtilizationEntry', '10': 'utilization'},
  ],
  '3': [TestOrcaReport_RequestCostEntry$json, TestOrcaReport_UtilizationEntry$json],
};

@$core.Deprecated('Use testOrcaReportDescriptor instead')
const TestOrcaReport_RequestCostEntry$json = {
  '1': 'RequestCostEntry',
  '2': [
    {'1': 'key', '3': 1, '4': 1, '5': 9, '10': 'key'},
    {'1': 'value', '3': 2, '4': 1, '5': 1, '10': 'value'},
  ],
  '7': {'7': true},
};

@$core.Deprecated('Use testOrcaReportDescriptor instead')
const TestOrcaReport_UtilizationEntry$json = {
  '1': 'UtilizationEntry',
  '2': [
    {'1': 'key', '3': 1, '4': 1, '5': 9, '10': 'key'},
    {'1': 'value', '3': 2, '4': 1, '5': 1, '10': 'value'},
  ],
  '7': {'7': true},
};

/// Descriptor for `TestOrcaReport`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List testOrcaReportDescriptor = $convert.base64Decode(
    'Cg5UZXN0T3JjYVJlcG9ydBInCg9jcHVfdXRpbGl6YXRpb24YASABKAFSDmNwdVV0aWxpemF0aW'
    '9uEi0KEm1lbW9yeV91dGlsaXphdGlvbhgCIAEoAVIRbWVtb3J5VXRpbGl6YXRpb24SUAoMcmVx'
    'dWVzdF9jb3N0GAMgAygLMi0uZ3JwYy50ZXN0aW5nLlRlc3RPcmNhUmVwb3J0LlJlcXVlc3RDb3'
    'N0RW50cnlSC3JlcXVlc3RDb3N0Ek8KC3V0aWxpemF0aW9uGAQgAygLMi0uZ3JwYy50ZXN0aW5n'
    'LlRlc3RPcmNhUmVwb3J0LlV0aWxpemF0aW9uRW50cnlSC3V0aWxpemF0aW9uGj4KEFJlcXVlc3'
    'RDb3N0RW50cnkSEAoDa2V5GAEgASgJUgNrZXkSFAoFdmFsdWUYAiABKAFSBXZhbHVlOgI4ARo+'
    'ChBVdGlsaXphdGlvbkVudHJ5EhAKA2tleRgBIAEoCVIDa2V5EhQKBXZhbHVlGAIgASgBUgV2YW'
    'x1ZToCOAE=');

