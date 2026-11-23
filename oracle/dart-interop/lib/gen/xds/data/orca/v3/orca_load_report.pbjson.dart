//
//  Generated code. Do not modify.
//  source: xds/data/orca/v3/orca_load_report.proto
//
// @dart = 2.12

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_final_fields
// ignore_for_file: unnecessary_import, unnecessary_this, unused_import

import 'dart:convert' as $convert;
import 'dart:core' as $core;
import 'dart:typed_data' as $typed_data;

@$core.Deprecated('Use orcaLoadReportDescriptor instead')
const OrcaLoadReport$json = {
  '1': 'OrcaLoadReport',
  '2': [
    {'1': 'cpu_utilization', '3': 1, '4': 1, '5': 1, '10': 'cpuUtilization'},
    {'1': 'mem_utilization', '3': 2, '4': 1, '5': 1, '10': 'memUtilization'},
    {'1': 'rps_fractional', '3': 3, '4': 1, '5': 1, '10': 'rpsFractional'},
    {'1': 'request_cost', '3': 4, '4': 3, '5': 11, '6': '.xds.data.orca.v3.OrcaLoadReport.RequestCostEntry', '10': 'requestCost'},
    {'1': 'utilization', '3': 5, '4': 3, '5': 11, '6': '.xds.data.orca.v3.OrcaLoadReport.UtilizationEntry', '10': 'utilization'},
  ],
  '3': [OrcaLoadReport_RequestCostEntry$json, OrcaLoadReport_UtilizationEntry$json],
};

@$core.Deprecated('Use orcaLoadReportDescriptor instead')
const OrcaLoadReport_RequestCostEntry$json = {
  '1': 'RequestCostEntry',
  '2': [
    {'1': 'key', '3': 1, '4': 1, '5': 9, '10': 'key'},
    {'1': 'value', '3': 2, '4': 1, '5': 1, '10': 'value'},
  ],
  '7': {'7': true},
};

@$core.Deprecated('Use orcaLoadReportDescriptor instead')
const OrcaLoadReport_UtilizationEntry$json = {
  '1': 'UtilizationEntry',
  '2': [
    {'1': 'key', '3': 1, '4': 1, '5': 9, '10': 'key'},
    {'1': 'value', '3': 2, '4': 1, '5': 1, '10': 'value'},
  ],
  '7': {'7': true},
};

/// Descriptor for `OrcaLoadReport`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List orcaLoadReportDescriptor = $convert.base64Decode(
    'Cg5PcmNhTG9hZFJlcG9ydBInCg9jcHVfdXRpbGl6YXRpb24YASABKAFSDmNwdVV0aWxpemF0aW'
    '9uEicKD21lbV91dGlsaXphdGlvbhgCIAEoAVIObWVtVXRpbGl6YXRpb24SJQoOcnBzX2ZyYWN0'
    'aW9uYWwYAyABKAFSDXJwc0ZyYWN0aW9uYWwSVAoMcmVxdWVzdF9jb3N0GAQgAygLMjEueGRzLm'
    'RhdGEub3JjYS52My5PcmNhTG9hZFJlcG9ydC5SZXF1ZXN0Q29zdEVudHJ5UgtyZXF1ZXN0Q29z'
    'dBJTCgt1dGlsaXphdGlvbhgFIAMoCzIxLnhkcy5kYXRhLm9yY2EudjMuT3JjYUxvYWRSZXBvcn'
    'QuVXRpbGl6YXRpb25FbnRyeVILdXRpbGl6YXRpb24aPgoQUmVxdWVzdENvc3RFbnRyeRIQCgNr'
    'ZXkYASABKAlSA2tleRIUCgV2YWx1ZRgCIAEoAVIFdmFsdWU6AjgBGj4KEFV0aWxpemF0aW9uRW'
    '50cnkSEAoDa2V5GAEgASgJUgNrZXkSFAoFdmFsdWUYAiABKAFSBXZhbHVlOgI4AQ==');

