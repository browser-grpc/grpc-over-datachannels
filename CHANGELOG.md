# Changelog

All notable changes to grpc-over-datachannels. Versions are
curated release tags on `master`; dates are the tag dates.

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
