# C# — grpc-dc runtime

Generated, dependency-free gRPC-over-DataChannels runtime
with Echo stubs, examples, and tests in this directory.

## First run (Docker, no toolchain install)

    docker build -f docker/csharp.Dockerfile -t grpc-dc-csharp .
    docker run --rm grpc-dc-csharp

## Regenerate stubs for your schema

    protoc --plugin=protoc-gen-grpc-dc-csharp=$PWD/bin/protoc-gen-grpc-dc-csharp \
           --grpc-dc-csharp_out=out -I . your.proto

Full project quickstart: [`../QUICKSTART.md`](../QUICKSTART.md).
