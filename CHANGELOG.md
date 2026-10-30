# Changelog

All notable changes to grpc-over-datachannels. Versions are
curated release tags on `master`; dates are the tag dates.

## v0.35.9 — 2026-10-30

- Public CI no longer runs 4× per release: both public
  workflows trigger on branch pushes and PRs only (release
  tags previously re-ran identical trees).
- The main public repo gains a browser CI job: Playwright
  suites (Chromium/Firefox/WebKit) from the exported
  `browser-test/` harness. This also fixes the exporter
  dropping tracked `browser-test` sources (`test.mjs`,
  `harness.mjs`, `fake_turnd.mjs`, `echo_deep_checks.mjs`
  missed the old copy pattern), so `npm test` in a public
  clone runs the full script again.

## v0.35.8 — 2026-10-30 (published to GitHub/npm/PyPI/GHCR/NuGet/Maven Central)

- `publish-maven` root-caused and fixed: GitHub-built
  bundles carried `_remote.repositories` and
  `maven-metadata-local.xml` from the runner's local Maven
  repository, which Portal validation rejects; the workflow
  now strips them from the bundle zip before upload
  (verified VALIDATED on a diagnostic branch).
- Kafka e2e: the commit-after-rebalance test re-subscribes
  and retries when a member stream dies mid-race under
  load, instead of asserting on a fenced commit.

## v0.35.7 — 2026-10-30 (published to GitHub/npm/PyPI/GHCR/NuGet/Maven Central)

- Kafka proxy: `Produce` now retries stale-leader errors
  (5/6) with backoff for up to ~5 s, so a produce landing
  right after topic creation no longer fails while leaders
  elect on a loaded broker.
- The `publish-maven` workflow uploads the signed bundle
  through the Central Portal API (the plugin's own upload
  fails Portal bundle validation while the identical zip
  validates via the API, now proven on 0.35.5/0.35.6).

## v0.35.6 — 2026-10-30 (published to GitHub/npm/PyPI/GHCR/NuGet/Maven Central)

- Public CI fixes from the first GitHub runs: the Kafka
  proxy retries a group commit briefly on
  ILLEGAL_GENERATION/UNKNOWN_MEMBER_ID while a rebalance
  settles; the Go and interop images run `go mod tidy` so
  the versioned webrtc module resolves in-repo; the C++
  image compiles every test file its driver references;
  the C image defines `_DEFAULT_SOURCE` (gcc-14 strict
  POSIX declarations); the Swift/Kotlin/Scala test compiles
  include `examples/interop/*`; and the Rust image skips
  the one oracle test that needs external reference clients.

## v0.35.5 — 2026-10-30 (published to GitHub/npm/PyPI/GHCR/NuGet/Maven Central)

- The Java runtime now publishes to Maven Central as
  `io.github.browser-grpc:grpc-dc`: a generated `java/pom.xml`
  (sources/javadoc jars, GPG signing, Central Portal
  publishing) and a manual-dispatch `publish-maven` workflow.
  The `io.github.browser-grpc` namespace is verified on the
  Central Portal.

## v0.35.4 — 2026-10-30 (published to GitHub/npm/PyPI/GHCR/NuGet)

- The C# runtime now publishes to NuGet as
  [`GrpcDc`](https://www.nuget.org/packages/GrpcDc): package
  metadata in `Grpcdc.csproj`, version and package readme
  injected by the exporter, a best-effort pack/push step in
  the release flow (`NUGET_API_KEY`), and the primary path —
  a `publish-nuget` GitHub Actions workflow using NuGet
  Trusted Publishing (OIDC, no stored key). Maven Central for
  the Java runtime is the remaining registry and follows
  separately (it needs a Central Portal namespace + GPG).

## v0.35.3 — 2026-10-30 (published to GitHub/npm/PyPI/GHCR)

- The public repo now runs CI on GitHub: a generated
  `.github/workflows/ci.yml` builds and runs every per-language
  Docker image (`docker/<lang>.Dockerfile`) as a parallel
  matrix job, plus the interop image — the same two commands
  users can run from a local clone. Together with the
  kafka-proxy repo's CI, both public repos now show live
  per-language test results.

## v0.35.2 — 2026-10-30 (published to GitHub/npm/PyPI/GHCR)

- The Kafka proxy gets its own public repo,
  [browser-grpc/kafka-proxy](https://github.com/browser-grpc/kafka-proxy):
  a standalone generated export (Rust runtime + proxy, no
  Racket source) with a CI Dockerfile that runs the e2e suite
  against real Apache Kafka and Redpanda fixtures, a public
  runner script, and a GitHub Actions workflow. It is
  versioned and tagged in lockstep with this repo.

## v0.35.1 — 2026-10-30 (published to GitHub/npm/PyPI/GHCR)

- The Kafka proxy now ships as a container image:
  `ghcr.io/browser-grpc/kafka-proxy` (built with broker TLS and
  WebRTC-direct support), with a generated
  `docker/kafka-proxy.Dockerfile` and a public `KAFKA.md` guide
  in the export. No new org — it publishes under `browser-grpc`
  alongside `protoc-plugins`.

## v0.35.0 — 2026-10-30 (published to GitHub/npm/PyPI/GHCR)

- Kafka over gRPC: `grpcdc.kafka.v1.Kafka` generated stubs and
  clients for every supported language (native and browser),
  served by a Rust proxy that speaks the Kafka binary protocol
  to Apache Kafka (KRaft) and Redpanda. Produce/consume with
  per-partition ordering and offset resume, consumer groups
  (range/roundrobin assignment, static membership, fencing,
  out-of-range auto-reset, broker-restart resume), idempotent
  and transactional producers with `read_committed` consume,
  null-vs-empty record keys, multi-broker leader routing, and
  dependency-free gzip/snappy/LZ4/zstd codecs, SASL
  PLAIN/SCRAM-SHA-256/SCRAM-SHA-512, and broker TLS. Extensive
  generated e2e coverage runs against both brokers in CI.

## v0.34.0 — 2026-10-28 (published to GitHub/npm/PyPI/GHCR)

- The generator webapp now bundles starter projects for
  arbitrary schemas (web, Node, Python, Go) in its starter
  kit, and can save/open schema files in Google Drive
  (client-side only, `drive.file` scope — any Google account
  can sign in and keep schemas in its own Drive).
- The generator page is also reachable at
  [grpc-dc.lunchgamer.com](https://grpc-dc.lunchgamer.com/)
  (a redirect to the live app), referenced from the app
  footer and the public README; the page carries the
  AdSense Auto ads script.

## v0.33.0 — 2026-10-27 (published to GitHub/npm/PyPI/GHCR)

- **Breaking (Go):** the Go modules are renamed so they
  resolve on pkg.go.dev: `grpcdc` →
  `github.com/browser-grpc/grpc-over-datachannels/go` and
  `dcwebrtc` →
  `github.com/browser-grpc/grpc-over-datachannels/webrtc/go`.
  Generated Go stubs now import the runtime by the new path
  (regenerate your stubs), and hand-written imports need the
  same mechanical rewrite — Go has no alias mechanism for a
  renamed module. `go get
  github.com/browser-grpc/grpc-over-datachannels/go` now works
  against the public repository; the two modules are versioned
  together (`go/v0.33.0` and `webrtc/go/v0.33.0` tags beside
  `v0.33.0`).
- Interop `TestService` server implementations are now
  generated from the shared behavior spec in all nine server
  languages (JavaScript, Python, C, C++, Dart, Zig, Lua, PHP,
  Ruby); wire behavior is unchanged (full interop matrix
  passes, 225/225 pairs).
- The Rust enum emission shape is single-sourced between the
  native plugin and the browser generators; unknown enum
  values keep round-tripping (`Unknown(i32)`), now pinned by
  an enum-corpus parity case in Chromium, Firefox, and WebKit.

## v0.32.16 — 2026-10-27 (published to GitHub/npm/PyPI/GHCR)

- Event bus (`grpcdc.events.v1`): generated publish/subscribe
  with shallow tag-value filtering (enum tags extensible in
  your own schema copy), in-memory at-most-once broker, plus
  a git-backed log serde (one commit per event) for native
  peers — now in all sixteen languages (JavaScript, Python,
  Go, Rust, Ruby, PHP, Dart, Lua, Java, C#, Kotlin, Scala,
  Swift, C++, Zig, C), native and (for JavaScript) browser.
  Demos and generated tests in each language; browser
  end-to-end (Chromium/Firefox/WebKit) verified. Where a
  language's generated enum is closed (Dart, Java, Kotlin,
  Swift, Zig), user-defined tags arrive by regenerating from
  an extended schema copy; where the runtime dispatches
  inline on one thread (C, and Lua's synchronous dispatch),
  the suites exercise fan-out through in-process
  subscriptions fed by Publish RPC, as documented in the
  generated modules.
- Browser-test and Go harness boilerplate consolidated into
  `browser-test/harness.mjs` and
  `go/cmd/internal/browserharness` (no behavior change).
- Rust protobuf enums now preserve unknown values
  (`Tag::Unknown(n)`) instead of collapsing them to the first
  value; JS client streams cancel promptly on break/return.

## v0.32.15 — 2026-10-26 (published to GitHub/npm/PyPI/GHCR)

- Interop case table extended everywhere: the generated
  tables now include `special_status_message`,
  `cancel_after_begin`, `cancel_after_first_response`, and
  `timeout_on_sleeping_server` in every client suite, plus
  compression rows (`client_compressed_unary/streaming`,
  `server_compressed_unary/streaming`) in all client suites
  (gzip stays on the bridge HTTP/2 hop; the DataChannel wire
  is compression-free) and ORCA rows (`orca_per_rpc`,
  `orca_oob`) for the Dart/Swift/Zig/C/C++/Lua/Ruby/PHP
  clients.
- Direction-B server grading for every native language: the
  official grpc-java TestServiceClient (19 cases incl.
  compression/cacheable) and grpc-go interop-client (16 cases
  incl. ORCA) now run against each generated language's
  TestService server through the bridge — Java, Kotlin,
  Scala, C#, Dart, Swift, Zig, C, C++, Lua, Ruby, and PHP
  join the existing servers. The C server's metrics stream
  answers one-shot (single-stream runtime; `orca_oob` stays
  skipped there, as documented in the test), and the PHP
  endpoint now dispatches each inbound call in its own Fiber
  with an input-driven scheduler, so concurrent streams
  interleave regardless of HEADERS order (its stdio transport
  is buffered/non-blocking to match).
- Generated HTTP/2 client transports for Kotlin, Scala,
  Dart, Swift, and Zig, stamped by `racket/http2-gen.rkt`
  from the shared RFC 9113 spec/HPACK tables like the other
  seven: cleartext h2c everywhere plus TLS (ALPN h2) where
  the stdlib has it (Kotlin/Scala via the JDK, Dart via
  SecureSocket); Swift and Zig print a clear SKIP on the TLS
  leg (no stdlib TLS) instead of falling back to cleartext.
  Each has a `TestHttp2Oracle` suite against the official
  grpc-java OracleServer plus the Node TLS fixture.
- SCTP DSL phase 3: the SACK/gap/retransmit machine is
  generated from `racket/sctp-dsl.rkt` alongside reassembly
  (`sctp_sack_gen` for Go/JS/Rust) — cumulative-TSN tracking,
  gap-block computation, and miss-count fast retransmit with
  serial arithmetic throughout (the hand-written Rust gap
  walk compared TSNs non-serially at wrap). New generated
  conformance scenarios (`sack_scenarios` in
  fixtures/sctp_vectors.json) run the same steps in all
  three stacks, including a TSN-wrap scenario.
- Browser matrix: WebKit legs are on in the CI image for
  every `all`-mode browser test, and
  browser-test/direct_turn.test.mjs gains Firefox/WebKit
  legs (WebKit passes relay<->relay; Firefox skips with the
  documented environment limitation).

## v0.32.14 — 2026-10-26

- Interop client grading now covers every generated client:
  Dart, Swift, Zig, C, C++, Lua, Ruby, and PHP suites join
  Java/C#/Kotlin/Scala running the same generated 11-case
  table against the official Go TestServiceServer through the
  bridge (`make interop-stubs` grows stubs for all of them;
  `racket/interop-gen.rkt` emits the per-language tables).
  Java/C#/Kotlin/Scala additionally grade the ORCA per-RPC
  and out-of-band rows (`orca_per_rpc`, `orca_oob`).
  Building these suites exposed and fixed generator bugs,
  each mirrored in the browser plugin shim (webgen.rkt):
  C++ message classes emit out-of-line method definitions in
  dependency order (incomplete-type by-value members), dotted
  package namespaces, and per-origin stub includes; Lua/Ruby/
  PHP stubs require and qualify per-origin message modules;
  Ruby empty-message decoding no longer emits an empty
  `case`; PHP class names that collide with reserved words
  (`Empty`) get a trailing underscore; generated stream
  wrappers in Lua/Ruby/PHP expose `headers`/`trailers`, and
  the generated C runtime records client response HEADERS
  (`grpcdc_stream_headers`).
- SCTP reassembly is generated, not mirrored: the machine is
  described once in `racket/sctp-dsl.rkt` and emitted as
  `webrtc/go/sctp_reassembly_gen.go`,
  `webrtc/js/sctp_reassembly_gen.js`, and
  `webrtc/rust/src/sctp_reassembly_gen.rs` (feed/drain/skip/
  reset over per-stream partials). The three hand-mirrored
  implementations and their drift class (v0.32.12) are gone;
  association code keeps TSN-window/SACK bookkeeping and
  consumes reassembler deliveries. JS adopts the Go/Rust
  merge semantics (pairwise merge, extract-any completion).
- Generated HTTP/2 client transports for Java and C#:
  `emit-java-http2`/`emit-csharp-http2` in
  `racket/http2-gen.rkt` stamp `java/grpcdc/Http2Transport.java`
  and `csharp/grpcdc/Http2Transport.cs` from the same RFC 9113
  spec/HPACK tables as JS/Go/Python — cleartext h2c plus TLS
  (ALPN h2) dial, generated HPACK codec, stream/connection
  flow control, gzip keyed on `grpc-encoding`. New
  `TestHttp2Oracle` suites in both languages dial the
  official grpc-java OracleServer directly (scenarios,
  metadata echo, 200x1500-byte flow-control stream) plus a
  TLS leg against the Node fixture.

## v0.32.13 — 2026-10-26

- Interop client grading extended from Java to C#, Kotlin,
  and Scala: generated grpc.testing/ORCA stubs for all three
  (`make interop-stubs`), generated case-table emitters in
  racket/interop-gen.rkt, and thin TestInteropOracle runners
  grading each client against the official Go
  TestServiceServer through the bridge (the same 11 cases,
  now including custom_metadata on the duplex leg — generated
  receiving-stream wrappers in Java/C#/Kotlin/Scala expose
  `headers`/`trailers` accessors). Building these stubs
  exposed and fixed generator bugs, each mirrored in the
  browser plugin shim (webgen.rkt): cross-package stub type
  references are fully qualified in C#/Kotlin/Scala (Java in
  v0.32.12); C# map fields named after their enclosing
  message get a trailing underscore; Kotlin async adapter
  retention is per-service (multiple services per file);
  Scala fields named with hard keywords (`Payload.type`)
  are backtick-quoted.
- SCTP conformance vectors: racket/sctp-spec.rkt scenarios
  stamped to fixtures/sctp_vectors.json and interpreted by
  the Go/JS/Rust SCTP suites (interleaved, reversed,
  duplicated fragments; SSN-ordered release), so the three
  mirrored stacks prove identical wire behaviour on shared
  generated inputs. The hand-written per-stack regression
  tests from v0.32.12 remain.
- `make stress-interop` also loops the full official-clients
  oracle function 5x under `-race`.

## v0.32.12 — 2026-10-26

- Root-caused the intermittent proxy/WebRTC-Direct interop
  hang: the SCTP reassembly in all three WebRTC stacks
  (JS/Go/Rust) merged TSN-contiguous partials across message
  boundaries. When a large request's END fragment landed
  after the next message's BEGIN fragment, the two messages
  were concatenated into one corrupt delivery (dropped by
  the gRPC frame parser) and the second message's SSN never
  completed, wedging ordered delivery on the stream while
  SACKs kept advancing — servers sat idle with a handler
  blocked in Recv. Reassembly now never merges across a
  BEGIN/END boundary and never attaches fragments to an
  already-ended partial; each stack has a regression test
  delivering interleaved fragments of two messages.
- BDD: shared `stream-break` scenario kind ("Breaking a
  server stream stops the server") generated from
  bdd-spec for every runner — JS, Go, Python loopback +
  sidecar, Rust, browser (Chromium/Firefox), Java, C#,
  Kotlin, Scala, Dart, Swift, C, C++, Zig, Lua, Ruby, PHP.
  Follow-on abandonment fixes from the audit: C++ and Zig
  inline-pump servers now pump once per send so a handler
  on the pump stack observes the peer RST; the C sidecar
  transport gained a timed recv so sidecar handlers can
  poll for RST; Ruby streams RST via a finalizer when the
  stream object is dropped without break/close; Lua
  (`__gc`/`<close>`) and PHP (`__destruct`) streams cancel
  on abandonment.
- Java interop client grading: generated Java stubs for
  grpc.testing + ORCA (`make interop-stubs`), a generated
  interop case table (`InteropCases`, from
  racket/interop-spec.rkt), and `TestInteropOracle` running
  the Java client against the official Go TestServiceServer
  through the bridge (empty, large unary, client/server
  streaming, ping-pong, empty stream, status code/message
  unary + duplex, unimplemented method/service). Building
  the ORCA stubs exposed and fixed two Java codegen bugs:
  cross-package message references in stubs are now fully
  qualified, and boxed map key/value defaults for
  float/double are emitted as `0.0f`/`0.0`.

## v0.32.11 — 2026-10-25

- Stream-break cancellation audited and fixed across all 16
  runtimes: abandoning a server-streaming call via the
  natural idiom (iterator break/close, Drop/destructor,
  subscription/task cancellation, context cancel without a
  pending Recv, enumerator/generator close) now sends RST
  CANCELLED, and every server endpoint fails sends on
  RST-terminated streams with CANCELLED so producing
  handlers stop instead of streaming into the void. JS was
  fixed in v0.32.10; this wave covers Go, Rust, Python,
  Java, C#, Kotlin, Scala, Dart, Swift, C, C++, Zig, Lua,
  Ruby, and PHP, each with a loopback regression test
  asserting the server stops producing.
- Rust interop grading: generated Rust stubs for
  grpc.testing + ORCA (`make interop-stubs`), a Rust
  TestService server (`interop_server_stdio` example), and
  `rust/tests/interop_oracle.rs` grading the Rust client
  against the reference Go server (empty/large unary,
  orca_per_rpc, orca_oob) and the Rust server against the
  official Java client (all four compressed cases) and the
  Go client (ORCA). Found and fixed a Rust pb codegen bug:
  proto fields named like Rust keywords (`Payload.type`)
  are now emitted as raw identifiers (`r#type`).
- Proxy: mid-stream compression start (first message
  identity, later messages gzipped) is covered by a proxy
  test — payloads are always transcoded correctly; the one
  documented limitation is that `grpc-encoding` metadata
  cannot be surfaced once the request HEADERS frame has
  gone out.
- `make stress-interop`: flake-hunting lane repeating the
  Go/Java `custom_metadata` oracle under `-race`.

## v0.32.10 — 2026-10-25

- Server-direction compression interop: the proxy now
  surfaces the declared `grpc-encoding` as ordinary metadata
  (injected from the first request message's compressed flag
  when per-message compression declares no header) and gzips
  response messages for servers that declare `grpc-encoding:
  gzip` in their initial metadata, so the reference
  `expect_compressed` checks map onto the compression-free
  DataChannel wire. `client_compressed_unary`,
  `client_compressed_streaming`, `server_compressed_unary`,
  and `server_compressed_streaming` pass under the grpc-java
  client against our JS/Go/Python servers; the bridge
  decompresses flagged messages as gzip even without a
  declared header, matching stock server behavior.
- ORCA out-of-band streaming graded end-to-end:
  `OpenRcaService.StreamCoreMetrics` (vendored proto,
  generated stubs) is implemented by our JS/Go/Python
  servers, and our clients feed the shared state via
  `FullDuplexCall` and read it back on the stream — against
  the reference Go server's ORCA service and our own.
- Go server-oracle case runners are time-bounded (120 s per
  case, like the JS/Python drivers) after a one-off
  full-suite hang in a Java `custom_metadata` call; the case
  passes repeatedly under `-race` stress (targeted, full
  function, and full package), so the hang is hardened
  against rather than left to eat the package timeout.
- JS runtime: breaking out of a server-streaming iteration
  now cancels the call (RST) instead of only closing it
  locally, and the server endpoint fails sends on
  RST-terminated streams so a producing handler stops
  instead of streaming into the void. Found via the ORCA
  OOB stream (infinite by design) hanging the JS oracle
  suite at exit; covered by a new echo regression test.

## v0.32.9 — 2026-10-25

- BDD grows a shared `unary-trailer` scenario across all 16
  language runners: echo implementations surface a request
  metadata marker as the `x-echo-trailer` response trailer,
  and every runner asserts it end-to-end. Writing it caught
  two real runtime bugs, now fixed in the generators:
  Kotlin/Scala status frames dropped the trailing-metadata
  member, and Swift copied the (empty) response-metadata maps
  into its response sink before dispatch, so
  `SetHeaders`/`SetTrailers` never reached the wire.
- ORCA load reporting in the interop harness:
  `orca_per_rpc` and `orca_oob` run against our JS/Go/Python
  servers under the official grpc-go interop client (via its
  test LB service config), and `orca_per_rpc` runs from our
  JS/Go/Python clients against both reference servers. The
  `endpoint-load-metrics-bin` trailer carries the base64
  `OrcaLoadReport` (vendored proto, generated stubs);
  grpc-java's client is excluded by upstream behavior (it
  fails the case even against grpc-go's own server).
- Compression in the generated HTTP/2 client transports
  (JS/Go/Python): requests gzip when call metadata carries
  `grpc-encoding: gzip`, every stream advertises
  `grpc-accept-encoding`, and flagged responses decompress.
  The four `*_compressed_*` interop cases pass against both
  reference servers (the oracle Go server now builds with the
  gzip encoding import, which upstream's server main omits).
  Server-direction compressed cases stay excluded: the
  DataChannel wire is compression-free by design and the
  proxy terminates gzip at the HTTP/2 hop.
- Soak: `scripts/soak.mjs` (`make soak`) sustains
  large-unary RPCs against the Java oracle (our JS client
  direct; the official Go client against the oracle and
  against our server through the ingress proxy/WebRTC-Direct
  path), with per-iteration latency budgets. Default 1000
  iterations per phase passes with zero failures.

## v0.32.8 — 2026-10-25

- Response initial + trailing metadata across all 16
  generated runtimes: TRAILERS status frames carry an
  optional metadata member and response HEADERS carries
  initial metadata; servers set them via the call context
  (JS `ctx.setHeaders/setTrailers`, Go
  `grpcdc.SetHeader/SetTrailer`, Python
  `ctx.set_headers/set_trailers`, equivalents elsewhere),
  clients surface them (JS `onHeaders`/`onTrailers` options,
  Go `Header()`/`Trailer()`, Python `.headers`/`.trailers`,
  equivalents elsewhere). `-bin` values are base64 on the
  wire, matching the gRPC HTTP/2 convention. The grpc-java /
  grpc-go `custom_metadata` interop case now runs in both
  directions with the full upstream echo asserted.
- JS generated client takes an `AbortSignal` in call
  options for per-call cancellation; the interop
  `cancel_after_begin` / `cancel_after_first_response`
  cases now run under the JS driver too.

## v0.32.7 — 2026-10-25

- Public-export hygiene: the clarity gate in the release
  exporter silently never matched (a POSIX class Racket's
  regexp engine does not honor), so generator-internal
  source paths had leaked into three HTTP/2 oracle test
  headers and one generated plugin bundle header. Gate
  regex fixed (and the runtime asset-URL exemption made
  real); offending comments scrubbed at the source and
  regenerated.

## v0.32.6 — 2026-10-25

- Interop oracle completed: grpc-go added as second
  Direction-A oracle (`oracle/go-interop` builds the official
  interop server/client; Dockerfile.ci builds both), and
  Direction B runs the official grpc-java/grpc-go interop
  clients against generated TestService servers for JS, Go,
  and Python through the ingress proxy -> WebRTC-Direct
  path (14 Java / 13 Go cases each; `custom_metadata`
  excluded — trailing metadata is not surfaced by the frame
  layer). Fixes that fell out: JS SCTP gained a congestion
  window (RFC 9260) plus out-of-order reassembly merging and
  the receive pump now drains socket backlog — large
  messages over WebRTC-Direct went from RTO-bound seconds
  (or hangs) to ~20ms; DTLS silently discards replayed/bad
  records instead of killing the pump; JS status frames no
  longer leak the `NAME: ` display prefix onto the wire
  (`StatusError.statusMessage`); larger UDP socket buffers
  on the direct path. The same cwnd/reassembly/pump fixes
  are mirrored in the Rust and Go SCTP stacks.
- Interop oracle (Direction A): the canonical grpc interop
  suite now grades our generated clients. `grpc.testing`
  protos vendored in `oracle/interop` (grpc-java v1.62.2,
  Apache 2.0); our plugins generate `TestService` stubs for
  JS, Python, and Go (`make interop-stubs`), and per-language
  drivers run the interop cases against the official
  grpc-java `TestServiceServer` directly over HTTP/2:
  empty/large unary, streaming shapes, ping-pong, custom
  metadata (initial echo), status + special-status messages,
  unimplemented method/service, cancels, sleeping-server
  deadline. Two generator fixes fell out: JS protobuf `bytes`
  encoding no longer spreads large payloads onto the call
  stack (271 KiB payloads work), and Go codegen handles
  field-less messages and service-less protos. Still open:
  official clients vs our servers (Direction B), grpc-go as
  second oracle, trailing-metadata surfacing.
- Generated HTTP/2 client transports (wave 1): generated
  stubs can now call official gRPC servers (grpc-java and
  peers) directly over HTTP/2 — no DataChannel, no bridge.
  `racket/http2-spec.rkt` holds the RFC 9113/7541 tables once;
  `racket/http2-gen.rkt` emits a frame-Transport for JS
  (`js/src/http2.js`, adapter over `node:http2`, exported as
  `grpc-dc/http2`), Python (`grpcdc.http2.Http2Transport`),
  and Go (`grpcdc.DialHttp2`) — Python/Go carry a generated
  manual HPACK + session layer with flow control. TLS is not
  generated: stdlib TLS (ALPN `h2`) wraps the byte stream and
  only the dial glue is emitted. Proven by direct oracle
  tests against grpc-java (scenarios, metadata, deadlines,
  unknown methods, 1000-message streams, 300 KiB messages)
  plus TLS dials to a TLS HTTP/2 front-end.

## v0.32.5 — 2026-10-24

- Proxy redone, ingress-only, scoped to exactly the
  official gRPC transport set (grpc-java and peers):
  HTTP/2 over TCP (h2c, or TLS with --tls-cert/--tls-key)
  in front of a grpc-dc server dialed over WebRTC-Direct
  (certhash multiaddr, no signaling server) and mapped
  onto the existing Server.serve interface. Removed: the
  egress direction (DataChannel clients -> HTTP/2
  backend), the custom framed-TCP ingress, the HTTP/3
  front-end, and the smoltcp sidecar crate. The
  Racket proxy spec now generates a single http2-ingress
  mode; parity tests assert the removed surface is absent.
- Oracle coverage vs grpc-java filled in: the Java oracle
  now implements canonical Echo semantics (x-echo metadata
  reflection, delayMs, per-shape fail) and client modes
  for metadata, deadlines (new DEADLINE case), and TLS.
  New e2e tests: metadata both directions, deadline both
  directions (DEADLINE_EXCEEDED), unknown method
  (UNIMPLEMENTED), 1000-message server stream, Java client
  over TLS through the bridge, and the official Java
  client through the redone ingress proxy to a grpc-dc
  server over WebRTC-Direct. All passing.
- Includes everything in v0.32.4 (superseded before its
  separate public publish).

## v0.32.4 — 2026-10-24

- Proxy surface, mostly generated: racket/proxy-spec.rkt is
  the single source for proxy modes; proxy-gen stamps it
  into proxy/proxy_modes.generated.json and proxy/README.md
  via `make generate`, and proxy.test.mjs pins spec<->code
  parity in `make test`.
- smoltcp spike (proxy/tcp-sidecar, Rust): userspace TCP
  echo between two smoltcp stacks over a virtual Ethernet
  pair — handshake/data/teardown with zero OS sockets
  (`cargo test` in the crate), plus a UDP-encapsulated
  frame binary. Separate crate: dc-webrtc stays zero-dep.
- HTTP/3 spike (proxy/h3-terminator, Rust/quinn): QUIC
  endpoint (self-signed) bridging streams to a TCP backend
  (`cargo test` in the crate). QUIC exists only client<->
  proxy; the h3 framing layer is the follow-up.
- The Node grpc-dc-proxy is now in the public export
  (proxy/ with bridge + generated README + mode table;
  imports rewritten to the export layout, healthz-verified
  from the export tree). Rust sidecars stay private.
- Outreach drafts refreshed for the current feature set;
  awesome-list submission happens in a publish window.
- Includes everything in v0.32.3 (superseded before its
  separate public publish).

## v0.32.3 — 2026-10-24

- Spike: supported TCP<->DataChannel proxy process
  (proxy/grpc-dc-proxy.mjs), generalizing the oracle test
  bridge. grpc-dc clients (browser or native) signal over
  WebSocket and call a stock HTTP/2 gRPC backend with no
  backend changes; compression stays terminated in the
  proxy. Proven by proxy/proxy.test.mjs (`make test-proxy`,
  now in `make test`): generated JS client over a real
  DataChannel through the proxy — unary, server-streaming,
  and trailers-only INVALID_ARGUMENT all pass. Follow-ups
  (not in this spike): smoltcp TCP-listener sidecar mode,
  HTTP/3 termination, generated per-language proxy
  examples, public export of the proxy.
- Includes everything in v0.32.2 (superseded before its
  separate public publish).

## v0.32.2 — 2026-10-24

- Honey badger mascot across the project: master artwork
  plus derived resolutions (1024–16 px) and a multi-size
  favicon.ico under docs/badger/ (generator:
  scripts/render-badger.py). Wired into the GitHub social
  card, the Pages landing page (header image + favicons),
  the in-browser generator app (favicon set, apple-touch
  icon, og:image), the repo README, and the org profile.
  GitHub org/repo avatar upload stays a manual step from
  docs/badger/honey-badger-512.png (no API for avatars).
- Includes everything in v0.32.1 (superseded before its
  separate public publish).

## v0.32.1 — 2026-10-24

- Browser-examples index is now covered in all three
  engines: `test-browser-examples` (new in `make test`)
  drives the newcomer page's own signaling flow for all
  nine Wasm languages in Chromium, Firefox, and WebKit —
  9/9 in each. Previously verified in Chromium only.
- npm publishing future-proofing: the export ships a
  manually dispatched Trusted Publishing workflow
  (`.github/workflows/publish-npm.yml`, OIDC + provenance,
  no stored token) plus maintainer doc NPM-PUBLISHING.md.
  One-time Trusted Publisher setup on npmjs.com remains;
  the local token path stays active until npm retires
  token-based direct publishing in January 2027.
- Includes everything in v0.32.0 (superseded before its
  separate public publish).

## v0.32.0 — 2026-10-24

- Plugin distribution: three install channels for the same
  dependency-free protoc plugins (protoc + Node.js 18+;
  see PLUGINS.md). (1) Every GitHub Release now carries a
  self-contained `grpc-dc-<version>.zip` plus `SHA256SUMS`
  (bin/ wrappers + plugin runtime; runs in place after
  unzip). (2) The `grpc-dc` npm package ships all 23 plugins
  as bin entries (`node_modules/.bin/protoc-gen-grpc-dc-*`).
  (3) A `ghcr.io/browser-grpc/protoc-plugins` container image
  (per-version tag + `latest`) with protoc and all plugins
  preinstalled on PATH — no host Node needed. All three
  channels verified against `proto/echo.proto` before
  release (zip: Go stubs; npm: Rust stubs; container:
  Python stubs).
- Includes everything in v0.31.1 (superseded before its
  separate public publish).

## v0.31.1 — 2026-10-24

- Browser examples work from a public clone: the export
  now ships the prebuilt Wasm client bundles (~10 MB;
  `make artifacts` builds them in the private tree, and a
  missing bundle fails the release loudly). Verified
  clean-room from the exported tree: compose starter,
  compose browser-examples (9/9 languages in a real
  browser), and the tunnel-browser profile (9/9 through a
  live trycloudflare.com URL).
- All nine Wasm languages are back in the browser-examples
  index, Lua included. The v0.31.0 exclusion misdiagnosed
  the cause: Lua's native client runs the deep BDD
  scenarios (failure/metadata/cancel/deadline), and the
  generated starter/browser servers only implemented the
  happy-path Echo. Both generated servers now implement
  the canonical Echo semantics; the Lua run settles and
  the index passes 9/9.
- Demo profile fixed: `demo-go`, `demo-python`, and
  `demo-rust` ran stdio interop harnesses with no driver
  attached (they block on stdin by design). They now run
  each language's loopback suite and print its transcript.

## v0.31.0 — 2026-10-24

- Browser examples are now Docker- and tunnel-powered:
  `docker compose --profile starter up` runs the
  browser<->Node starter; `--profile tunnel` puts it (or,
  with `--profile tunnel-browser`, the examples index) on a
  public trycloudflare.com URL. The starter and examples
  pages now pick `wss://` on HTTPS pages — the tunnel
  walkthrough caught the insecure-WebSocket failure the
  localhost path could not.
- Echo in every browser language: `examples/browser/`
  (generated) serves the Wasm client pages for Go, Zig, C++,
  Swift, Kotlin, Dart, Rust, and Scala.js against the Node
  stack server with WebSocket signaling. Verified 8/8 in a
  real Chromium page. Lua is excluded from the index for
  now: its native Wasm client hits a startup race in this
  server shape (the same page passes in the BDD harness,
  which still covers Lua in the browser).
- Native demo profile: `docker compose --profile demo run
  demo-go|demo-python|demo-rust|demo-js` runs a language's
  Echo server+client pair and prints the transcript, for
  poking a running service instead of only a green suite.
- compose `tunnel` now targets the starter; the previous
  static-site tunnel remains as `tunnel-app`.

## v0.30.0 — 2026-10-23

- One-command JS starter: `node examples/starter/server.mjs`,
  open http://localhost:8080/, press Run. A browser gRPC client
  talks to the generated Echo service on the in-repo Node
  WebRTC stack; WebSocket signaling (SDP text only, tiny
  dependency-free RFC 6455 shim) is included, so nothing needs
  installing and no test files need reading. Generated from
  the same metaprogram; verified in a real Chromium page
  (unary, server-stream ticks, bidi echo). Linked from
  QUICKSTART step 2.
- Clarity regression gate in the exporter: the release now
  fails if user-facing exported text references generator-
  internal source paths; provenance files are allowlisted.
  The v0.29.1 scrub can no longer silently regress.
- Troubleshooting page (`docs/TROUBLESHOOTING.md`, linked
  from the README): secure context, signaling choices,
  TURN/NAT, WebKit fallback generators, which transport plugs
  into `Channel`, and the silent-hang checklist.

## v0.29.1 — 2026-10-23

- Newcomer clarity scrub: published output no longer leads
  with the implementation language. Generated-file headers
  now read `@generated by grpc-dc codegen` instead of naming
  generator source paths that do not exist in the public
  tree; runtime/spec/test prose drops generator-internal
  file references; the web app says "plugin runtime" /
  "full plugins in-browser" instead of naming its in-browser
  plugin implementation, and the zip README/manifest wording
  matches. Provenance stays where it belongs:
  GENERATED-CODE-LICENSE.md, SPEC.md/SPEC-WEBRTC.md, and
  RELEASE.json. No wire, API, or behavior change; the full
  suite is green (interop 225/225, webrtc matrix 20/20).

## v0.29.0 — 2026-10-23

- QUICKSTART step 2 is now runnable as published:
  `node browser-test/native_step2.mjs [chromium|firefox|webkit]`
  pairs a real browser gRPC client with the native stack
  Echo server (SDP as plain text; swap in your own signaling).
  Verified in all three engines. The sample is exported
  individually from the otherwise-private browser-test tree.
- WebKit joins `all` mode for the nine core browser
  DataChannel suites (test, bdd, go_server, browser_server,
  dtls_server, turn, trickle, close, restart), so the
  container gate now covers Chromium/Firefox/WebKit.
  Enabling it exposed a latent cross-engine hang: suites
  sharing one signaling file base consumed a previous
  engine's answer file in `all` mode. go_server and
  browser_server now use a fresh signal base per engine.
  All nine suites pass in all three engines.
- A Playwright-recorded GIF of the guided first run
  (`docs/first-run.gif`, ~120 KB) now sits above the fold in
  the generated README and the Pages landing page; the npm
  publish path is live (host authenticated as `unicomp21`;
  OTP for 2FA is handled as a reported follow-up, never a
  blocked GitHub release).

## v0.28.0 — 2026-10-23

- Newcomer onboarding for the public export: generated
  `QUICKSTART.md` (first browser RPC in ~5 lines, Docker
  client/server pair, stubs for your own `.proto`), generated
  per-language `README.md` files (first run, regenerate,
  project use), an HTML examples gallery with per-language
  anchors (`docs/gallery.html`, linked from the README table
  and landing page), and curated deep links (JS browser
  client, Go client, Python messages, shop schema).
- Live app guided first run: "Run your first RPC" generates
  the Echo client in-page, serves it over a loopback
  DataChannel pair, and runs unary + streaming calls with the
  equivalent ~10 lines of code shown. Real calls, no mocks.
- Package-manager story: the npm package `grpc-dc` now carries
  keyword metadata, homepage/repository, and an aligned
  version per release; `scripts/release-push.sh` dry-runs and
  (when logged in) publishes it during the publish window.
  Python gets a generated `pyproject.toml`, so
  `pip install ./python` installs `grpcdc`.
- TypeScript declarations ship for the JS runtime
  (`js/index.d.ts`, wired through package `types`/exports and
  verified with `tsc --strict`): Channel/Server/Endpoint,
  dynamic client, and Wasm bridges are typed.
- README badges (release, license, live generator, npm) and
  a 1280x640 social preview card (`docs/social-preview.png`,
  rendered by `scripts/render-social.py`), referenced from
  the landing page's Open Graph image.

## v0.27.1 — 2026-10-23

- GitHub/Pages discoverability for web and browser developers:
  the Pages landing page gains a keyword title ("gRPC in the
  Browser over WebRTC DataChannels"), meta description, Open
  Graph/Twitter cards, canonical URL, schema.org JSON-LD, a
  "Why DataChannels?" section, and `robots.txt`/`sitemap.xml`.
  The web app page gets matching title/description/OG metadata
  and a browser-first intro. The generated public README and
  org profile lead with "Run gRPC in the browser … no grpc-web
  proxy" plus the language/keyword surface, and
  `scripts/release-push.sh` now aligns the GitHub repo
  description, homepage, and an expanded topic set
  (grpc-web, rtcdatachannel, protobuf, protoc-plugin, wasm,
  browser, peer-to-peer, typescript, …) on every publish.

## v0.27.0 — 2026-10-23

- SCTP flow-control fix (Rust/Go/JS): `send_data` now queues
  when the peer receive window is full instead of sending past
  `rwnd`; SACK processing flushes the queue as window frees.
  Sending past the window burst megabytes into kernel buffers
  that dropped most of it, throttling associations to ~1s RTO
  retransmits. `bench-mux` blast (2000×1KiB) improves
  973→~2700 msgs/s (1.0→2.6 MiB/s) and post-blast ping-pong
  RTT recovers 11.9→2.6 ms.
- Endpoint pump (Rust): receive slice 5ms→1ms and all queued
  inbound packets are drained per iteration. Loopback
  ping-pong mean RTT improves 19.2→2.7 ms.
- WebKit OPFS fallback (web app): when the Racket/Wasm worker
  fails to boot (WPE WebKit fails the runtime's OPFS home
  mount), `app.js` now times out the boot (30s), terminates
  the worker, and falls back to the built-in generators
  instead of hanging Generate forever. `webapp_parity` and
  `webapp_pb` run in WebKit via that fallback with all stubs
  still byte-compared against native plugins, and WebKit
  joins their `all` mode under `GRPC_DC_WEBKIT`. The fallback
  also exposed a real parity bug, fixed in `racket/webgen.rkt`:
  the browser Python emitter ignored `trace=hooks` (missing
  `set_tracer`/`set_trace_filter` re-exports).

## v0.26.0 — 2026-10-23

- Cross-browser Playwright matrix: every browser-test engine
  dispatch (45 files) now also accepts WebKit. Chromium-only
  launch flags are stripped for WebKit (MiniBrowser rejects
  `--no-sandbox`). In `all` mode WebKit runs where
  `GRPC_DC_WEBKIT` is set — `Dockerfile.ci` installs WebKit
  and sets it, so the container gate covers Chromium, Firefox,
  and WebKit; host runs without WebKit libraries are
  unchanged. Verified in WebKit: native DataChannel gRPC,
  BDD, TURN/direct/trickle/close/restart, Go/browser/DTLS
  servers, the Wasm client suites and matrix, and the webapp
  browse test (23 languages). Known limitation, recorded in
  the tests: `webapp_parity`/`webapp_pb` stay explicit-only
  for WebKit because the in-browser Racket runtime's OPFS
  home mount fails in WPE WebKit (worker posts `ready`, then
  an OPFS `UnknownError`), so Generate never completes.
- Release gate: the README release checklist now requires
  `make test-stress-ports` before tagging.
- Mux benchmark: `make bench-mux` (`mux_bench` Rust example)
  reports handshake rate, blast throughput, and ping-pong
  RTT for pairs on one `PeerMux` socket. Baseline on the
  dev host: 8.1 pairs/s, 1013 msgs/s (1.0 MiB/s) echo blast
  at 1 KiB, 19.2 ms mean RTT (polling-bound; a latency
  baseline, not a target).

## v0.25.2 — 2026-10-23

- Parallel UDP port-collision stress (`make test-stress-ports`,
  `scripts/stress_ports.py`): N copies (default 3) of each
  collision-prone suite — Rust mux/CID/TURN/OpenSSL/direct,
  Go mux/TURN/direct/DTLS under `-race`, JS mux/TURN-mux/
  DTLS/DC/coturn, and the cross-stack webrtc matrix — run
  concurrently per suite; any `EADDRINUSE` / "address already
  in use" in any copy fails the run. Passes at N=3 (repeated)
  and N=4 with zero collisions. Rust copies run with
  `--test-threads=2` to bound CPU oversubscription, and the
  `webrtc_direct` echo deadlines rise 15s→60s so cross-copy
  contention measures ports, not scheduler noise.

## v0.25.1 — 2026-10-23

- UDP port-allocation hardening (tests and harnesses): the
  echo harnesses (Rust/Go/JS `dtls_echo`, `dc_echo`) now bind
  ephemeral ports themselves and report the allocated port in
  their `LISTENING` line, and their fallback default ports
  (4443/4444) are gone — consumers read the allocated port
  instead of probe-close-rebinding a guessed one. External
  daemons that require a numeric port (openssl `s_server`,
  coturn) keep the unavoidable probe-close step, now always
  wrapped in startup-liveness verification with retry on a
  fresh port (Rust `spawn_coturn`/`spawn_coturn_turns`, Go
  `spawnCoturn`, JS `startCoturn`, JS openssl startup). No
  unjustified hardcoded UDP ports remain in tests or
  harnesses; protocol-fixed ports (mDNS 5353) are unchanged.
  Repeated runs of the collision-prone suites (Rust
  dtls_openssl + webrtc_direct ×3, JS dtls/dc/coturn ×3,
  webrtc matrix ×2) pass without EADDRINUSE flakes.

## v0.25.0 — 2026-10-23

- Cross-stack TURN × mux interop: the webrtc matrix gains
  six `turn-mux` cells pairing mux against mux across Rust,
  Go, and JS with both sides also allocating on one shared
  fake TURN server (deliberately unreachable host addresses,
  so only relayed pairs can connect). This proves the
  v0.24.0 composition — dedicated per-peer TURN sockets plus
  DTLS connection-id demux — works across stacks, not just
  within each. The `peer_echo` mux harnesses take an
  optional TURN server argument, and the fake TURN server
  is also runnable standalone (`browser-test/fake_turnd.mjs`)
  so native harness processes and in-process JS peers share
  one allocation service. Matrix now reports 20/20 cells.

## v0.24.1 — 2026-10-23

- Browser app completeness fix: `kotlin-native` is now
  selectable alongside the other 22 generator targets in
  the published web app. Its Racket plugin is staged for
  the in-browser Racket/Wasm runner, its Kotlin/Native
  runtime is bundled into generated archives, and browser
  parity/browse coverage now exercises all 23 targets.
  The native published plugin already covered
  `kotlin-native` in v0.23.0; this release closes the
  browser-UI gap.

## v0.24.0 — 2026-10-23

- Cross-stack mux-to-mux interop: the webrtc matrix now
  pairs `PeerMux` against `PeerMux` across Rust, Go, and JS
  (six cells; the `peer_echo` harnesses gained mux modes) —
  the DTLS connection-id wire profile (record layout, AAD,
  fixed 10-byte mux CIDs, `DcPairHint` first flight) is
  proven byte-compatible across all three stacks, not just
  within each. Matrix now reports 14/14 cells.
- TURN on muxed peers (all three stacks): an allocation
  pins a concrete 5-tuple, so a muxed peer's TURN leg (UDP
  transport) rides a dedicated per-peer socket bound at
  allocate time; TURN traffic never touches the shared
  socket, and all existing TURN machinery (permissions,
  channel bindings, refreshers, consent, restarts) is
  reused unchanged. TCP/TLS TURN rides its own stream as
  before. New relay-only mux-to-mux tests in Rust, Go, and
  JS (fake TURN, deliberately unreachable host addresses,
  two concurrent pairs per mux).
- Docs: `SPEC-WEBRTC.md` now specifies the mux/CID profile
  (routing order, CID allocation, `DcPairHint`), and the
  generated public README's PeerMux section no longer
  claims source-address routing or missing TURN.
- `make test` fully green (exit 0, webrtc matrix 14/14,
  interop matrix 225/225), `make check-generated`
  byte-stable.

## v0.23.0 — 2026-10-22

- DTLS connection IDs (RFC 9146) in all three native WebRTC
  stacks (Rust, Go, JS/Node): a muxed endpoint announces a
  connection id in the handshake, subsequent records carry
  it after the epoch/sequence (and inside the AEAD AAD),
  and `PeerMux` routes by exact cid lookup — two muxes can
  now peer with each other (mux-to-mux), and NAT rebinding
  no longer strands DTLS records. Peers that ignore the
  extension (browsers) keep the plain record layout. A
  private `DcPairHint` extension carries the remote ICE
  ufrag on the first ClientHello so the first flight also
  routes on a shared socket.
- Mux routing fixes in all three stacks: username-less STUN
  Binding Successes are offered to every endpoint (each
  agent consumes only its own integrity-checked
  transaction) — learned-source routing made mux-to-mux
  ICE nomination racy — and the Go/JS mux ClientHello hint
  parsers had an off-by-one in the handshake header walk
  (8 bytes after the length field, not 9) that misrouted
  first flights.
- The Node protoc plugin now covers all 23 generator
  languages: a `kotlin-native` emitter joins the
  generated-JS emitters (wasm-mode Kotlin template: no
  CompletableFuture/async surface, `Long`-nanosecond
  timeouts, `grpcdc.EOFException`), byte-parity-tested
  against the Racket plugin through real protoc.
- Direct connection-id echo tests in all three stacks
  (Rust `cid_test.rs`, Go `cid_test.go`, JS `cid.test.js`);
  the generated two-pairs mux-to-mux scenario passes in
  Rust, Go, and JS.
- `make test` fully green (exit 0, webrtc matrix 8/8),
  `make check-generated` byte-stable, no_std builds pass.

## v0.22.0 — 2026-10-22

- Publishable protoc plugins with no Racket required:
  `webapp/protoc-gen-grpc-dc.mjs` is a dependency-free Node
  plugin driving the same generated-JS emitters as the
  browser app; a parity test runs real protoc both ways and
  requires byte-identical output for all 22 generator
  languages. The public export ships it plus per-language
  `bin/protoc-gen-grpc-dc-*` wrappers — so the public
  per-language Docker images re-enabled their protoc-driven
  tests (`TestBddSchemas`, `TestPbMessages`) and all 16
  images again run those suites green; only cross-language
  sidecar cases stay private. The one Racket-only plugin
  remaining is `kotlin-native`.
- Single-socket serving: `PeerMux` hosts many signaled
  peers on one UDP socket in all three native stacks
  (Rust, Go, JS/Node), via a small datagram seam per stack
  (STUN by ufrag, DTLS by learned source; TURN unavailable
  on muxed peers). The parity scenario is generated from
  `racket/mux-spec.rkt` by `racket/mux-gen.rkt` into all
  three stacks' test trees.
- The public export now also carries a trimmed browser
  test harness (`browser-test/`): `npm ci` +
  `node bdd.test.mjs all` replays the 16 BDD scenarios in
  real Chromium and Firefox from the clone, and the
  generated README documents PeerMux and the browser check.
- `make test` fully green (EXIT:0, webrtc matrix 8/8)
  including the mux tests in all three stacks.

## v0.21.0 — 2026-10-22

- Public export for the browser-grpc GitHub org, generated by
  `racket/releasegen.rkt` from a git allowlist (tracked files
  only) with a leak gate that fails the export if any Racket
  source crosses: `make release-public` builds the complete
  public tree (16 language dirs, gh-pages docs + browser app,
  RELEASE.json); `scripts/release-push.sh` is the separate,
  explicit publish step.
- New-user tranche, all generated from the same Racket
  tables: one Dockerfile per language (16) whose default
  command runs that language's test suite, a cross-language
  interop image (`interop matrix: 4/4 pairs passed`), a
  compose front door (docs app + `cloudflare/cloudflared`
  quick-tunnel profile for HTTPS on any device), webapp deep
  links (`#schema=<id>&lang=<id>`) and a starter-kit zip
  (stubs + examples + RUN.md), a gallery of the same Echo
  server in every language with captured stdio transcripts,
  and the org profile README.
- Swift is back in the public language table — it had drifted
  out of the releasegen allowlist while its Dockerfile still
  referenced it; all 16 public images now build and pass.
- Fix: data race in the generated Go runtime — the read loop,
  cancelStream, and failAll could send on a stream's event
  channel concurrently with its close (panic risk). Sends and
  the exactly-once terminal close are now serialized on a
  per-stream mutex in `racket/runtime-go.rkt`;
  `go test -race -count=5` is clean.
- IoT: `webrtc/rust/examples/iot_cable.rs` runs two
  bare-metal-style devices from power-on to a DataChannel
  echo over raw Ethernet (ARP, ICE, DTLS, SCTP — no sockets,
  no wall clock, no OS entropy) via the platform stub HAL;
  `make test-iot` gates it with the net-stack tests.
- Public per-language images disclose their one exclusion in
  the generated header: protoc-plugin cases (the plugins are
  Racket) and cross-language sidecar cases stay in the
  private suite, which is fully green (`make test` EXIT:0,
  webrtc matrix 8/8).

## v0.20.3 — 2026-10-22

- Dedicated Wasm server tests are deep now: a shared
  `browser-test/echo_deep_checks.mjs` drives failure,
  metadata, and unknown-method scenarios from the JS client
  against every Wasm Echo server (18 test files; incremental
  stream servers assert their two registered shapes). This
  caught real gaps — ClientStream (and in some impls
  ServerStream/Bidi) did not reject "fail" in the Go, Zig,
  C++, Swift, and Scala.js stream servers, the C++ and Zig
  facade servers, the Rust Wasm server, and the shared
  Dart/Lua example impls; all now reject canonically in
  every method.
- CI image layering, round 2: per-language source copies +
  warm builds (Rust, Go, C#, C++, Swift, Kotlin, Dart, Zig)
  now precede the catch-all `COPY . .` in `Dockerfile.ci`,
  and the rustup/wasm-bindgen toolchain moved pre-COPY, so
  a one-language change rebuilds only that language's warm
  layer plus the shared post-COPY steps.

## v0.20.2 — 2026-10-21

- CI image layering: the download-heavy toolchain warm-ups
  (scala-cli/bloop resolution, Maven oracle deps, Playwright
  browsers, the Racket/Wasm bootstrap) moved before
  `COPY . .` in `Dockerfile.ci`, staged on a few copied
  files, so ordinary source changes no longer bust their
  caches (previously every release rebuilt them from
  scratch, ~1h+).
- Kotlin facade incremental stream server now rejects
  "fail" in ClientStream/Bidi too, asserted by
  `browser-test/wasm_kotlin_stream_server.test.mjs` (status
  3). Calling the captured `fail` callback from inside the
  pull-loop lambda trips a Kotlin/Wasm illegal-cast fault;
  routing the invocation through a member helper
  (`SlowEchoStream.failIfFail`) avoids it. This closes the
  exception noted in v0.20.1.

## v0.20.1 — 2026-10-21

- Wasm matrix hardening: the hand-written Echo server impls
  for the Zig native, Kotlin native, and Kotlin facade Wasm
  servers now reject "fail" in every method (canonical
  semantics; previously only Unary rejected, so failed
  streaming calls completed with OK trailers and clients
  reported code 0). `browser-test/wasm_matrix.test.mjs` now
  asserts the deep failure/metadata/unknown-method/cancel/
  deadline codes for every client×server pair, not just the
  call-shape summary. (The Kotlin facade's incremental
  stream-server impl keeps its previous behavior: invoking
  its `fail` callback from the pull loop trips a Kotlin/Wasm
  "illegal cast" fault, so fail-injection is not wired there.)

## v0.20.0 — 2026-10-21

- Wasm BDD deepening: every Wasm client — the native runtimes
  (Rust, Dart, Zig, Lua, C++, Swift, Kotlin) and all six
  facades (Go, Zig, C++, Swift, Kotlin, Scala.js) — now
  executes the failure, metadata, unknown-method,
  cancellation, and deadline scenarios inside the Wasm module
  itself, asserted by `browser-test/bdd_wasm.test.mjs` against
  the generated table (all 13 manifest entries are `deep`).
  The JS Wasm bridge (`createGrpcDcBridge`, generated) now
  forwards per-call options: `{metadata, timeout}` on all
  shapes and `{cancelAfter: n}` to abort a stream after n
  responses; the Go facade bridge runtime exports
  options-aware helpers (`CallUnaryWithOptions`,
  `CallServerStreamCancelAfter`), and the Zig/C++/Swift
  facade bridges gain `js_unary_opts`/`js_server_stream_cancel`
  env imports, the Kotlin/Scala.js facade bridges
  options-aware unary and cancel-after server-stream helpers.

## v0.19.0 — 2026-10-21

- Browser/Wasm BDD coverage: `racket/bdd-gen.rkt` now also
  stamps the scenario table and a Wasm client manifest into
  `browser-test/` (`bdd_scenarios.generated.mjs`,
  `bdd_wasm_manifest.generated.mjs`). The JS browser client
  runs the full 16-scenario table in Chromium and Firefox over
  a native RTCDataChannel (`browser-test/bdd.test.mjs`, wired
  into `make test-browser`); every Wasm client (13 pages:
  native Rust/Dart/Zig/Lua/C++ runtimes and Go/Zig/C++/Swift/
  Kotlin/Scala.js facades) is asserted against expectations
  derived from the same generated table (`bdd_wasm.test.mjs`,
  wired into `make test-wasm-matrix`).
- Go generated map encoding is now deterministic: the Go
  emitter sorts map keys before encoding (matching the Lua,
  Rust, and Swift fixes in v0.18.0). Caught by a Docker-gate
  flake in `TestBddSchemas` where Go's randomized map iteration
  swapped two kitchen-sink entries.

## v0.18.0 — 2026-10-20

- BDD scenario coverage expanded in every language: the shared
  16-scenario table (from `racket/bdd-spec.rkt`) now includes
  server-stream failure, bidi failure, deadline-exceeded, and
  stream cancellation next to the original call shapes. The
  reference Echo contract -- `"fail"` is rejected in every
  method -- is now implemented by every language's Echo service.
- Protoc schema examples as BDD: `racket/bdd-schemas.rkt`
  stamps protoc's own --encode golden bytes (kitchen sink,
  three-level nesting, oneof last-one-wins, unknown-field
  retention, empty message) into every language; generated
  classes must decode and re-encode them byte-identically
  (`TestBddSchemas`). Writing this caught four real bugs:
  Rust generated code panicked decoding packed fixed32/float
  fields (4-byte chunks sliced into an 8-byte conversion; the
  generator now pads chunks, `template-rust.rkt`, `webgen.rkt`);
  Lua, Rust, and Swift map encoding was nondeterministic
  (generators now emit sorted map keys); Scala sign-extension
  for negative int32/enum now produces protoc-canonical
  10-byte varints.
- The same 16-scenario BDD table now also runs over the real
  WebRTC stack via the Rust `direct_sidecar` in three languages
  (`TestBddSidecar` / `test_bdd_sidecar.py`): Python, Go, and
  C++ each run every scenario, including failure, deadline, and
  cancellation, over DTLS/SCTP rather than loopback.
- Lossy and unordered datachannels are now exposed through the
  generated runtimes' Direct adapters: Rust
  (`direct_client_endpoint`, `accept_direct_endpoint`), Go
  (`DirectClientEndpoint`, `AcceptDirectEndpoint`), and JS
  (`directClientStackEndpoint`, `openDirectChannel`) return or
  use the raw endpoint so applications can open
  max-retransmits/max-lifetime and unordered channels next to
  the reliable ordered "grpc" channel. Documented in
  SPEC-WEBRTC.md ("Lossy and unordered channels").

## v0.17.0 — 2026-10-20

- RSA support in the homegrown TLS 1.2 client (`tls12.rs`):
  ClientHello now offers ECDHE-RSA-AES128-GCM-SHA256 and the
  `rsa_pkcs1_sha256/384` signature algorithms, RSA leaf
  certificates are accepted, and RSA ServerKeyExchange
  signatures verify with the existing PKCS#1 v1.5 code. The
  Rust TURNS coturn leg now uses an RSA certificate verified
  against a pinned root (no skip-verify), closing the interop
  gap where RSA-cert TURN servers -- the common case -- alerted
  the handshake. DTLS stays ECDSA by design (our certs are
  generated ECDSA and fingerprint-pinned).
- Generated JS (Node) WebRTC-Direct adapter:
  `src/webrtc_direct.js` (from `racket/runtime-js.rkt`) exports
  `directListener`, `acceptDirectEndpoint`,
  `directClientEndpoint`, and `directClientTurnEndpoint` over
  `webrtc/js/direct.js`, matching the Rust and Go generated
  adapters. `js/test/webrtc_direct.test.js` runs a generated
  Echo client/server by multiaddr.
- Sidecar multi-connection: `direct_sidecar` now bridges one
  thread per connection in both modes, so one listen sidecar
  and one dial sidecar carry concurrent Direct sessions.
  Proven by three concurrent Python clients
  (`python/tests/test_sidecar_multi.py`) and three concurrent
  Go clients (`TestSidecarMultiConnGo`).
- Housekeeping: Swift test warnings cleaned (zero warnings in
  `make test-swift`); DTLS/OpenSSL soak re-run -- 40/40 runs
  (200 cases) clean, which with the earlier 100 clean runs
  bounds the historical flake at roughly 2% (95% confidence).

## v0.16.0 — 2026-10-20

- Sidecar gRPC tests for the remaining languages: Kotlin,
  Scala, C#, Swift, C++, Zig, and C suites each run an Echo
  client and server through two Rust `direct_sidecar`
  processes (`TestSidecar OK`), joining Python, Go, Ruby, PHP,
  Dart, and Java from earlier releases. The C runtime gained
  `grpcdc_sidecar_from_fd` so a server can wrap the accepted
  socket. Lua joins via a host-provided socket (below), so
  every supported language can now call -- and serve -- through
  the Rust WebRTC-Direct stack.
- Concurrent Direct dialers: the Rust, JS, and Go
  `DirectListener`s now demultiplex their shared UDP socket by
  peer address (queued pending peers, one claim per Accept),
  so simultaneous handshakes against one listener no longer
  steal each other's packets. Proven by four concurrent dialers
  with distinct payloads in all three stacks. The Go and JS
  TURN fakes' ephemeral-relay-port fixes were matched in the
  Go fake.
- Direct over TURN past the allocation lifetime: Rust, JS, and
  Go tests run against fakes enforcing a 3 s allocation and
  permission lifetime and prove traffic still flows after 5 s.
  This caught a real bug: Go `DirectDialTurn` bypassed the
  peer-remembering helper, so its refresher never re-issued
  permissions; it now uses `turnAddPeer`.
- TURN/TLS (TURNS) and IPv6 coturn legs: Rust, JS, and Go each
  dial Direct through a private coturn over a TLS
  client<->server transport and over IPv6 (`[::1]` listener,
  relay, and multiaddr). The Rust and JS stacks gained
  `REQUESTED-ADDRESS-FAMILY` plumbing (error 440 without it),
  the Rust Direct TURN io now drains the stream inbox, the JS
  Direct peer writes stream frames like `Peer.turnWrite`, and
  Go `DirectDialTurn` picks a dual-stack socket for v6. The
  homegrown Rust TLS stack offers ECDHE-ECDSA only, so its
  coturn fixture uses an ECDSA cert.
- Lua host-provided sidecar transport: generated
  `grpcdc/sidecar_transport.lua` frames over a socket injected
  by the host application (pure Lua has no stdlib sockets).
  `lua/tests/host_socket.lua` is the test host (TCP bridged
  over FIFOs by a small helper), and `TestSidecar` runs Lua
  client and server through two sidecars.

## v0.15.0 — 2026-10-20

- Go WebRTC-Direct parity: `dcwebrtc` `direct.go`
  (certhash/multiaddr, listener, dial, dial over TURN reusing
  the Peer TURN demux) with the same test set as Rust/JS, plus
  generated-runtime adapter `grpcdc` direct helpers and a Go
  gRPC-over-Direct multiaddr test. The Go and JS fake TURN
  fixtures now deliver to direct (non-TURN) peers from the
  relay socket, like real TURN servers.
- Browser proof: `browser-test/direct_turn.test.mjs`
  (Playwright/Chromium) dials with relay-only ICE — the
  symmetric-NAT shape — and asserts the nominated pair is
  relay<->relay with the echo crossing it.
- Real TURN interop: coturn is installed in `Dockerfile.ci`;
  Rust and JS direct-over-TURN tests run against it (skipping
  when `turnserver` is absent).
- Generated `SidecarTransport` for Go, Ruby, PHP, Dart, Java,
  Kotlin, Scala, C#, Swift, C++, Zig, and C (Python shipped in
  v0.14.0), all from the Racket runtime sources; gRPC through
  two sidecars is tested in Go, Ruby, PHP, Dart, and Java.
  Lua remains the documented exception (no stdlib socket).

## v0.14.0 — 2026-10-20

- libp2p-style WebRTC-Direct: signaling-free client→server
  connections identified by certhash multiaddrs
  (`/ip4/.../udp/.../webrtc-direct/certhash/f...`). Rust
  `dc_webrtc::direct` (`DirectListener`, `direct_dial_multiaddr`,
  `direct_dial_turn_multiaddr`) and JS `webrtc/js/direct.js`
  (Node), with fixed DTLS roles and certificate pinning (wrong
  certhash fails the handshake), tested in both stacks.
- WebRTC-Direct over TURN: the dialer runs its whole DTLS/SCTP
  session inside a TURN allocation (permission + channel
  binding, background refresh) — the symmetric-NAT path; the
  listener needs no TURN awareness. Echo-tested against fake
  TURN servers in Rust and JS.
- Generator support (Racket): generated Rust runtime gains
  `grpc_dc::webrtc_direct` (`direct_listener`,
  `accept_direct_transport`, `direct_client`,
  `direct_client_turn`); generated Python runtime gains
  `grpcdc.SidecarTransport`.
- Rust `direct_sidecar` binary bridges one `grpc` datachannel
  to a local length-prefixed TCP socket (`dial`/`listen`
  modes), so every generated language can call the Rust Direct
  impl (proven Python↔Python through two sidecars).

## v0.13.0 — 2026-10-20

- `trace=hooks` stub baking in every language generator
  (registrar re-export/delegate plus `trace_methods` filter
  baked in where the language has a load-time idiom);
  JS/Wasm stubs remain the documented exception — they use
  the runtime entry-point exports. Hooks-mode stubs verified
  by generation plus per-language compile/syntax checks.
- Stack tracing parity: `ice.nominated`, `dtls.handshake`,
  `endpoint.ready` now emitted by all three WebRTC stacks
  (`setStackObserver` in JS and Go beside Rust's `trace`
  module), each with a committed event-sequence test.
- Docs: README parameter table covers `trace_methods` and
  points at the `tracing_demo`/`otlp_tracer` examples (also
  in the browser-browsable corpus).

## v0.12.0 — 2026-10-20

- WebRTC stack tracing: new `trace` module in dc-webrtc —
  `Peer::connect` emits `ice.nominated`, `dtls.handshake`
  (full/resumed), and `endpoint.ready` to a registered
  synchronous observer, same dormant dependency-free hook
  shape as the gRPC runtimes; observer panics are caught.
- IPv6 completion: DHCPv6 client (SOLICIT/ADVERTISE/REQUEST/
  REPLY with IA_NA + DNS, renew at half valid lifetime, drop
  at expiry) and RA origination (`send_router_advertisement`)
  beside RA consumption, so `IpStack6` covers host and router
  roles.
- Per-method tracing filter in every generated runtime:
  `set_trace_filter` (`;`-separated paths, trailing `*` =
  prefix) plus the `trace_methods=` protoc plugin parameter
  (requires `trace=hooks`; validated, baked into Python
  stubs). Committed tests in Python and JS.
- TURN over IPv6: `TurnServerConfig::request_ipv6_relay`
  sends REQUESTED-ADDRESS-FAMILY (constant stamped from
  `webrtc-spec.rkt` into Rust/JS/Go tables); end-to-end
  IPv6 relay connect test in the TURN suite.

## v0.11.1 — 2026-10-20

- Deflake `dtls_openssl` (test harness only, no protocol
  changes): the ~10% failure rate traced to three harness
  bugs — both `s_server` tests raced cert generation in one
  shared pid-named temp dir (`key values mismatch` at
  startup), startup synced on fixed 500ms sleeps instead of
  the `ACCEPT` readiness signal, and `handshake_types` parsed
  encrypted epoch-1 records as plaintext (phantom Certificate
  flights). Unique cert dirs, readiness polling with captured
  openssl logs in panic messages, epoch-0-only type parsing.
  Baseline 2/20 failing → 100/100 host runs and 20/20 Docker
  `test-webrtc-rust` runs clean (95% upper bound ~3%).

## v0.11.0 — 2026-10-20

- Tracing follow-through: printing-observer demos
  (`tracing_demo` in Python and JS) and an OTLP/JSON exporter
  observer (`otlp_tracer` in Python and JS) as examples — the
  runtimes stay dependency-free; the exporter batches ended
  spans to a collector with stdlib/platform fetch only and
  swallows export failures. Browser generator gains a
  per-language `trace` select feeding the `trace=` parameter.
- Net stack: DHCP lease timers driven from `DhcpClient::tick`
  (renew at T1 = 50%, rebind at T2 = 87.5%, drop at expiry,
  ACK re-arms); IPv6 Router Solicitation/Advertisement (RA
  installs/withdraws the default router, on-link prefix info),
  opt-in IPv6 forwarding with hop-limit decrement and
  pending-forward queueing; `EthernetCable::endpoint6` runs
  ICE nomination over IPv6/NDP (cable now delivers Ethernet
  multicast).
- DTLS resumption interop completed in both directions:
  `openssl_client_ticket_resumption` (`s_client -sess_in`
  against our server). Fixes along the way: `NewSessionTicket`
  now issued at epoch 0 before CCS with the `session_ticket`
  extension echoed in the full `ServerHello`; resumed hellos
  echo the client session id (the resumption signal) and omit
  the ticket extension; no post-handshake ticket rotation
  (OpenSSL rejects it and it poisoned the data path); clients
  offer a random session id when resuming and keep the
  presented session when no rotation follows. The `dtls_echo`
  example gained a `server <port> resume` mode.

## v0.10.0 — 2026-10-19

- Homegrown tracing (all runtimes + browser JS core): W3C
  `traceparent` propagation through HEADERS with a synchronous
  span-observer hook (`set_tracer`/`setTracer`/`SetTracer`/
  `grpcdc_set_tracer`), dormant until registered — no new
  dependencies, unchanged wire when off. Client spans end at
  trailers/RST/deadline; server spans wrap dispatch.
- Protoc plugins accept `trace=off|hooks` (other values are a
  plugin error); `hooks` re-exports the registrar from Python
  stubs. Spec and README document the contract; Python and JS
  tracing suites cover propagation, continuation, error status,
  and dormancy.

## v0.9.0 — 2026-10-19

- Net stack: IPv4 gateway routing (longest-prefix route table,
  gateway next hops, opt-in forwarding with TTL decrement),
  DHCP lease renewal (`DhcpClient::renew_frame`), and ARP/NDP
  cache expiry on `IpStack::tick`.
- Net stack: IPv6 beside IPv4 — `IpStack6` with NDP neighbour
  discovery, ICMPv6 echo, UDP/IPv6 pseudo-header checksums,
  SLAAC-style EUI-64 addresses (`link_local_addr`, `slaac_addr`),
  and default-router next hops.
- DTLS: fixed NewSessionTicket capture against real servers
  (the ticket precedes the server Finished; the handshake pump
  now stashes it instead of discarding it), added
  `Dtls::was_resumed` and `Dtls::close` (close_notify), and an
  OpenSSL ticket-resumption interop test.

## v0.8.0 — 2026-10-19

- Peer-level DTLS session resumption (`PeerConfig` session
  fields, `DcEndpoint::take_dtls_session`).
- DHCPv4 client and raw Ethernet cable endpoint; bare-metal
  Cortex-M (thumbv7em) build gate.
- Webapp Browse: current editor schema view.
- Docs: embedded profile in SPEC-WEBRTC, README catch-up.

## v0.7.0 — 2026-10-19

- Webapp: Browse generated code mode with per-language
  corpus index (generated `corpus-manifest.json`, copied assets).

## v0.6.0 — 2026-10-19

- DTLS session tickets/resumption with pluggable crypto
  backend (`CryptoBackend`), sealed peer identity in tickets.
- Headless serial/BLE-style signaling and sleep/wake harness.
- Embedded WebRTC core: platform layer (clock/RNG/transport),
  hand-rolled Ethernet/ARP/IPv4/UDP stack, no_std port.
- C coverage parity: generated BDD, oracle, and dynamic drivers.

## v0.5.0 — 2026-10-19

- C99 as the sixteenth language (generated runtime, descriptor-
  driven dynamic mode, BDD/oracle/dynamic test drivers).
- Embedded gates: cross-compile checks and `rust_no_std` profile.
- Browser fallback and webapp coverage for C.

## v0.4.0 — 2026-10-19

- Browser fallback: generated message types for every language,
  byte-identical to the native plugins.

## v0.3.0 — 2026-10-18

- Schema-shape matrix gate; generated Rust messages used
  everywhere; full browser fallback message parity.
- Encode-side oneof clearing and cross-file map helpers.

## v0.2.0 — 2026-10-18

- Presence, oneof, proto2 default, and unknown-field semantics
  across all generated message runtimes.
- In-browser preview of the generated JS bundle; zip
  completeness checks in the web app.

## v0.1.0 — 2026-10-17

- Initial release: gRPC over WebRTC DataChannels with runtimes
  generated by recursive Racket metaprogramming for 15 native
  languages plus browser clients; hand-rolled dependency-free
  WebRTC stack (ICE/DTLS/SCTP/SDP) in Rust; TCP<->DataChannel
  oracle proxy for testing against reference gRPC; generated
  tests, examples, and docs from a single Racket source of truth.
