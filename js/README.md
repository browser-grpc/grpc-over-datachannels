# JavaScript (browser + Node) — grpc-dc runtime

Start here if you are new to the project. The runtime in
this directory is generated, dependency-free, and speaks
the gRPC wire protocol over WebRTC DataChannels.

## First run

```sh
    node js/examples/echo_demo.js   # all four method shapes, in-memory pair
    node --test js/test/*.test.js   # full suite
```

## Use it in your project

npm install grpc-dc — or copy this directory; there are no dependencies. TypeScript types ship in `index.d.ts`.

## Regenerate stubs for your schema

From the repository root (one wrapper per language in `bin/`):

    protoc --plugin=protoc-gen-grpc-dc-js=$PWD/bin/protoc-gen-grpc-dc-js \
           --grpc-dc-js_out=out -I . your.proto

Or generate in the browser and download the zip:
https://browser-grpc.github.io/grpc-over-datachannels/app/

## Where things live

- Runtime: this directory (see its generated sources).
- Worked example: `examples/` (Echo in every method shape).
- Tests: `tests/` — the same BDD scenarios every language runs.

Full project quickstart: [`../QUICKSTART.md`](../QUICKSTART.md).
