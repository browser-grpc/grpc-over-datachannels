# Zig — grpc-dc runtime

Start here if you are new to the project. The runtime in
this directory is generated, dependency-free, and speaks
the gRPC wire protocol over WebRTC DataChannels.

## First run

```sh
    cd zig && zig build tests
```

## Use it in your project

Zig package manager: `zig fetch --save git+https://github.com/browser-grpc/grpc-over-datachannels.git#v0.41.0` — the repository root is a Zig package (build.zig.zon) exposing modules `grpcdc` (the runtime) and `kafka_grpc` (the grpcdc.kafka.v1 stubs). Depend on it with `b.dependency("grpc_dc", .{})` and `dep.module("grpcdc")` / `dep.module("kafka_grpc")`. Or copy this directory; there are no dependencies.

## Regenerate stubs for your schema

From the repository root (one wrapper per language in `bin/`):

    protoc --plugin=protoc-gen-grpc-dc-zig=$PWD/bin/protoc-gen-grpc-dc-zig \
           --grpc-dc-zig_out=out -I . your.proto

Or generate in the browser and download the zip:
https://browser-grpc.github.io/grpc-over-datachannels/app/

## Where things live

- Runtime: this directory (see its generated sources).
- Worked example: `examples/` (Echo in every method shape).
- Tests: `tests/` — the same BDD scenarios every language runs.
- Test and example index: [`TESTS.md`](TESTS.md) — every suite and example here, plus shared matrix coverage.

Full project quickstart: [`../QUICKSTART.md`](../QUICKSTART.md).
