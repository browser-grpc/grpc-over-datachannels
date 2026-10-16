# gRPC over WebRTC DataChannels

gRPC over a single `RTCDataChannel` — no HTTP/2, no servers to reach:
many concurrent calls (unary, server-, client-, and bidirectional
streaming) are multiplexed onto one ordered, reliable data channel
with a small frame protocol ([SPEC.md](SPEC.md)). Generated,
dependency-free runtimes exist for **Rust, JavaScript, Go, Python,
Java, C#, C++, Swift, Kotlin, Dart, Zig, Lua, and Ruby**, plus
descriptor-driven dynamic clients/servers, a reimplemented
zero-dependency WebRTC stack (Go/JS/Rust, [SPEC-WEBRTC.md](SPEC-WEBRTC.md)),
and browser clients in JavaScript, Rust (WASM), Dart (JS and WASM),
Go (WASM facade), and Zig (WASM facade).

Everything protocol-shaped is generated from **one Racket source of
truth** by recursive metaprogramming, in three levels:

1. **Recursive macros** in [racket/spec.rkt](racket/spec.rkt) expand the
   frame-type and status-code tables once per entry into Racket
   constants, lookup functions, and the runtime tables.
2. **[racket/metagen.rkt](racket/metagen.rkt)** reads the spec,
   protobuf-wire, descriptor-walk, and emitter modules *as syntax*,
   splices them into two standalone **protoc plugins**
   (`bin/protoc-gen-grpc-dc-rust`, `bin/protoc-gen-grpc-dc-js`), stamps
   the wire tables into `rust/src/wire_gen.rs` and `js/wire_gen.js`, and
   emits golden frame fixtures.
3. **The generated plugins** recursively walk `CodeGeneratorRequest`
   descriptors (file → service → method) and emit typed Rust and JS
   stubs for any `.proto` file.

```text
racket/spec.rkt ──macros──▶ racket codec + runtime tables
       │
       └──metagen──▶ bin/protoc-gen-grpc-dc-{rust,js}   (protoc plugins)
       │           ├─▶ rust/src/wire_gen.rs, js/wire_gen.js
       │           └─▶ fixtures/vectors.json (golden bytes, all 3 runtimes test against them)
       └──protoc──▶ rust/gen/*_grpc_dc.rs, js/examples/*_grpc_dc.js  (service stubs)
```

## Quick start

Prerequisites: [Racket](https://download.racket-lang.org/) and
[protoc](https://github.com/protocolbuffers/protobuf/releases) on `PATH`,
plus Rust (cargo) and Node ≥ 18 for the runtimes.

```bash
make generate   # regenerate plugins, wire tables, fixtures, stubs
make test       # Racket (42 checks), Rust (10 tests), JS (11 tests)
make demos      # echo demo in both languages, all four call shapes
```

Output of the demo (identical in Rust and JS):

```text
unary        -> echo: hello (index 0)
server-stream-> tick#0, tick#1, tick#2
client-stream-> a+b+c (3 parts)
bidi         -> x, y
```

## Generating stubs for your own service

```bash
protoc --plugin=protoc-gen-grpc-dc-rust=bin/protoc-gen-grpc-dc-rust \
       --plugin=protoc-gen-grpc-dc-js=bin/protoc-gen-grpc-dc-js \
       --plugin=protoc-gen-grpc-dc-go=bin/protoc-gen-grpc-dc-go \
       --grpc-dc-rust_out=path/to/out --grpc-dc-js_out=path/to/out \
       --grpc-dc-go_out=path/to/out \
       -I proto your_service.proto
```

Plugin parameters (pass via `--grpc-dc-rust_out=param:outdir`):

| Parameter (Rust) | Default | Meaning |
|---|---|---|
| `message_module=crate::pb` | `crate::pb` | module holding your prost/hand-written message types |

| Parameter (JS) | Default | Meaning |
|---|---|---|
| `pb_import=./echo_pb.js` | `./<base>_pb.js` | module exporting your message classes |

| Parameter (Go) | Default | Meaning |
|---|---|---|
| `go_package=echo` | proto package's last segment | Go package of the generated stub + your message types |

Message contract: Rust types implement `grpc_dc::Message` (one-line
`grpc_dc::impl_message_via_prost!(T)` under the `prost` feature); JS
classes expose `static encode(msg)` / `static decode(bytes)`; Go types
implement `MarshalDC() []byte` / `UnmarshalDC([]byte) error`.

## Using it

Rust (runtime crate `grpc_dc` in [rust/](rust/)):

```rust
let channel = grpc_dc::Channel::new(transport);          // odd stream ids
let client = EchoClient::new(channel);
let resp = client.unary(EchoRequest { /* … */ }).await?;

tokio::spawn(grpc_dc::Server::serve(server_transport,
    vec![echo_service(Arc::new(MyEcho))]));
```

JavaScript (zero-dependency ESM in [js/](js/)):

```js
import { Channel, Server, createPeer, memoryDataChannelPair } from "grpc-dc";
const client = new EchoClient(new Channel(rtcDataChannel));
const server = new Server().addService(createEchoService(handlers));
server.serve(rtcDataChannel);
```

Signaling/ICE stay with your app: hand an *open* channel to these APIs.
Rust plugs a real `RTCDataChannel` in through the `DcTransport` trait
(`InboxDc` adapts callback-style stacks such as the `webrtc` crate); JS
accepts any object with the `RTCDataChannel` message interface (browser
`RTCDataChannel`, `werift`, `node-datachannel`, …). Both sides can call
each other over the same channel: the peer that created it allocates odd
stream ids, the answering peer even ones (`Peer` in Rust, `createPeer`
in JS).

## Testing notes

Beyond per-language loopback suites, the same golden frame/protobuf
bytes (`fixtures/vectors.json`, authored by the Racket codec) are
asserted in Racket, Rust, and JS, and `js/test/interop.test.js` runs
live cross-language calls in **both directions** (JS client ↔ Rust
server and Rust client ↔ JS server, all four shapes) over a stdio
bridge whose framed units are exactly DataChannel messages.

Go joins in `go/`: golden-vector tests, a loopback suite for all four
shapes, and stdio-bridge interop in both directions against the Rust
binaries (`go/interop_test.go`). Its protoc plugin
(`bin/protoc-gen-grpc-dc-go`) is generated from
`racket/template-go.rkt` by the same metaprogram; messages implement
`MarshalDC`/`UnmarshalDC` (see `go/examples/echo_pb.go`).

Official-implementation oracle: `oracle/bridge.mjs` translates
HTTP/2 ⇄ grpc-dc frames (TCP ⇄ DataChannel), so the official
grpc-java stack (`oracle/java`) acts as a test oracle for every
runtime. One Racket table (`racket/oracle-spec.rkt`) generates the
scenario file and the JS/Go/Rust test drivers; the Java client is
hand-written and independent. Compression (gzip) is terminated in
the bridge — decompressed on entry, never emitted on the
DataChannel — so the wire stays compression-free (see Known limits).

Browser clients come in two kinds. **Native runtimes** run the real
codec/endpoint/stub code in the page — Rust compiled to WASM
(`wasm/rust`), Dart via both `dart compile js` and
`dart compile wasm` (`wasm/dart`), the Zig runtime compiled to WASM
running in a Web Worker over a SharedArrayBuffer mailbox
(`wasm/zig/native` — its blocking pump model maps onto the worker),
and Lua: the 5.4 interpreter compiled to `wasm32-wasi` with an
exception-handling-based `setjmp` (`wasm/lua`), executing the real
generated Lua runtime from embedded sources in a worker.
**Facades** wrap the JS implementation: `js/src/wasm_bridge.js`
exposes a byte-level bridge, and generated facades (plugins
`protoc-gen-grpc-dc-wasm-go` and `protoc-gen-grpc-dc-wasm-zig`)
give Go and Zig typed clients whose calls execute in the tested JS
runtime. `make test-wasm`, `make test-zig-wasm-browser`,
`make test-zig-wasm-native-browser`, `make test-lua-wasm-browser`,
`make test-dart-browser`, and `make test-dart-wasm-browser` run
each in Chromium and Firefox over a native `RTCDataChannel`.

`make test` also covers the reimplemented WebRTC stack itself
(`webrtc/`, see SPEC-WEBRTC.md): three independent stacks (Go stdlib,
JS Node builtins, Rust std-only with hand-rolled crypto) covering
SDP, ICE (host/srflx/TURN relay incl. TCP/TLS legs, trickle, consent
freshness, restart, IPv6), DTLS 1.2 in both roles, SCTP/PR-SCTP, and
DCEP — cross-checked against OpenSSL, against each other, and against
real Chromium/Firefox pages via Playwright (`browser-test/`).
Everything runs in the CI image (`Dockerfile.ci`).

## Layout

```text
SPEC.md                  wire protocol v1
proto/echo.proto         example service exercising all four shapes
racket/                  spec.rkt (source of truth), pb.rkt, desc.rkt,
                         metagen.rkt, template-{rust,js,go}.rkt (stub
                         emitters), runtime-{rust,js,go}.rkt (runtime
                         emitters — the runtimes are generated), tests/
bin/                     GENERATED protoc plugins (do not edit)
fixtures/vectors.json    GENERATED golden bytes
rust/                    runtime crate, generated stubs (gen/), examples
js/                      runtime (src/), generated stub + demo (examples/)
go/                      Go runtime (stdlib only), generated stub +
                         hand-written messages (examples/), stdio
                         interop harnesses
webrtc/                  reimplemented zero-dependency WebRTC stack
                         (Rust std-only + JS Node-builtins), tables
                         generated by racket/webrtc-{spec,gen}.rkt
python/ java/ csharp/    generated runtimes + stubs for the further
cpp/ swift/ kotlin/      languages (same layout as go/: runtime,
dart/ zig/ lua/ ruby/    examples, tests; all stdlib-only)
browser-test/            Playwright real-browser interop tests
oracle/                  TCP<->DataChannel bridge (bridge.mjs) and the
                         official grpc-java oracle (java/)
wasm/                    browser clients: go/ and zig/ (generated
                         facades over the JS bridge), rust/, dart/,
                         zig/native/, and lua/ (native runtimes in
                         WASM, incl. worker/SAB mailbox bridges)
Dockerfile.ci            all build/test/tooling in one image
Makefile                 generate / test / demos
```

## Known limits (v1)

- No compression on the grpc-dc wire — deliberately held off. Where
  an official gRPC peer requires it, the oracle proxy
  (`oracle/bridge.mjs`) terminates gzip at the HTTP/2 edge, so
  language runtimes never see compressed frames.
- No external gRPC/protobuf runtime dependencies in any language:
  Rust/JS/Go runtimes are generated by the Racket metaprogram and use
  only their standard libraries (plus prost/tokio plumbing in Rust).

- One data channel per endpoint; per-stream flow-control windows and
  partial reliability are v2 topics (see SPEC.md).
- HEADERS/TRAILERS payloads are JSON by design (debuggability over
  bytes); DATA payloads have a 16 MiB cap.
- Deadlines/cancellation: `Channel::cancel` sends RST; no automatic
  deadline propagation yet.
