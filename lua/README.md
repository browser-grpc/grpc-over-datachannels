# Lua — grpc-dc runtime

Generated, dependency-free gRPC-over-DataChannels runtime
with Echo stubs, examples, and tests in this directory.

## First run (Docker, no toolchain install)

    docker build -f docker/lua.Dockerfile -t grpc-dc-lua .
    docker run --rm grpc-dc-lua

## Regenerate stubs for your schema

    protoc --plugin=protoc-gen-grpc-dc-lua=$PWD/bin/protoc-gen-grpc-dc-lua \
           --grpc-dc-lua_out=out -I . your.proto

Full project quickstart: [`../QUICKSTART.md`](../QUICKSTART.md).
