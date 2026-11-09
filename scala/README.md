# Scala — grpc-dc runtime

Generated, dependency-free gRPC-over-DataChannels runtime
with Echo stubs, examples, and tests in this directory.

## First run (Docker, no toolchain install)

    docker build -f docker/scala.Dockerfile -t grpc-dc-scala .
    docker run --rm grpc-dc-scala

## Regenerate stubs for your schema

    protoc --plugin=protoc-gen-grpc-dc-scala=$PWD/bin/protoc-gen-grpc-dc-scala \
           --grpc-dc-scala_out=out -I . your.proto

Test and example index: [`TESTS.md`](TESTS.md).

Full project quickstart: [`../QUICKSTART.md`](../QUICKSTART.md).
