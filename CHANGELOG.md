# Changelog

All notable changes to grpc-over-datachannels. Versions are
curated release tags on `master`; dates are the tag dates.

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
