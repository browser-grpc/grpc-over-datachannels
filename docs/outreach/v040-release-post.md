# v0.40.0 release post — prepared 2026-11-09 for publication

Status: v0.40.0 is live (GitHub / npm / PyPI / GHCR / NuGet /
Maven Central / GitHub Maven / pub.dev / crates.io / LuaRocks /
JSR; RubyGems grpc-dc + kafka-grpc; the eventbus-grpc gem is
still propagating — link only what is verified below).

Links:
- Release: https://github.com/browser-grpc/grpc-over-datachannels/releases/tag/v0.40.0
- Repo: https://github.com/browser-grpc/grpc-over-datachannels
- Generator app: https://browser-grpc.github.io/grpc-over-datachannels/app/
- npm: https://www.npmjs.com/package/grpc-dc (kafka-grpc, eventbus-grpc)
- crates.io: https://crates.io/crates/grpc-dc (kafka-grpc)
- pub.dev: https://pub.dev/packages/grpc_dc (kafka_grpc, eventbus_grpc)
- NuGet: https://www.nuget.org/packages/GrpcDc (KafkaGrpc, EventBusGrpc)

---

## dev.to article (primary, long form)

Title: **gRPC over DataChannels 0.40.0: distributed tracing (beta), a Rust TCP proxy, and a browser-safe SCTP**

Tags: grpc, webrtc, rust, webdev

Body:

0.40.0 of grpc-over-datachannels is out. The headline is
distributed tracing (beta) that works the same way in every
generated runtime — 15 native languages plus the browser —
but the release also carries an SCTP delivery overhaul and a
measurement about browser packet sizes that changed how every
stack in the project sends data.

### Tracing that follows the call

Register a span observer and every generated client and
server emits spans with durations and the W3C sampled flag.
Unsampled trace contexts still propagate — they just don't
record. The part that matters in practice: nested calls
parent automatically. When a handler makes its own outbound
gRPC call, that call joins the inbound trace with no manual
context plumbing (ambient context on native runtimes,
explicit trace-context binding in the browser). A
client-originated call starts a root span when there is no
parent, and the TCP/DataChannel proxy emits its own span for
proxied calls, so a trace survives the hop from a stock
HTTP/2 client into a DataChannel service.

Every language ships a TRACING.md next to its TESTS.md, and
the test suites assert the full client/server parent chain —
including the Wasm matrix, which pairs native and facade
browser runtimes in both directions and checks that server
spans parent to client spans in the same trace. Two real
bugs fell out of that coverage: span-id seeding that trapped
on `wasm32-unknown-unknown`, and a Lua span clock that broke
in hosts without the `os` library. Both are fixed and now
covered by checks that run against the published packages.

It's designated beta behind one central flag in the
generator; the runtime stays dormant until your application
registers a tracer.

### The 2048-byte wall

While adding large-message legs to the browser matrix, we
found something worth sharing: Chromium silently drops SCTP
packets larger than 2048 bytes. A 2028-byte packet was acked;
a 2128-byte packet was retransmitted forever — no error, no
close, just a call that never completes. Chromium's own
outgoing datagrams top out around 1225 bytes.

Our three hand-rolled SCTP stacks (Rust, Go, JS) now
fragment at 1152-byte payloads: one chunk per packet, the
whole packet comfortably inside the datagrams browsers
themselves emit, and no IP fragmentation on real network
paths. Receivers were always size-agnostic; this is purely a
sender-side budget, and it's now enforced everywhere with
the measurement recorded in the code.

Alongside that, all three stacks gained RTT-measured
retransmit timers (SRTT/RTTVAR feeding the RTO, replacing a
fixed 1-second recovery), O(1)-amortized reassembly, and a
truthful advertised receive window that shrinks for
gap-buffered data. The proxy stress leg grew to 8 MB; the
browser matrix now pushes 192 KiB unary calls (just under
the RTCDataChannel single-message cap) through 20/20 runtime
pairs in Chromium and Firefox. A paced throughput bench
(`make bench-throughput`) baselines our JS stack against
Chromium's native one.

### Also in 0.40.0

- A dependency-free Rust TCP/DataChannel proxy in both
  directions: stock HTTP/2 clients call a grpc-dc server,
  grpc-dc clients call a stock HTTP/2 backend, TLS on both
  sides, compression terminated in the proxy. A new
  malformed-input corpus for the JS ingress proxy (garbage
  prefaces, truncated frames, gzip bombs, mid-message
  resets) found and fixed a status-mapping bug.
- Embedded: the raw-Ethernet Echo proof now fragments a
  10 KiB call across ~7 Ethernet frames each way and streams
  over the no-IP transport.
- Fresh-consumer gates run against the published packages
  (npm kafka-grpc shown here), so packaging regressions get
  caught outside the repo.

Packages for this release are live on npm (grpc-dc,
kafka-grpc, eventbus-grpc), crates.io, pub.dev, NuGet,
Maven Central, LuaRocks, and JSR, with generated runtimes
for Rust, Go, JS, Python, Java, C#, C++, Swift, Kotlin,
Dart, Zig, Lua, Ruby, PHP, Scala, and C. If you try the
tracing beta, we'd like to hear where the model chafes —
it's the last big surface we expect to iterate on before
calling it stable.

---

## Blogger version (c100k.blogspot.com)

Title: gRPC over DataChannels 0.40.0: tracing (beta), Rust proxy, browser-safe SCTP

Reuse the dev.to body with HTML formatting; canonical links
to the GitHub release and package pages above.
