# WebRTC stack reimplementation — profile and rules

Goal: a browser-grade WebRTC **datachannel** stack reimplemented from
the RFCs, generated as far as possible by the Racket metaprogram, with
**zero external dependencies**, so `grpc-dc` no longer needs a foreign
WebRTC library underneath it.

## Hard rules

- **Rust stack crate (`webrtc/rust`, crate `dc-webrtc`): no
  `[dependencies]` at all.** std only: threads, blocking UDP sockets,
  `std::sync::mpsc`. Crypto is hand-rolled in-tree; its constant tables
  (SHA-256 round constants, AES S-box, CRC-32 table) are *computed* by
  the Racket metaprogram, not copied from a crate. Entropy comes from
  the OS (`/dev/urandom`).
- **JS stack (`webrtc/js`): Node builtins only** (`node:crypto`,
  `node:dgram`). Browsers expose no raw UDP sockets, so the JS stack is
  Node-only by necessity; in a browser, the native `RTCDataChannel`
  plus the existing zero-dep `js/` gRPC runtime remains the right
  client — and is exactly what the Playwright test exercises.
- **Go stack (`webrtc/go`): standard library only.** Mirrors the JS
  stack's shape (the two are kept in lockstep, with Rust where its
  std-only constraint allows); `crypto/tls` covers TURN over TLS.
- **Interop target: real browsers** (Firefox/Chrome datachannels), not
  just our own two peers. Every layer is therefore the RFC protocol,
  with the subsets below chosen to be the smallest ones browsers accept.

## Layer profile

| Layer | RFC | Subset |
|---|---|---|
| SDP | 8866/8829 | offer/answer, `m=application UDP/DTLS/SCTP webrtc-datachannel`, `sctp-port:5000`, `max-message-size`, fingerprint/setup/ice lines, candidates inline in SDP and/or trickled (`a=ice-options:trickle` advertised) |
| ICE | 8445/8489 (+5766 TURN) | full agent, both roles, host + server-reflexive (srflx) + TURN relay candidates, connectivity checks + nomination, tie-breaker role-conflict repair, STUN Binding with short-term credentials; TURN: Allocate with long-term credentials (MD5 key), CreatePermission per remote candidate, pair traffic relayed as ChannelData over channels bound per peer address (Send/Data indications remain the fallback for unbound addresses and are accepted inbound); permissions (300 s), channel bindings, and the allocation (server-granted LIFETIME) are refreshed in the background at 80% of expiry; `raddr`/`rport` emitted before `generation 0` (Firefox's parser stops at unknown extensions); trickle ICE: SDP may carry zero candidates, remote candidates added incrementally (`AddRemoteCandidate`/`addRemoteCandidate`/`add_remote_candidate`, during connect in Go/JS and via a trickle channel in Rust), local candidates emitted via callback (`SetOnLocalCandidate`/`setOnLocalCandidate`) or candidate-line accessors, end-of-candidates accepted as a no-op (TURN permissions cover candidates known at connect; later-trickled candidates connect directly or peer-reflexively); consent freshness (RFC 7675): Binding checks on the nominated pair every 5 s by default (configurable, relay-aware), expiry after 30 s of silence closes the endpoint and fires a failure callback; nominating checks are retransmitted per pair (250 ms pacing) until their Binding success lands; ICE restart: fresh credentials per generation with media continuing on the old pair until renomination (DTLS destination is pinned per generation and switches only at renomination); IPv6 host/srflx/relay candidates throughout; TURN over TCP and TLS (`turns:`) on the client↔server leg (stream framing per RFC 5766 — STUN lengths, ChannelData padded to 4-byte boundaries; the allocation itself still requests UDP peer transport), with Rust verifying `turns:` chains against a real root store (system PEM bundle, ECDSA-SHA256 + RSA-SHA256 links) through the std-only TLS 1.2 client in `tls12.rs` |
| DTLS | 6347/9147-off | **1.2 only**, `TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256`, P-256 only, self-signed certs pinned by SHA-256 fingerprint, extended master secret, `use_srtp` (RFC 5764: `SRTP_AES128_CM_HMAC_SHA1_80`, `SRTP_AEAD_AES_128_GCM`), HelloVerifyRequest handled client-side; **both roles browser-tested** — servers accept real-browser clients, including coalesced flights (epoch-0 key-establishing records sharing a datagram with the encrypted Finished) |
| SCTP | 9260/7496/6951/6525 | INIT/COOKIE handshake with state cookie, DATA/SACK with gap reports, retransmission, ordered + unordered streams, fragmentation/reassembly, PR-SCTP FORWARD-TSN, RE-CONFIG stream reset for datachannel close (RFC 8831 §6.4: outgoing reset, peer resets its side in turn, deferred until the sender's last assigned TSN is cumulative), HEARTBEAT, graceful SHUTDOWN |
| DCEP | 8832/8831 | DATA_CHANNEL_OPEN/ACK, reliable + partially-reliable channel types, PPIDs 50/51/53/56/57, DTLS-client=even streams rule |

Demultiplexing on the single UDP socket follows RFC 7983: first byte
0–3 → STUN, 20–63 → DTLS. SCTP rides inside DTLS application data.

## Verification strategy (independent oracles first)

1. Crypto against published NIST/RFC test vectors.
2. DTLS handshake against **OpenSSL** `s_server`/`s_client -dtls1_2`
   before the JS DTLS exists — OpenSSL is the reference every browser
   stack is measured against.
3. Rust ↔ JS cross-tests at every layer (the stdio-bridge pattern the
   gRPC interop tests already use, here over real UDP loopback).
4. **Playwright + a real browser** as the final proof: a page opens a
   native `RTCDataChannel` to our Rust/Node peer and runs the existing
   JS gRPC client over it. Playwright therefore belongs in the browser
   test target and in `Dockerfile.ci` — not in the unit suites.

Dependency audit is mechanical and part of CI: `webrtc/rust/Cargo.toml`
must keep an empty dependency set and `webrtc/js` may import only
`node:` builtins.

## Browser interop findings (Chromium + Firefox, via Playwright)

Bugs that self-interop between our two stacks could not catch, all
found by running real browsers (`browser-test/`) and fixed:

- STUN FINGERPRINT: the CRC must be computed with the header length
  already set to the final value including the FP attribute; browsers
  verify it and silently dropped our Binding successes.
- `use_srtp` extension: the profiles vector length must match the
  profiles actually carried; BoringSSL rejects trailing bytes.
- ICE `ice-pwd` must be ≥ 22 characters (RFC 8445); browsers reject
  shorter passwords in SDP.
- WebRTC PPIDs are DCEP 50, String 51, Binary 53, String-Empty 56,
  Binary-Empty 57 (not a contiguous 53–57 block).
- Browsers offer only mDNS `<uuid>.local` host candidates; native peers
  resolve them with a minimal RFC 6762 query (`mdns.rs` / `mdns.js` /
  `mdns.go`).
- Chromium answers mDNS queries **by multicast** to
  `224.0.0.251:5353` even when the query carries the QU bit: a resolver
  listening only on its ephemeral query socket hears nothing and
  silently falls back to peer-reflexive learning. The resolvers now
  also join the group on :5353 while querying, ask A and AAAA, and
  retry resolution while ICE checks are in flight (never under the
  agent lock).
- Playwright's Firefox answers **no** mDNS query variant (verified on
  host and in Docker), so Firefox legs depend on peer-reflexive
  learning, which needs Firefox to initiate checks. It will not
  initiate to same-IP or loopback pairs, so browser legs cannot
  connect inside a single-IP network namespace — the Docker gate
  therefore runs with `--network host` (see Dockerfile.ci).
- A browser may re-nominate a different pair within the same ICE
  generation; if the DTLS destination live-follows the agent's
  nominated pair, media drifts mid-session. The destination is pinned
  to the connect-time pair and switches only at an ICE restart's
  renomination.
