# gRPC over WebRTC DataChannels

gRPC over a single `RTCDataChannel` — no HTTP/2, no servers to reach:
many concurrent calls (unary, server-, client-, and bidirectional
streaming) are multiplexed onto one ordered, reliable data channel
with a small frame protocol ([SPEC.md](SPEC.md)). Generated,
dependency-free runtimes exist for **Rust, JavaScript, Go, Python,
Java, C#, C++, Swift, Kotlin, Dart, Zig, C99, Lua, Ruby, PHP, and Scala**, plus
descriptor-driven dynamic clients/servers, a reimplemented
zero-dependency WebRTC stack (Go/JS/Rust, [SPEC-WEBRTC.md](SPEC-WEBRTC.md)),
and browser clients in JavaScript, native Rust/Dart/Zig/Lua/C++
WASM runtimes, and generated Go, Zig, C++, Swift, and Kotlin
WASM facades over the JS bridge.

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

| Parameter (all plugins) | Default | Meaning |
|---|---|---|
| `trace=off` | `off` | runtime tracer stays dormant (still registerable from app code) |
| `trace=hooks` | | also wire the tracer registrar into generated stubs (currently Python) |

Tracing is homegrown and dependency-free: register an observer
(`grpcdc.set_tracer` / `setTracer` / `SetTracer` /
`grpcdc_set_tracer`, per language) and clients propagate a W3C
`traceparent` through HEADERS while servers parent spans to it.
See "Tracing" in [SPEC.md](/media/jdavis/DGX10_03/data/repo/devenv/grpc-over-datachannels/SPEC.md).

Message contract: Rust types implement `grpc_dc::Message` (one-line
`grpc_dc::impl_message_via_prost!(T)` under the `prost` feature); JS
classes expose `static encode(msg)` / `static decode(bytes)`; Go types
implement `MarshalDC() []byte` / `UnmarshalDC([]byte) error`.

## Generating stubs in the browser (no install)

The same generation runs fully client-side in `webapp/`: upload or
edit `.proto` files, pick languages, and download a zip containing
the schemas, generated stubs (`gen/<lang>/`), the matching runtimes
(`runtime/<lang>/`), and a README. Schema compilation in the page is
`protocompile` (the compiler library behind buf) built to
WebAssembly (`webapp/compiler/`).

Generation itself runs the actual Racket protoc plugins: the 21
assembled `bin/protoc-gen-grpc-dc-*` programs execute inside a
Racket/WebAssembly runtime in a Web Worker (`webapp/racket/runner.rkt`,
runtime built by `scripts/build-racket-wasm.sh`). The page reframes
the compiled descriptor set as a protoc `CodeGeneratorRequest`, the
runner invokes each plugin's `plugin-main`, and the framed
`CodeGeneratorResponse`s become the zip's `gen/<lang>/` entries —
the same code, not a port. This needs cross-origin isolation
(SharedArrayBuffer), so serve with COOP/COEP headers. When the
runtime cannot start (or with `?gen=js`), the app falls back to
built-in JS generators stamped by the same Racket metaprogram into
`webapp/gen/generators.js` (`racket/webgen.rkt`); those also still
supply the JS message modules (`gen/js/<base>_pb.js`). Coverage is
all 16 native languages plus the 6 WASM/Scala.js facade generators.
`browser-test/webapp_parity.test.mjs` drives the real UI in
Chromium and Firefox and asserts the zipped stubs are byte-identical
to the native `protoc` plugins' output on both the Racket and the
fallback path, so neither path can drift from the plugins.

```bash
make webapp-dist          # build the self-contained static bundle
make webapp-serve         # serve it with COOP/COEP (Racket runner)
# open http://127.0.0.1:8006 in a browser
```

The same page has a **Browse generated code** mode: pick a schema
(the bundled `echo.proto` or the `webapp/testdata` set) and any of
the 22 targets, and navigate every generated file — stubs and
message types generated live in the page (byte-identical to the
plugins), plus each language's runtime, examples, and tests. The
repo-side index is `webapp/gen/corpus-manifest.json`, stamped by
the Racket metaprogram from the tree itself, so what you browse is
what CI compiles. Files open in a highlighted read-only viewer;
search covers file names and contents, **Compare with** shows the
same logical file in a second language side by side, views are
deep-linkable (`#browse/<lang>/<schema>/<group>/<file>`), and
**Open schema in Generator** hands the schema to the generator
tab. `browser-test/webapp_browse.test.mjs` covers navigation,
byte-identity, search, compare, and deep links in Chromium and
Firefox.

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

Behavior documentation is generated, not hand-written: the
scenario table in `racket/bdd-spec.rkt` is the single source of
truth. `make generate` stamps it into `BDD.md` (Given/When/Then
prose) and into a `bdd_scenarios` data file per language, and
each language's `TestBdd` suite interprets that same table
against a loopback client and server — so the documented
examples are exactly what all 15 test suites enforce, and the
two cannot drift apart. `make test` also runs
`make check-generated`, which regenerates the whole tree and
fails if any generated file (docs included) differs from its
Racket source.

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
Lua: the 5.4 interpreter compiled to `wasm32-wasi` with an
exception-handling-based `setjmp` (`wasm/lua`), executing the real
generated Lua runtime from embedded sources in a worker, C++:
the real `grpcdc` runtime and native generated stub compiled to
`wasm32-wasip1` with wasi-sdk's exception-enabled libc++
(`wasm/cpp/native`), endpoint in the new inline pump mode
(Transports offering `TryRecv` run without read/dispatch threads;
stream waits pump the transport) in a worker, Swift: the real
`grpcdc` runtime and native generated stub compiled as Embedded
Swift to `wasm32-unknown-none-wasm` (no Foundation; one generated
runtime serves both native and Embedded builds) with an inline
pump endpoint in a worker (`wasm/swift/native`), and Kotlin: the
real `grpcdc` runtime (a generated Kotlin/Wasm variant of the JVM
bodies — `wasm/kotlin/grpcdc`, plugin
`protoc-gen-grpc-dc-kotlin-native`) and native generated stub
compiled to Kotlin/Wasm with an inline pump endpoint in a worker
(`wasm/kotlin/native`). The Swift, Kotlin, Zig, and C++ native WASM
builds also run in the server role: the same worker hosts the
generated Echo server (inline pump loop driven by
`PollOnce`/`pollOnce`), and the Node test's JS client drives
the four call shapes plus a deadline (`make
test-swift-wasm-native-browser`, `make
test-kotlin-wasm-native-browser`, `make
test-zig-wasm-native-browser`, and `make
test-cpp-wasm-native-browser` run both roles). The Lua WASM
build serves the same way (`wasm/lua/echo_server.lua`, in
`make test-lua-wasm-browser`), and the async Dart and Rust
WASM runtimes serve event-driven on the page thread with no
worker at all (`make test-dart-browser`, `make
test-dart-wasm-browser`, `make test-wasm`). Cross-language
wire compatibility is covered pairwise by `make
test-interop-matrix`: every language's stdio Echo client
against every language's stdio Echo server (14 × 14 ordered
pairs over a raw byte pump, asserting the four call shapes
plus the fail error case, `x-echo` metadata, and a slow-call
deadline), and by `make test-webrtc-matrix`: the Go, JS, and
Rust WebRTC stacks paired over real ICE/DTLS/DataChannels
(gRPC Echo cells for Go/JS in both directions, DataChannel
echo cells for the Rust pairings).
**Facades** wrap the JS implementation: `js/src/wasm_bridge.js`
exposes a byte-level bridge, and generated facades (plugins
`protoc-gen-grpc-dc-wasm-{go,zig,cpp,swift,kotlin}`) give Go,
Zig, C++ (exception-free `wasm32-wasi` reactor), Swift (Embedded
Swift on `wasm32-unknown-none-wasm`, no Foundation), and Kotlin
(Kotlin/Wasm JS interop) typed clients whose calls execute in
the tested JS runtime. All five facades also serve:
`createGrpcDcServerBridge` in the JS bridge hosts a real JS
`Server`, and each generated facade registers typed handlers
on it — Kotlin and Go handlers as bridge objects, Zig, C++, and
Swift handlers as `serve_*` exports the page glue drives through
`js_server_*` imports. Client-streaming and bidi requests reach
Kotlin and Go handlers incrementally: the bridge's
`registerClientStreamInc`/`registerBidiInc` hand the handler a
pull source (`next()` per request as it arrives), and the
browser tests prove incrementality with a ping-pong bidi call
whose first response lands before the second request is sent;
the Zig/C++/Swift export-shaped handlers receive the same feed
one request at a time through generated serve_*Start/Feed/End
exports, so all five facades are incremental. Scala additionally ships a Scala.js facade
(`protoc-gen-grpc-dc-wasm-scala`, packaged with scala-cli;
`make test-scalajs-browser`) with the same client, server, and
incremental-server surfaces. `make test-wasm-matrix`
additionally pairs browser clients and servers across runtimes
(native pairs Kotlin→Zig, Swift→Kotlin, C++→Swift, Zig→C++ plus
facade×native and facade×facade pairs — eleven today, including
Scala.js facade→Kotlin native and Zig native→Scala.js facade)
through a byte relay.
`make test-wasm`, `make
test-zig-wasm-browser`, `make test-zig-wasm-native-browser`,
`make test-lua-wasm-browser`, `make test-dart-browser`,
`make test-dart-wasm-browser`, `make test-cpp-wasm-browser`,
`make test-cpp-wasm-native-browser`, `make
test-swift-wasm-browser`, `make test-swift-wasm-native-browser`,
`make test-kotlin-wasm-browser`, `make
test-kotlin-wasm-native-browser`, and `make test-wasm-matrix`
run each in Chromium and Firefox
over a native `RTCDataChannel`.

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
wasm/                    browser clients: go/, zig/, cpp/,
                         swift/, and kotlin/ (generated facades
                         over the JS bridge), rust/, dart/,
                         zig/native/, cpp/native/, and lua/
                         (native runtimes in WASM, incl.
                         worker/SAB mailbox bridges)
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

- Embedded/IoT: the generated C99 runtime (`c/grpcdc`) is
  stdlib-only with a two-function transport vtable (send/recv one
  DataChannel message) and a blocking, single-threaded call model
  shaped for poll loops; `make test-c-cross` builds it for
  aarch64 and riscv64 Linux and runs the suites under qemu-user
  with code sizes reported; C has the same codec/echo/messages,
  BDD, oracle, and dynamic (descriptor-driven) suites as every
  other language. Generated Rust messages have a
  `rust_no_std=true` profile (alloc-only, `BTreeMap` for maps)
  verified by `make test-rust-nostd`. The WebRTC stack itself is
  embedded-ready: a platform layer (clock/RNG/UDP traits with a
  deterministic tick harness), an alloc-only `no_std` protocol
  core gated on host + wasm32 + Cortex-M
  (`make test-webrtc-nostd`), a hand-rolled Ethernet/ARP/IPv4/
  UDP + DHCPv4 stack for targets with no OS at all, DTLS session
  resumption with a pluggable crypto backend, and serial/BLE
  signaling for headless peers — see the Embedded profile in
  SPEC-WEBRTC.md. Only the target's NIC driver and the OS-backed
  `Peer`/endpoint shell remain platform code.
- One data channel per endpoint; per-stream flow-control windows and
  partial reliability are v2 topics (see SPEC.md).
- HEADERS/TRAILERS payloads are JSON by design (debuggability over
  bytes); DATA payloads have a 16 MiB cap.
- Deadlines/cancellation: cancellation sends RST in every runtime.
  Deadline propagation (`grpc-timeout` metadata, client-side
  `DEADLINE_EXCEEDED` enforcement, server call-context budget — see
  SPEC.md) is implemented in all 16 runtimes, each in its idiom
  (Go drives it through `context.Context`). Rust on wasm32
  enforces through the host `setTimeout`, and native Zig on
  wasm32 through a host monotonic-clock hook installed by its
  browser transport. Remaining caveat: cooperative pump
  runtimes check deadlines between messages and cannot preempt
  a handler already running inline.
- Async surfaces: Python `asyncio`, C++ coroutines (plus
  `std::future`), Ruby and PHP Fibers, Scala
  `scala.concurrent.Future`, and Lua coroutines ship alongside the
  older JS/Kotlin/Dart/Go/Rust async surfaces. Zig has no async
  surface yet (upstream removed language-level async; its runtime
  is single-threaded-pump by design).

## CI and releases

CI runs the same gate as local development — all toolchains
live in `Dockerfile.ci`:

```sh
docker build -f Dockerfile.ci -t grpc-dc-ci .
docker run --rm grpc-dc-ci make test
```

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) does
exactly this on every push and pull request (it takes effect
once the project has a GitHub remote; no remote is configured
in this checkout). Releases are plain Git tags on `master`
(`git tag vX.Y.Z`): before tagging, run `make generate` (the
tree must stay byte-stable), the host `make test`, and the
two Docker commands above, twice each for the container runs.

## License

Licensed under the Apache License, Version 2.0 — see [LICENSE](LICENSE)
and [NOTICE](NOTICE). Code generated by the protoc plugins from your
own `.proto` files may be used without restriction under the additional
permission in [GENERATED-CODE-LICENSE.md](GENERATED-CODE-LICENSE.md);
runtime code copied from this project remains under Apache-2.0.
