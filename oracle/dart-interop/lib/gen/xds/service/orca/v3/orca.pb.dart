//
//  Generated code. Do not modify.
//  source: xds/service/orca/v3/orca.proto
//
// @dart = 2.12

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_final_fields
// ignore_for_file: unnecessary_import, unnecessary_this, unused_import

import 'dart:core' as $core;

import 'package:protobuf/protobuf.dart' as $pb;

class OrcaLoadReportRequest extends $pb.GeneratedMessage {
  factory OrcaLoadReportRequest() => create();
  OrcaLoadReportRequest._() : super();
  factory OrcaLoadReportRequest.fromBuffer($core.List<$core.int> i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromBuffer(i, r);
  factory OrcaLoadReportRequest.fromJson($core.String i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'OrcaLoadReportRequest', package: const $pb.PackageName(_omitMessageNames ? '' : 'xds.service.orca.v3'), createEmptyInstance: create)
    ..hasRequiredFields = false
  ;

  @$core.Deprecated(
  'Using this can add significant overhead to your binary. '
  'Use [GeneratedMessageGenericExtensions.deepCopy] instead. '
  'Will be removed in next major version')
  OrcaLoadReportRequest clone() => OrcaLoadReportRequest()..mergeFromMessage(this);
  @$core.Deprecated(
  'Using this can add significant overhead to your binary. '
  'Use [GeneratedMessageGenericExtensions.rebuild] instead. '
  'Will be removed in next major version')
  OrcaLoadReportRequest copyWith(void Function(OrcaLoadReportRequest) updates) => super.copyWith((message) => updates(message as OrcaLoadReportRequest)) as OrcaLoadReportRequest;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static OrcaLoadReportRequest create() => OrcaLoadReportRequest._();
  OrcaLoadReportRequest createEmptyInstance() => create();
  static $pb.PbList<OrcaLoadReportRequest> createRepeated() => $pb.PbList<OrcaLoadReportRequest>();
  @$core.pragma('dart2js:noInline')
  static OrcaLoadReportRequest getDefault() => _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<OrcaLoadReportRequest>(create);
  static OrcaLoadReportRequest? _defaultInstance;
}


const _omitMessageNames = $core.bool.fromEnvironment('protobuf.omit_message_names');
