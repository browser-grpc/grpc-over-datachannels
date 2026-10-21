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
| ICE | 8445/8489 (+5766 TURN) | full agent, both roles, host + server-reflexive (srflx) + TURN relay candidates, connectivity checks + nomination, tie-breaker role-conflict repair, STUN Binding with short-term credentials; TURN: Allocate with long-term credentials (MD5 key), CreatePermission per remote candidate, pair traffic relayed as ChannelData over channels bound per peer address (Send/Data indications remain the fallback for unbound addresses and are accepted inbound); permissions (300 s), channel bindings, and the allocation (server-granted LIFETIME) are refreshed in the background at 80% of expiry; `raddr`/`rport` emitted before `generation 0` (Firefox's parser stops at unknown extensions); trickle ICE: SDP may carry zero candidates, remote candidates added incrementally (`AddRemoteCandidate`/`addRemoteCandidate`/`add_remote_candidate`, during connect in Go/JS and via a trickle channel in Rust), local candidates emitted via callback (`SetOnLocalCandidate`/`setOnLocalCandidate`) or candidate-line accessors, end-of-candidates accepted as a no-op (TURN permissions cover candidates known at connect; later-trickled candidates connect directly or peer-reflexively); consent freshness (RFC 7675): Binding checks on the nominated pair every 5 s by default (configurable, relay-aware), expiry after 30 s of silence closes the endpoint and fires a failure callback; nominating checks are retransmitted per pair (250 ms pacing) until their Binding success lands; ICE restart: fresh credentials per generation with media continuing on the old pair until renomination (DTLS destination is pinned per generation and switches only at renomination); IPv6 host/srflx/relay candidates throughout; TURN over TCP and TLS (`turns:`) on the client↔server leg (stream framing per RFC 5766 — STUN lengths, ChannelData padded to 4-byte boundaries; the allocation itself still requests UDP peer transport), with Rust verifying `turns:` chains against a real root store (system PEM bundle; ECDSA with SHA-256/384/512 over P-256/P-384 and RSA with SHA-256/384/512, ECDHE on both curves) through the std-only TLS 1.2 client in `tls12.rs` |
| DTLS | 6347/9147-off | **1.2 only**, `TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256`, P-256 only, self-signed certs pinned by SHA-256 fingerprint, extended master secret, `use_srtp` (RFC 5764: `SRTP_AES128_CM_HMAC_SHA1_80`, `SRTP_AEAD_AES_128_GCM`), HelloVerifyRequest handled client-side; **both roles browser-tested** — servers accept real-browser clients, including coalesced flights (epoch-0 key-establishing records sharing a datagram with the encrypted Finished) |
| SCTP | 9260/7496/6951/6525 | INIT/COOKIE handshake with state cookie, DATA/SACK with gap reports, retransmission, ordered + unordered streams, fragmentation/reassembly, PR-SCTP FORWARD-TSN, RE-CONFIG stream reset for datachannel close (RFC 8831 §6.4: outgoing reset, peer resets its side in turn, deferred until the sender's last assigned TSN is cumulative), HEARTBEAT, graceful SHUTDOWN |
| DCEP | 8832/8831 | DATA_CHANNEL_OPEN/ACK, reliable + partially-reliable channel types, PPIDs 50/51/53/56/57, DTLS-client=even streams rule |

Demultiplexing on the single UDP socket follows RFC 7983: first byte
0–3 → STUN, 20–63 → DTLS. SCTP rides inside DTLS application data.

## WebRTC-Direct (libp2p-style)

Signaling-free client→server connections for listeners with a
reachable UDP address: no ICE negotiation, no SDP exchange.

- **Identity**: the listener's self-signed certificate, pinned by
  its *certhash* — multibase `f` + base64url of the sha2-256
  multihash (`0x12 0x20 || SHA-256(cert DER)`) of the certificate,
  exactly as in libp2p multiaddrs. Dialers verify the DTLS peer
  certificate against it (`expected_peer_fingerprint`); a wrong
  certhash fails the handshake.
- **Address**: `/ip4/<a>/udp/<p>/webrtc-direct/certhash/<hash>`
  (or `ip6`). `parse_direct_multiaddr` / `parseDirectMultiaddr`
  return the socket address + pinned digest.
- **Roles are fixed**: dialer is DTLS client (even SCTP streams,
  opens the `grpc` channel), listener is DTLS server. The
  listener learns the dialer address from the first datagram.
- **Concurrent dialers**: a listener may accept any number of
  dialers, including simultaneous handshakes. All three native
  listeners demultiplex the shared UDP socket by peer address:
  one socket reader routes datagrams to the endpoint that
  claimed that peer, unclaimed peers queue until an `accept`
  claims them (one claim per accept, serialized), so endpoints
  never steal each other's handshake packets.
- **Over TURN (symmetric NAT)**: `direct_dial_turn` /
  `directDialTurn` allocate on a TURN server, install a
  permission + channel binding for the listener address, and run
  the entire DTLS/SCTP session inside Send/Data indications or
  ChannelData. The dialer never exchanges a direct packet with
  the listener, so NAT mapping behavior (including symmetric
  NAT) cannot break it; a background refresher keeps the
  allocation alive. The listener needs no TURN awareness — it
  sees ordinary UDP from the relayed address. Refresh is proven
  past expiry: Rust, JS, and Go tests use fakes enforcing a
  3-second allocation and permission lifetime and verify
  traffic still flows after 5 seconds (the fake drops relayed
  traffic for expired allocations, so the test cannot pass
  without Refresh, permission, and channel-bind renewal).
- **TURNS and IPv6**: the TURN client<->server transport may be
  TLS (`TurnTransport::Tls` / `transport: "tls"` /
  `Transport: "tls"`) over a dedicated stream connection, and
  the whole Direct session may run over IPv6 (an `ip6`
  multiaddr against a `[::1]` listener and relay). Both shapes
  are proven against a private coturn in all three native
  stacks. Servers whose relay is IPv6-only may reject
  allocations without `REQUESTED-ADDRESS-FAMILY` (error 440);
  set `request_ipv6_relay` / `requestIpv6Relay` /
  `RequestIPv6Relay` when dialing one. Note the homegrown Rust
  TLS stack offers ECDHE-ECDSA only, so a coturn serving TURNS
  to the Rust stack needs an ECDSA certificate.
- **Browser shape**: browsers cannot bind UDP or allocate TURN
  in this raw form, so a browser is always the dialer, via a
  native `RTCPeerConnection` with relay-only ICE
  (`iceTransportPolicy: "relay"` + `iceServers`) to a full
  `Peer`. Proven by `browser-test/direct_turn.test.mjs`
  (Playwright/Chromium): the browser offers only relay
  candidates, the nominated pair is relay<->relay, and the echo
  crosses it. The raw-allocation form above is the native
  equivalent, proven against fake TURN fixtures and against
  real coturn (`direct_over_real_turn_coturn` in Rust,
  `direct_coturn.test.js` in JS; both skip without
  `turnserver`, which `Dockerfile.ci` installs).
- **Implementations**: Rust `webrtc/rust/src/direct.rs`
  (`DirectListener`, `direct_dial(_multiaddr)`,
  `direct_dial_turn(_multiaddr)`), JS `webrtc/js/direct.js`
  (same names in camelCase), and Go `webrtc/go/direct.go`
  (`NewDirectListener`, `DirectDialMultiaddr`,
  `DirectDialTurnMultiaddr` -- the TURN path reuses the Peer's
  TURN demux). Generated gRPC support: Rust
  `grpc_dc::webrtc_direct` (`direct_listener`,
  `accept_direct_transport`, `direct_client`,
  `direct_client_turn`, from `racket/runtime-rust.rkt`) and
  the Go adapter `go/webrtc_direct.go` (`DirectListener`,
  `AcceptDirectTransport`, `DirectClientTransport`,
  `DirectClientTurnTransport`).
- **All other languages**: the Rust binary
  `webrtc/rust/examples/direct_sidecar.rs` owns the stack and
  bridges one `grpc` datachannel to a local TCP socket with u32
  big-endian length-prefixed messages (one prefix per
  DataChannel message). `dial` mode dials a listener (optionally
  over TURN); `listen` mode is the listener and connects each
  accepted channel to a language server socket. Generated
  runtimes plug in with a stdlib-only framed-TCP transport
  (reference: `grpcdc.SidecarTransport` in Python, generated
  from `racket/runtime-python.rkt`; the framing is identical in
  every language). Lua is the one variation: pure Lua has no
  stdlib sockets, so its generated `SidecarTransport`
  (`lua/grpcdc/sidecar_transport.lua`) frames over a socket the
  host application injects (`sendAll` / `recvExact` / `close`);
  `lua/tests/host_socket.lua` is the test host implementation.
- **Tests**: `webrtc/rust/tests/webrtc_direct.rs` (echo, wrong
  certhash rejected, concurrent dialers, echo and refresh-past-
  lifetime over fake TURN, echo over coturn, TURNS and IPv6
  coturn legs, IPv6 echo), `webrtc/js/test/direct.test.js`
  (same set + certhash round-trip) and `direct_coturn.test.js`
  (coturn UDP, TURNS, and IPv6 legs),
  `webrtc/go/direct_test.go` (same set),
  `browser-test/direct_turn.test.mjs` (Chromium relay-only
  dial, nominated relay<->relay pair),
  `rust/tests/webrtc_direct_grpc.rs` and
  `go/webrtc_direct_test.go` (generated Echo client/server by
  multiaddr), and same-language gRPC through two sidecars in
  every generated language's test suite (Python, Go, Ruby, PHP,
  Dart, Java, Kotlin, Scala, C#, Swift, C++, Zig, C, and Lua;
  each prints `TestSidecar OK`).

## Embedded profile

The Rust crate is layered so the protocol core runs with no OS:

- **Platform injection** (`platform.rs`): the core reads time,
  entropy, and datagrams through `Clock` / `Rng` / `UdpTransport`
  traits (std defaults). The ICE agent's nomination/consent
  pacing runs on an injected clock (`Peer::new_with_platform`);
  `ManualClock` + `SeededRng` + `MemoryNetwork` give a
  deterministic, thread-free RTOS tick harness. Certificate
  validity reads the installed clock's wall time.
- **no_std core**: without the default `std` feature the crate is
  `no_std` (alloc-only) — ICE/DTLS/SCTP/DCEP/SDP/STUN, the `net`
  stack, and platform traits. OS surfaces (`Peer`, endpoint,
  TURN, mDNS, std transports, the TLS-over-TCP client) are
  std-gated. Gate `make test-webrtc-nostd` builds host + wasm32 +
  thumbv7em-none-eabihf (Cortex-M; the core needs no 64-bit
  atomics).
- **L2–L4 stack** (`net.rs`): hand-rolled Ethernet II, ARP
  (RFC 826), IPv4 (RFC 791, no options/fragmentation), UDP
  (RFC 768), ICMP echo, and a DHCPv4 client (RFC 2131 subset:
  DISCOVER/OFFER/REQUEST/ACK yielding address, mask, router,
  DNS, lease). `DhcpClient::tick` drives lease timers: renew
  (server-id REQUEST) at T1 = 50% of the lease, rebind
  (broadcast REQUEST) at T2 = 87.5%, lease dropped at expiry;
  every ACK re-arms the clock. Pure frame-in/frame-out state
  machines; the target supplies the NIC driver below Ethernet
  and ARP routing is local-subnet only.
- **IPv6 beside IPv4** (`IpStack6`): NDP neighbour discovery,
  ICMPv6 echo, UDP/6, EUI-64/SLAAC addresses, Router
  Solicitation/Advertisement (an RA installs the sender as
  default router, lifetime 0 withdraws it, on-link Prefix
  Information sets the prefix length; `send_router_advertisement`
  originates RAs for router mode), opt-in forwarding with
  hop-limit decrement and pending-forward queueing until NDP
  resolves. `EthernetCable::endpoint6` binds the stack to a
  `UdpTransport`, so ICE nomination runs over IPv6/NDP exactly
  as over IPv4/ARP (`ice_nomination_over_ipv6_ethernet`). A
  DHCPv6 client (RFC 8415 subset: SOLICIT/ADVERTISE/REQUEST/
  REPLY, IA_NA + DNS) renews at half the valid lifetime from
  `tick` and drops the lease at expiry.
- **Stack tracing** (`trace` module): `Peer::connect` emits
  `ice.nominated`, `dtls.handshake` (`full`/`resumed`), and
  `endpoint.ready` to a registered synchronous observer — the
  same dormant, dependency-free hook shape as the gRPC
  runtimes. Observer panics are caught. All three stacks emit
  the same events (`setStackObserver` in JS and Go); the JS
  and Go DTLS stacks have no session resumption, so their
  handshake detail is always `full`.
- **TURN over IPv6**: `TurnServerConfig::request_ipv6_relay`
  adds REQUESTED-ADDRESS-FAMILY (RFC 8656; the attribute
  constant is stamped from `webrtc-spec.rkt` into all three
  stacks) so allocations return IPv6 relayed addresses;
  XOR-address codecs were already family-agnostic.
- **DTLS session resumption** (RFC 5077 shape, opt-in, off by
  default): servers with a 32-byte ticket key issue AES-128-GCM
  sealed `NewSessionTicket`s; clients capture them
  (`Dtls::take_session`, `DcEndpoint::take_dtls_session`) and
  reconnect abbreviated (`connect_resumed`, or
  `PeerConfig::resume_session` with a persistent
  `PeerConfig::certificate`). The peer certificate travels
  inside the sealed ticket and the SDP fingerprint check runs
  against it unchanged — resumption skips re-presentation, not
  identity. Tampered, expired (1 h), or foreign-key tickets fall
  back to a full handshake. `Peer` level: the DTLS
  offerer is the ticket issuer; the answerer captures/resumes.
  OpenSSL interop notes: the ticket is issued at epoch 0 before
  CCS (an epoch-1 ticket after Finished is rejected by OpenSSL
  TLS 1.2 clients as post-handshake), servers echo the client's
  session id in the resumed `ServerHello` (the resumption
  signal; no `session_ticket` extension in that hello), and no
  fresh ticket is rotated after an abbreviated handshake.
  `openssl_client_ticket_resumption` covers `s_client -sess_in`
  against our server; `openssl_server_ticket_resumption` covers
  the reverse.
- **Crypto backend seam**: the DTLS suite operations (SHA-256,
  HMAC-SHA-256, TLS PRF, AES-128-GCM) route through an installed
  `CryptoBackend` (default: hand-rolled), so mbedTLS/PSA/wolfSSL
  bindings can be installed at startup with no call-site
  changes. Outside the v1 boundary: SHA-384/512, SHA-1/MD5
  (cert-chain/STUN legacy), CRCs, and P-256/P-384 group ops.
- **Headless signaling** (`signaling.rs`): SDP and candidate
  lines framed over any byte stream (serial/BLE/UART) as
  `[u32 BE length][u8 kind][payload]` — kinds: offer, answer,
  candidate, end-of-candidates — with a stdio example
  (`peer_serial`). Combined with consent expiry (sleep
  detection) and ticket resumption (fast wake), this covers the
  embedded connect → sleep → wake cycle with no HTTP/WebSocket
  anywhere.

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
  connect inside a single-IP network namespace with obfuscated
  candidates. The test harness therefore launches Firefox with
  `media.peerconnection.ice.obfuscate_host_addresses=false` (raw IP
  candidates); Chromium keeps obfuscation and covers the mDNS path.
- A browser may re-nominate a different pair within the same ICE
  generation; if the DTLS destination live-follows the agent's
  nominated pair, media drifts mid-session. The destination is pinned
  to the connect-time pair and switches only at an ICE restart's
  renomination.
