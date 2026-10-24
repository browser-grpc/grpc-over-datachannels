# C++ — grpc-dc runtime

Generated, dependency-free gRPC-over-DataChannels runtime
with Echo stubs, examples, and tests in this directory.

## First run (Docker, no toolchain install)

    docker build -f docker/cpp.Dockerfile -t grpc-dc-cpp .
    docker run --rm grpc-dc-cpp

## Regenerate stubs for your schema

    protoc --plugin=protoc-gen-grpc-dc-cpp=$PWD/bin/protoc-gen-grpc-dc-cpp \
           --grpc-dc-cpp_out=out -I . your.proto

Full project quickstart: [`../QUICKSTART.md`](../QUICKSTART.md).
