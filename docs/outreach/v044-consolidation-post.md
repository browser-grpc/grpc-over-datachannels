# v0.44.0 consolidation post — prepared 2026-11-19, PUBLISHED

Status: v0.44.0 is live on GitHub / crates.io / npm /
pub.dev / NuGet / RubyGems / LuaRocks / JSR / PyPI /
GitHub Maven / GHCR, with all generated-repo CI green
(`make ci-status`). Maven Central sync is deferred to
its weekly slot.

Published 2026-11-19:
- dev.to: https://dev.to/unicomp21/one-webrtc-stack-sixteen-languages-deleting-the-mirrors-5g6f
- Blogger: https://c100k.blogspot.com/2026/11/grpc-over-datachannels-0440-one-webrtc.html
- Long video: https://youtu.be/YSIp5PQqn5Y
- Short (DTLS `undefined`): https://youtube.com/shorts/5h3poOgXM24
- Short (64-packet queue): https://youtube.com/shorts/17bs0wAyL-g

Links:
- Release: https://github.com/browser-grpc/grpc-over-datachannels/releases/tag/v0.44.0
- Repo: https://github.com/browser-grpc/grpc-over-datachannels
- Generator app: https://browser-grpc.github.io/grpc-over-datachannels/app/
- npm: https://www.npmjs.com/package/grpc-dc (kafka-grpc, eventbus-grpc)
- crates.io: https://crates.io/crates/grpc-dc (kafka-grpc, eventbus-grpc, kafka-native)
- Videos: https://www.youtube.com/@JohnDavis-jf3on

---

## dev.to article (primary, long form)

Title: **One WebRTC stack, sixteen languages: deleting the mirrors**

Tags: grpc, webrtc, rust, javascript

Body:

grpc-over-datachannels started the way most multi-language
projects do: one WebRTC stack (ICE, DTLS, SCTP) written in
Rust, then mirrored by hand into Go and JavaScript so each
native stack could run standalone. Three implementations
of the same protocols, kept in sync by discipline and a
conformance suite.

That discipline already failed once. In v0.32 a fragment
reassembly bug — fragments merged across a message
boundary — wedged ordered delivery in one stack while the
others were fine. The fix taught us the actual lesson: the
state machines that must not drift should not exist three
times. So 0.44.0 deletes two of them.

### Sans-io cores, two consumption shapes

The Rust stack was already mostly pump-driven: feed a
datagram in, get packets and events out, no sockets or
threads inside. We finished that extraction for all three
protocols:

- SCTP: `dc-sctp-ffi` (C ABI) + `dc-sctp-wasm`
- DTLS: the handshake lifted into a resumable flight
  machine (`DtlsHandshake`), `dc-dtls-ffi` + `dc-dtls-wasm`
- ICE: the agent turned out to be sans-io already;
  gathering/TURN/mDNS were always host-side. `dc-ice-ffi`
  + `dc-ice-wasm`

Go consumes the cores through cgo behind small seams
(`sctpAssoc`, `DtlsConn`, the `IceAgent` API). JavaScript
consumes the same cores compiled to Wasm. The browser
bridge and every generated facade language ride the same
Rust runtime. There is now exactly one SCTP, one DTLS,
and one ICE implementation in the project.

The honest cost: about 311 ns per delivered message
across the FFI versus 173 ns for the old mirrored Go
stack. We measured it, and we'd pay it again: it's the
price of one conformance-tested implementation instead of
three that can drift. Throughput on the echo path is
~8,300 messages/second at 0.36 ms mean RTT (mux_bench).

### Flipping the defaults found the bugs

The mirrors stayed as the default until every consumer
was wired. Flipping Go and JS to the Rust cores — then
deleting the mirrors — is where the interesting failures
lived:

- **The DTLS pump that died on `undefined`.** In the Wasm
  adapter, one non-application DTLS record (a session
  ticket) mapped Rust's `None` to JavaScript `undefined`,
  the receive check tested only for `null`, and every
  endpoint pump threw. Sequential tests passed; eight
  concurrent rendezvous dials killed all eight pumps.
- **The 64-packet queue.** Bursty MiB messages overflowed
  the peer's small DTLS demux queue; the drops became SCTP
  retransmit storms and truncated chunk echoes — but only
  on the (slightly slower) FFI path. The queue is 4096
  deep now, and there's a permanent queued tail-drop
  blast regression test in the Rust suite.
- **A registry test that raced itself.** Two client
  endpoints shared one in-memory transport and raced for
  frames; it hung for 9m56s in GitHub CI before timing
  out (that failure is what the current public CI red was
  sitting on). One transport pair per client; fixed.
- **Public CI archaeology.** The generated repos' Go,
  browser, and interop jobs each needed the cores built
  before use — three generator fixes, shipped as export
  fixups.

### Oracles without mirrors

Deleting a second implementation deletes your differential
oracle, so the conformance net is now mirror-free by
design: OpenSSL differentials for DTLS (`dtls_openssl`,
`crypto_openssl`), the shared SCTP vectors through every
surface, the ICE consent/trickle suites against the core,
and full Go + JS suites that only have the Rust path to
run on. `make ci-status` sweeps the generated repos'
CI in one command; it's all green on v0.44.0.

The mirrors totaled roughly 4,400 lines of Go and
JavaScript. What's left is one stack, maintained once,
spoken everywhere.

---

## Blogger version (c100k.blogspot.com)

Title: grpc-over-datachannels 0.44.0: one WebRTC stack, every language

0.44.0 deletes the mirrored Go and JavaScript WebRTC
stacks. The Rust ICE/DTLS/SCTP cores are now the only
implementations, consumed through C ABI (Go, natively)
and Wasm (JavaScript, browsers, and every generated
facade language).

Why: three hand-mirrored state machines can drift, and
ours did (the v0.32 reassembly wedge). The cores are
sans-io — pump-driven, no sockets inside — so the same
code runs in-process everywhere. Cost measured: ~311 ns
per message across the FFI vs 173 ns mirrored; worth it
for one conformance-tested stack. Echo path: ~8,300
msgs/s at 0.36 ms RTT.

Flipping the defaults flushed out three good bugs: a
Wasm DTLS pump killed by JavaScript `undefined`, a
64-deep demux queue turning burst loss into retransmit
storms, and a registry test racing two clients on one
transport (the 9m56s GitHub CI hang). All fixed, all
with regression tests.

Release: https://github.com/browser-grpc/grpc-over-datachannels/releases/tag/v0.44.0
Code: https://github.com/browser-grpc/grpc-over-datachannels
