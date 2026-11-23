#!/bin/sh
# Regenerate the Dart stubs for the canonical interop protos
# (oracle/interop) with the Dart protoc plugin. Requires protoc
# and the protoc_plugin pub package on PATH:
#   dart pub global activate protoc_plugin 21.1.2
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export PATH="$PATH:$HOME/.pub-cache/bin"
protoc --plugin=protoc-gen-dart="$HOME/.pub-cache/bin/protoc-gen-dart" \
  --dart_out="grpc:$ROOT/oracle/dart-interop/lib/gen" \
  -I "$ROOT/oracle/interop" \
  grpc/testing/test.proto grpc/testing/messages.proto grpc/testing/empty.proto \
  xds/data/orca/v3/orca_load_report.proto xds/service/orca/v3/orca.proto
