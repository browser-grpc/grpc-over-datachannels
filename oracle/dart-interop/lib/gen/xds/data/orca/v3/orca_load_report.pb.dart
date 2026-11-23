//
//  Generated code. Do not modify.
//  source: xds/data/orca/v3/orca_load_report.proto
//
// @dart = 2.12

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_final_fields
// ignore_for_file: unnecessary_import, unnecessary_this, unused_import

import 'dart:core' as $core;

import 'package:protobuf/protobuf.dart' as $pb;

class OrcaLoadReport extends $pb.GeneratedMessage {
  factory OrcaLoadReport({
    $core.double? cpuUtilization,
    $core.double? memUtilization,
    $core.double? rpsFractional,
    $core.Map<$core.String, $core.double>? requestCost,
    $core.Map<$core.String, $core.double>? utilization,
  }) {
    final $result = create();
    if (cpuUtilization != null) {
      $result.cpuUtilization = cpuUtilization;
    }
    if (memUtilization != null) {
      $result.memUtilization = memUtilization;
    }
    if (rpsFractional != null) {
      $result.rpsFractional = rpsFractional;
    }
    if (requestCost != null) {
      $result.requestCost.addAll(requestCost);
    }
    if (utilization != null) {
      $result.utilization.addAll(utilization);
    }
    return $result;
  }
  OrcaLoadReport._() : super();
  factory OrcaLoadReport.fromBuffer($core.List<$core.int> i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromBuffer(i, r);
  factory OrcaLoadReport.fromJson($core.String i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'OrcaLoadReport', package: const $pb.PackageName(_omitMessageNames ? '' : 'xds.data.orca.v3'), createEmptyInstance: create)
    ..a<$core.double>(1, _omitFieldNames ? '' : 'cpuUtilization', $pb.PbFieldType.OD)
    ..a<$core.double>(2, _omitFieldNames ? '' : 'memUtilization', $pb.PbFieldType.OD)
    ..a<$core.double>(3, _omitFieldNames ? '' : 'rpsFractional', $pb.PbFieldType.OD)
    ..m<$core.String, $core.double>(4, _omitFieldNames ? '' : 'requestCost', entryClassName: 'OrcaLoadReport.RequestCostEntry', keyFieldType: $pb.PbFieldType.OS, valueFieldType: $pb.PbFieldType.OD, packageName: const $pb.PackageName('xds.data.orca.v3'))
    ..m<$core.String, $core.double>(5, _omitFieldNames ? '' : 'utilization', entryClassName: 'OrcaLoadReport.UtilizationEntry', keyFieldType: $pb.PbFieldType.OS, valueFieldType: $pb.PbFieldType.OD, packageName: const $pb.PackageName('xds.data.orca.v3'))
    ..hasRequiredFields = false
  ;

  @$core.Deprecated(
  'Using this can add significant overhead to your binary. '
  'Use [GeneratedMessageGenericExtensions.deepCopy] instead. '
  'Will be removed in next major version')
  OrcaLoadReport clone() => OrcaLoadReport()..mergeFromMessage(this);
  @$core.Deprecated(
  'Using this can add significant overhead to your binary. '
  'Use [GeneratedMessageGenericExtensions.rebuild] instead. '
  'Will be removed in next major version')
  OrcaLoadReport copyWith(void Function(OrcaLoadReport) updates) => super.copyWith((message) => updates(message as OrcaLoadReport)) as OrcaLoadReport;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static OrcaLoadReport create() => OrcaLoadReport._();
  OrcaLoadReport createEmptyInstance() => create();
  static $pb.PbList<OrcaLoadReport> createRepeated() => $pb.PbList<OrcaLoadReport>();
  @$core.pragma('dart2js:noInline')
  static OrcaLoadReport getDefault() => _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<OrcaLoadReport>(create);
  static OrcaLoadReport? _defaultInstance;

  @$pb.TagNumber(1)
  $core.double get cpuUtilization => $_getN(0);
  @$pb.TagNumber(1)
  set cpuUtilization($core.double v) { $_setDouble(0, v); }
  @$pb.TagNumber(1)
  $core.bool hasCpuUtilization() => $_has(0);
  @$pb.TagNumber(1)
  void clearCpuUtilization() => clearField(1);

  @$pb.TagNumber(2)
  $core.double get memUtilization => $_getN(1);
  @$pb.TagNumber(2)
  set memUtilization($core.double v) { $_setDouble(1, v); }
  @$pb.TagNumber(2)
  $core.bool hasMemUtilization() => $_has(1);
  @$pb.TagNumber(2)
  void clearMemUtilization() => clearField(2);

  @$pb.TagNumber(3)
  $core.double get rpsFractional => $_getN(2);
  @$pb.TagNumber(3)
  set rpsFractional($core.double v) { $_setDouble(2, v); }
  @$pb.TagNumber(3)
  $core.bool hasRpsFractional() => $_has(2);
  @$pb.TagNumber(3)
  void clearRpsFractional() => clearField(3);

  @$pb.TagNumber(4)
  $core.Map<$core.String, $core.double> get requestCost => $_getMap(3);

  @$pb.TagNumber(5)
  $core.Map<$core.String, $core.double> get utilization => $_getMap(4);
}


const _omitFieldNames = $core.bool.fromEnvironment('protobuf.omit_field_names');
const _omitMessageNames = $core.bool.fromEnvironment('protobuf.omit_message_names');
