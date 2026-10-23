# grpc-over-datachannels

gRPC over WebRTC DataChannels for many languages: dependency-free
generated runtimes and Echo stubs, a reimplemented WebRTC stack,
and native + browser (Wasm) clients and servers.

This repository is a generated public export (version v0.25.2)
of the grpc-over-datachannels project. Generated code may be used
without restriction (see GENERATED-CODE-LICENSE.md); everything
else is Apache-2.0 (see LICENSE).

## Languages

| Language | Runtime + stubs |
|---|---|
| C | [`c/`](c/) |
| C++ | [`cpp/`](cpp/) |
| C# | [`csharp/`](csharp/) |
| Dart | [`dart/`](dart/) |
| Go | [`go/`](go/) |
| Java | [`java/`](java/) |
| JavaScript | [`js/`](js/) |
| Kotlin | [`kotlin/`](kotlin/) |
| Lua | [`lua/`](lua/) |
| PHP | [`php/`](php/) |
| Python | [`python/`](python/) |
| Ruby | [`ruby/`](ruby/) |
| Rust | [`rust/`](rust/) |
| Scala | [`scala/`](scala/) |
| Swift | [`swift/`](swift/) |
| Zig | [`zig/`](zig/) |
| WebRTC stack | [`webrtc/`](webrtc/) |
| Wasm facades + native Wasm | [`wasm/`](wasm/) |

## Getting started (Docker, no toolchain install)

Every language's test suite in one command pair:

    docker build -f docker/rust.Dockerfile -t grpc-dc-rust .
    docker run --rm grpc-dc-rust
    docker build -f docker/go.Dockerfile -t grpc-dc-go .
    docker run --rm grpc-dc-go
    docker build -f docker/js.Dockerfile -t grpc-dc-js .
    docker run --rm grpc-dc-js
    docker build -f docker/python.Dockerfile -t grpc-dc-python .
    docker run --rm grpc-dc-python
    docker build -f docker/java.Dockerfile -t grpc-dc-java .
    docker run --rm grpc-dc-java
    docker build -f docker/csharp.Dockerfile -t grpc-dc-csharp .
    docker run --rm grpc-dc-csharp
    docker build -f docker/cpp.Dockerfile -t grpc-dc-cpp .
    docker run --rm grpc-dc-cpp
    docker build -f docker/swift.Dockerfile -t grpc-dc-swift .
    docker run --rm grpc-dc-swift
    docker build -f docker/kotlin.Dockerfile -t grpc-dc-kotlin .
    docker run --rm grpc-dc-kotlin
    docker build -f docker/dart.Dockerfile -t grpc-dc-dart .
    docker run --rm grpc-dc-dart
    docker build -f docker/zig.Dockerfile -t grpc-dc-zig .
    docker run --rm grpc-dc-zig
    docker build -f docker/c.Dockerfile -t grpc-dc-c .
    docker run --rm grpc-dc-c
    docker build -f docker/lua.Dockerfile -t grpc-dc-lua .
    docker run --rm grpc-dc-lua
    docker build -f docker/ruby.Dockerfile -t grpc-dc-ruby .
    docker run --rm grpc-dc-ruby
    docker build -f docker/php.Dockerfile -t grpc-dc-php .
    docker run --rm grpc-dc-php
    docker build -f docker/scala.Dockerfile -t grpc-dc-scala .
    docker run --rm grpc-dc-scala

Or `docker compose up` for the cross-language interop proof
plus the browser demo on http://localhost:8080 (generator with
a schema preloaded: http://localhost:8080/app/#schema=echo&lang=go).

## Try it in the browser

The [live demo](https://browser-grpc.github.io/grpc-over-datachannels/)
generates stubs for every language in your browser (protoc schema
in, generated code out) and runs the BDD example suite.

## Generate with protoc (Node)

The same generators ship as a dependency-free Node protoc
plugin, `docs/app/protoc-gen-grpc-dc.mjs`. Link it under one
name per language and generate natively:

    ln -s "$PWD/docs/app/protoc-gen-grpc-dc.mjs" ~/bin/protoc-gen-grpc-dc-rust
    protoc --plugin=protoc-gen-grpc-dc-rust=$HOME/bin/protoc-gen-grpc-dc-rust \
           --grpc-dc-rust_out=out -I . echo.proto

## IoT / embedded

The WebRTC stack under `webrtc/rust` is `no_std` (it cross-builds
for Cortex-M): platform traits inject clock, entropy, and the
datagram transport, and an in-crate net stack provides Ethernet
framing, ARP, IPv4/IPv6, UDP, and DHCP — WebRTC with no OS at
all. Two-device bring-up over a virtual cable, power-on to
DataChannel echo:

    cargo run --example iot_cable   # in webrtc/rust

Small generated runtimes (C99, Lua) target constrained hosts;
every generated runtime is dependency-free.

## Single-socket serving (PeerMux)

The Rust, Go, and JS (Node) stacks can host many signaled
peers on one bound UDP socket: `PeerMux` routes STUN by ICE
ufrag, the first DTLS flight by a pair-hint extension, and
every later DTLS record by its RFC 9146 connection id, so
a server needs exactly one open port for all its peer
connections (the single-port topology of Jitsi/Pion) —
and two muxes can peer with each other, since records no
longer route by source address. TURN also works on muxed
peers (the allocation's UDP leg rides a dedicated per-peer
socket). See `webrtc/rust/src/mux.rs`,
`webrtc/go/mux.go`, `webrtc/js/mux.js`; one generated
scenario tests all three stacks, and the cross-stack
matrix pairs mux against mux across stacks.

## Verify the browser story

The `browser-test/` directory carries the real-browser
harness (Playwright). From a clone:

    cd browser-test && npm ci && npx playwright install chromium
    node bdd.test.mjs all   # BDD scenarios in a real browser

Suites needing Rust harness binaries or TURN servers say
so in their headers; the BDD suite is self-contained.

No install, on any device: `docker compose --profile tunnel up`
serves this site through a temporary Cloudflare quick tunnel and
prints a public `https://*.trycloudflare.com` URL (WebRTC needs
the HTTPS secure context off localhost). The URL is random per
run and demo-only; DataChannel traffic stays peer-to-peer and
never passes through the tunnel.

## Behavior specification

The wire behavior is specified as generated BDD scenarios; see
[BDD.md](BDD.md) (also rendered under `docs/`). The same scenario
table runs natively in every language above and in real browsers.

## Provenance

Exported from source commit `5cef18b24b758e4867456b5ebf4ae2a9ac790d86` by the project's
code generator. This tree contains no build system: each language
directory carries its runtime, generated stubs, examples, and
tests in that language's usual layout.
