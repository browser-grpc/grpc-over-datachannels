# v0.43.0 release post — prepared 2026-11-16 for publication

Status: v0.43.0 is live and verified on GitHub / npm / PyPI /
pub.dev / crates.io / GHCR / NuGet / Maven Central / GitHub
Maven / RubyGems / LuaRocks / JSR, plus GitHub Packages
npm/NuGet/RubyGems mirrors. Link only what is verified below.

Links:
- Release: https://github.com/browser-grpc/grpc-over-datachannels/releases/tag/v0.43.0
- Repo: https://github.com/browser-grpc/grpc-over-datachannels
- Generator app: https://browser-grpc.github.io/grpc-over-datachannels/app/
- npm: https://www.npmjs.com/package/grpc-dc (kafka-grpc, eventbus-grpc)
- crates.io: https://crates.io/crates/grpc-dc (kafka-grpc, eventbus-grpc, kafka-native)
- pub.dev: https://pub.dev/packages/grpc_dc (kafka_grpc, eventbus_grpc)
- NuGet: https://www.nuget.org/packages/GrpcDc (KafkaGrpc, EventBusGrpc)
- Issue #2 (host/plugin request): https://github.com/browser-grpc/grpc-over-datachannels/issues/2

---

## dev.to article (primary, long form)

Title: **gRPC over DataChannels 0.43.0: host/plugin support and packet-loss instrumentation**

Tags: grpc, webrtc, rust, webdev

Body:

0.43.0 of grpc-over-datachannels is out. Two headline
features: a host/plugin model that lets one public endpoint
serve out-of-process plugins (a community request, issue
#2), and unified packet-loss instrumentation that follows a
call across the SCTP, TCP, and HTTP/2 legs of its path.

### One endpoint, many plugin processes

The request was simple to state: expose one grpc-dc
endpoint, and let independent processes register services
on it at runtime, without recompiling the host. 0.43.0
builds that from pieces the runtimes already had:

- **IPC transports.** The Rust, JS, and Go runtimes speak
  one length-prefixed framing over stdio and Unix domain
  sockets, so a plugin is just a grpc-dc server whose
  transport is a pipe instead of a DataChannel.
- **Runtime registration.** Servers can register and
  unregister services after `serve()` starts, in all three
  runtimes — a plugin connecting is a registration, a
  plugin exiting is an unregistration.
- **Interceptor chains.** Server interceptors compose in
  order; the rendezvous auth check from 0.42.0 is the
  built-in first interceptor. JS interceptors can supply
  verified claims to handlers; Go interceptors can replace
  the call context.
- **DC-to-DC routing.** A host forwards by path prefix
  (`route_prefix`), so `/my.PluginService/` can live in
  another process — or behind another DataChannel — while
  everything else stays local.
- **Discovery.** The well-known `grpcdc.registry.v1.Registry`
  service lists registered services and returns their
  descriptors, so dynamic clients can call plugin services
  with no codegen.

The reference deployment is `examples/plugin-host`: a Rust
host with a Node plugin process. Plugin lifecycle (spawn,
restart, upgrade) deliberately stays the host
application's job — the runtime provides the seams, not a
process manager. SPEC.md documents the model.

### Packet loss, measured on every leg

DataChannels don't lose packets the way TCP does — SCTP
retransmits inside the association — so "is my call slow
because of loss?" previously had no answer from the
runtime. Now every SCTP association reports
`AssociationStats`: packets and chunks sent/received,
retransmits split fast vs timeout, duplicates received.
One `LinkStats` snapshot unifies that with the TCP leg
(wire-level counters from the smoltcp sidecar) and the
HTTP/2 leg (frames, streams, flow-control stalls), all
mirroring the same field shape the generated stats types
already used. A live gate exercises all three legs of one
call and asserts the counters move.

### Also in 0.43.0

- Rendezvous coverage grew teeth: TURN through a real
  coturn and STUN browser legs against the Go listener,
  rendezvous over IPv6, browser auth against Go and Rust
  servers, and adversarial listener tests (garbage input,
  12-peer demux). One finding for coturn users: loopback
  listeners also need `--allow-loopback-peers`, or relay
  candidates silently never work (issue #1, a config fix,
  now regression-tested).
- Kafka differentials now run in five languages (Python,
  JS, Go, Dart, C#): transactional produce through one form
  factor, read-committed consume through the other.
- Crypto cross-checks against OpenSSL (P-256 both
  directions, P-384 ECDH, TLS 1.2 client handshake), and
  every export now ships CONTRIBUTING/SECURITY community
  files.

Packages for this release are live on npm (grpc-dc,
kafka-grpc, eventbus-grpc), PyPI, pub.dev, crates.io,
NuGet, Maven Central, RubyGems, LuaRocks, and JSR, with
GitHub Packages mirrors, and generated runtimes for Rust,
Go, JS, Python, Java, C#, C++, Swift, Kotlin, Dart, Zig,
Lua, Ruby, PHP, Scala, and C. If you build a plugin host,
we'd like to hear what lifecycle model you wrap around it —
that part is intentionally yours.

---

## Blogger version (c100k.blogspot.com)

Title: gRPC over DataChannels 0.43.0: host/plugin support and packet-loss instrumentation

Reuse the dev.to body with HTML formatting; canonical links
to the GitHub release and package pages above.
