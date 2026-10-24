# Java — grpc-dc runtime

Generated, dependency-free gRPC-over-DataChannels runtime
with Echo stubs, examples, and tests in this directory.

## First run (Docker, no toolchain install)

    docker build -f docker/java.Dockerfile -t grpc-dc-java .
    docker run --rm grpc-dc-java

## Regenerate stubs for your schema

    protoc --plugin=protoc-gen-grpc-dc-java=$PWD/bin/protoc-gen-grpc-dc-java \
           --grpc-dc-java_out=out -I . your.proto

Full project quickstart: [`../QUICKSTART.md`](../QUICKSTART.md).
