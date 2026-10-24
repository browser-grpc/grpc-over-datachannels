# Kotlin — grpc-dc runtime

Generated, dependency-free gRPC-over-DataChannels runtime
with Echo stubs, examples, and tests in this directory.

## First run (Docker, no toolchain install)

    docker build -f docker/kotlin.Dockerfile -t grpc-dc-kotlin .
    docker run --rm grpc-dc-kotlin

## Regenerate stubs for your schema

    protoc --plugin=protoc-gen-grpc-dc-kotlin=$PWD/bin/protoc-gen-grpc-dc-kotlin \
           --grpc-dc-kotlin_out=out -I . your.proto

Full project quickstart: [`../QUICKSTART.md`](../QUICKSTART.md).
