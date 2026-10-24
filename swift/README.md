# Swift — grpc-dc runtime

Generated, dependency-free gRPC-over-DataChannels runtime
with Echo stubs, examples, and tests in this directory.

## First run (Docker, no toolchain install)

    docker build -f docker/swift.Dockerfile -t grpc-dc-swift .
    docker run --rm grpc-dc-swift

## Regenerate stubs for your schema

    protoc --plugin=protoc-gen-grpc-dc-swift=$PWD/bin/protoc-gen-grpc-dc-swift \
           --grpc-dc-swift_out=out -I . your.proto

Full project quickstart: [`../QUICKSTART.md`](../QUICKSTART.md).
