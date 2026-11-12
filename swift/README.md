# Swift — grpc-dc runtime

Start here if you are new to the project. The runtime in
this directory is generated, dependency-free, and speaks
the gRPC wire protocol over WebRTC DataChannels.

## First run

```sh
    cd swift && mkdir -p build && swiftc -swift-version 5 -O grpcdc/*.swift examples/Pb.swift examples/EchoMessages.swift examples/EchoGrpcDc.swift examples/EchoServiceImpl.swift examples/StdioTransport.swift examples/DynamicEchoService.swift examples/interop/*.swift $(ls tests/*.swift | grep -v TestKafkaNative.swift) -o build/tests && ./build/tests TestEcho
```

## Use it in your project

SwiftPM: this repository is a Swift package (Package.swift at the root, listed on the Swift Package Index). Add it as a package dependency on https://github.com/browser-grpc/grpc-over-datachannels (use the newest release tag) and depend on the `GrpcDc` library product (module `Grpcdc`). Or compile the sources in `swift/grpcdc/` directly into your target — no dependencies either way. The `grpcdc.kafka.v1` stubs (KafkaMessages/KafkaGrpcDc) are part of the same module.

## Regenerate stubs for your schema

From the repository root (one wrapper per language in `bin/`):

    protoc --plugin=protoc-gen-grpc-dc-swift=$PWD/bin/protoc-gen-grpc-dc-swift \
           --grpc-dc-swift_out=out -I . your.proto

Or generate in the browser and download the zip:
https://browser-grpc.github.io/grpc-over-datachannels/app/

## Where things live

- Runtime: this directory (see its generated sources).
- Worked example: `examples/` (Echo in every method shape).
- Tests: `tests/` — the same BDD scenarios every language runs.
- Test and example index: [`TESTS.md`](TESTS.md) — every suite and example here, plus shared matrix coverage.

Full project quickstart: [`../QUICKSTART.md`](../QUICKSTART.md).
