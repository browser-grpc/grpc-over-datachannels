# Go — grpc-dc runtime

Start here if you are new to the project. The runtime in
this directory is generated, dependency-free, and speaks
the gRPC wire protocol over WebRTC DataChannels.

## First run

```sh
    cd go && go test ./...
```

## Use it in your project

Fetch it like any module: `go get github.com/browser-grpc/grpc-over-datachannels/go` (the WebRTC stack arrives as its sibling module `.../webrtc/go`) — or copy this directory into your module tree.

## Regenerate stubs for your schema

From the repository root (one wrapper per language in `bin/`):

    protoc --plugin=protoc-gen-grpc-dc-go=$PWD/bin/protoc-gen-grpc-dc-go \
           --grpc-dc-go_out=out -I . your.proto

Or generate in the browser and download the zip:
https://browser-grpc.github.io/grpc-over-datachannels/app/

## Where things live

- Runtime: this directory (see its generated sources).
- Worked example: `examples/` (Echo in every method shape).
- Tests: `tests/` — the same BDD scenarios every language runs.

Full project quickstart: [`../QUICKSTART.md`](../QUICKSTART.md).
