# PHP — grpc-dc runtime

Generated, dependency-free gRPC-over-DataChannels runtime
with Echo stubs, examples, and tests in this directory.

## First run (Docker, no toolchain install)

    docker build -f docker/php.Dockerfile -t grpc-dc-php .
    docker run --rm grpc-dc-php

## Regenerate stubs for your schema

    protoc --plugin=protoc-gen-grpc-dc-php=$PWD/bin/protoc-gen-grpc-dc-php \
           --grpc-dc-php_out=out -I . your.proto

Full project quickstart: [`../QUICKSTART.md`](../QUICKSTART.md).
