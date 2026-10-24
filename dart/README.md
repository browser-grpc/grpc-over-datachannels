# Dart — grpc-dc runtime

Generated, dependency-free gRPC-over-DataChannels runtime
with Echo stubs, examples, and tests in this directory.

## First run (Docker, no toolchain install)

    docker build -f docker/dart.Dockerfile -t grpc-dc-dart .
    docker run --rm grpc-dc-dart

## Regenerate stubs for your schema

    protoc --plugin=protoc-gen-grpc-dc-dart=$PWD/bin/protoc-gen-grpc-dc-dart \
           --grpc-dc-dart_out=out -I . your.proto

Full project quickstart: [`../QUICKSTART.md`](../QUICKSTART.md).
