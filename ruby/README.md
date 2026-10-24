# Ruby — grpc-dc runtime

Generated, dependency-free gRPC-over-DataChannels runtime
with Echo stubs, examples, and tests in this directory.

## First run (Docker, no toolchain install)

    docker build -f docker/ruby.Dockerfile -t grpc-dc-ruby .
    docker run --rm grpc-dc-ruby

## Regenerate stubs for your schema

    protoc --plugin=protoc-gen-grpc-dc-ruby=$PWD/bin/protoc-gen-grpc-dc-ruby \
           --grpc-dc-ruby_out=out -I . your.proto

Full project quickstart: [`../QUICKSTART.md`](../QUICKSTART.md).
