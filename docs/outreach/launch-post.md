# Launch post — DRAFT, do not post without approval

Status: draft, updated 2026-11-01. Ready to post: v0.36.0 went
live early on Nov 1, 2026 (GitHub / npm / PyPI / GHCR / NuGet /
GitHub-hosted Maven), so every claim below maps to a tagged
release. Maven Central syncs separately in its weekly slot after
the Sonatype throttle expires Nov 29 — do not gate this post on
it. The gRPC walkthrough video was re-recorded Nov 1 (no
version/date commitments in the narration); the link below is
the current upload, and the original upload has been deleted.

Assets this post ties together:

- Code: https://github.com/browser-grpc/grpc-over-datachannels
- Kafka proxy: https://github.com/browser-grpc/kafka-proxy
- Event bus: https://github.com/browser-grpc/eventbus
- In-browser stub generator: https://browser-grpc.github.io/grpc-over-datachannels/app/
- Blog: https://c100k.blogspot.com/2026/10/introducing-grpc-over-datachannels-grpc.html
- Blog: https://c100k.blogspot.com/2026/10/kafka-over-grpc-rust-kafka-proxy-with.html
- Blog: https://c100k.blogspot.com/2026/10/webrtc-direct-examples-in-every.html
- Video (2:24): https://youtu.be/LwrXpnlMlgA
- Video (2:12): https://youtu.be/KJ98a4ApZ4E
- Playlist: https://www.youtube.com/playlist?list=PLL20oIw8Dg5U

---

## 1. dev.to article (primary, long form)

Title: **gRPC in the browser without grpc-web: the wire protocol over a WebRTC DataChannel**

Tags: grpc, webrtc, rust, webdev

Body:

grpc-web exists because browsers can't speak HTTP/2 trailers.
The usual answer is a translation proxy in front of your service.
We took a different one: run the actual gRPC wire protocol —
length-prefixed frames, HPACK-free, all four call shapes — over a
single WebRTC `RTCDataChannel`, and generate the runtime for it
from your `.proto`.

**grpc-over-datachannels** is that experiment, grown up:

- **Dependency-free generated runtimes for 16 languages** —
  JavaScript/TypeScript, Go, Rust, Python, Ruby, PHP, Lua, C,
  C++, Dart, Java, Kotlin, Scala, Swift, C#, and Zig. Browser and
  native. The generated code is stdlib-only; there is no grpc
  library underneath it.
- **Our own WebRTC stack.** ICE, DTLS, and SCTP written from
  scratch, so the native clients don't depend on a WebRTC library
  either.
- **Graded against stock gRPC.** The generated implementations are
  tested against the reference implementations through a
  TCP↔DataChannel proxy — the oracle is the real thing, not a
  reimplementation of it.
- **WebRTC-Direct.** A server prints one certhash multiaddr; a
  client dials it. No signaling server. Direct on a LAN, through a
  TURN relay behind symmetric NAT, or full ICE with STUN in peer
  mode — with runnable examples in every language.
- **A Kafka proxy in Rust.** `grpcdc.kafka.v1.Kafka` exposes
  Apache Kafka as a generated gRPC service, so any generated
  client — including a browser tab — can produce and consume
  without a Kafka client library. The same generated e2e suite
  runs against Kafka and Redpanda in CI.

If you only have thirty seconds, the whole pitch is a 2-minute
video: https://youtu.be/LwrXpnlMlgA — and the Kafka proxy gets
its own: https://youtu.be/KJ98a4ApZ4E

The part we're proudest of is also the strangest: almost
everything in the repos is generated. The runtimes, the tests,
the examples, and the docs come from recursive generators, so
sixteen languages can't quietly drift apart. When a language
misbehaves, we fix the generator, not sixteen codebases.

Try it without installing anything — the stub generator runs in
your browser: https://browser-grpc.github.io/grpc-over-datachannels/app/

Code, releases (npm / PyPI / NuGet / GHCR / GitHub-hosted Maven):
https://github.com/browser-grpc/grpc-over-datachannels

Longer write-ups, with the design trade-offs:
- https://c100k.blogspot.com/2026/10/introducing-grpc-over-datachannels-grpc.html
- https://c100k.blogspot.com/2026/10/kafka-over-grpc-rust-kafka-proxy-with.html

Questions and hostile edge cases welcome — the NAT and framing
ones especially.

---

## 2. Hacker News — Show HN

Title: **Show HN: gRPC over WebRTC DataChannels – generated, dependency-free runtimes for 16 languages**

First comment (post immediately after submitting the repo URL):

Author here. This runs the gRPC wire protocol over a single
RTCDataChannel instead of HTTP/2, so a browser tab can call a
native service peer-to-peer with no grpc-web proxy.

Everything is generated from .proto: stdlib-only runtimes for
16 languages (JS/TS, Go, Rust, Python, C, C++, Java, Kotlin,
Scala, C#, Swift, Dart, Ruby, PHP, Lua, Zig), browser and
native, plus our own from-scratch ICE/DTLS/SCTP stack for the
native side. Generated implementations are graded against the
stock gRPC implementations via a TCP↔DataChannel oracle proxy.

Also in the box: WebRTC-Direct (server prints one certhash
multiaddr, client dials it — no signaling; TURN/STUN modes,
examples per language) and a Rust Kafka proxy that exposes
Kafka as a generated gRPC service, tested against Kafka and
Redpanda in CI.

2-minute video walkthrough: https://youtu.be/LwrXpnlMlgA
In-browser code generator: https://browser-grpc.github.io/grpc-over-datachannels/app/

Happy to answer questions on the framing, the NAT behavior,
or why we generate the tests too.

---

## 3. Reddit (use sparingly, one subreddit, text post)

Suggested venue: r/grpc if active, else r/webdev. Do not
cross-post the same text. Title:

**I put gRPC on a WebRTC DataChannel so browsers can skip the grpc-web proxy — generated runtimes for 16 languages**

Body: reuse the dev.to body trimmed to ~40%, lead with the
problem (browser can't do HTTP/2 trailers), end with the video
and the in-browser generator. Read the subreddit's self-promo
rules before posting; participate in comments, don't drive-by.

---

## Posting checklist

- [x] v0.36.0 verified on GitHub / npm / PyPI / NuGet / GitHub
      Maven (Maven Central intentionally pending its weekly slot)
- [x] RELEASE.json on the public repo reads v0.36.0
- [x] Blog "Current release" link bumped from v0.35.10 to the
      v0.36.0 tag; video descriptions carry no version claims
- [x] dev.to first — POSTED 2026-11-01:
      https://dev.to/unicomp21/grpc-in-the-browser-without-grpc-web-the-wire-protocol-over-a-webrtc-datachannel-43g3
- [ ] HN Show after dev.to is live (link repo, not the article)
      — SKIPPED 2026-11-01 by choice; no HN account yet
- [ ] One Reddit venue only; log the post in comment-log.md
      — SKIPPED 2026-11-01 by choice; no Reddit account yet,
      and r/grpc is banned, so the venue would be r/webdev
- [ ] Never re-post the same text to a second subreddit
