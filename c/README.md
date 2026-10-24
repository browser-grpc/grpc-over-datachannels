# C — grpc-dc runtime

Generated, dependency-free gRPC-over-DataChannels runtime
with Echo stubs, examples, and tests in this directory.

## First run (Docker, no toolchain install)

    docker build -f docker/c.Dockerfile -t grpc-dc-c .
    docker run --rm grpc-dc-c

## Regenerate stubs for your schema

    protoc --plugin=protoc-gen-grpc-dc-c=$PWD/bin/protoc-gen-grpc-dc-c \
           --grpc-dc-c_out=out -I . your.proto

Full project quickstart: [`../QUICKSTART.md`](../QUICKSTART.md).
