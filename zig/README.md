# Zig — grpc-dc runtime

Generated, dependency-free gRPC-over-DataChannels runtime
with Echo stubs, examples, and tests in this directory.

## First run (Docker, no toolchain install)

    docker build -f docker/zig.Dockerfile -t grpc-dc-zig .
    docker run --rm grpc-dc-zig

## Regenerate stubs for your schema

    protoc --plugin=protoc-gen-grpc-dc-zig=$PWD/bin/protoc-gen-grpc-dc-zig \
           --grpc-dc-zig_out=out -I . your.proto

Full project quickstart: [`../QUICKSTART.md`](../QUICKSTART.md).
