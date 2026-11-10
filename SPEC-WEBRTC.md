# WebRTC stack reimplementation — profile and rules

Goal: a browser-grade WebRTC **datachannel** stack reimplemented from
the RFCs, generated as far as possible by the project code generator, with
**zero external dependencies**, so `grpc-dc` no longer needs a foreign
WebRTC library underneath it.

## Hard rules

- **Rust stack crate (`webrtc/rust`, crate `dc-webrtc`): no
  `[dependencies]` at all.** std only: threads, blocking UDP sockets,
  `std::sync::mpsc`. Crypto is hand-rolled in-tree; its constant tables
  (SHA-256 round constants, AES S-box, CRC-32 table) are *computed* by
  the code generator, not copied from a crate. Entropy comes from
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
| DTLS | 6347/9147-off/9146 | **1.2 only**, `TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256`, P-256 only, self-signed certs pinned by SHA-256 fingerprint, extended master secret, `use_srtp` (RFC 5764: `SRTP_AES128_CM_HMAC_SHA1_80`, `SRTP_AEAD_AES_128_GCM`), HelloVerifyRequest handled client-side; **both roles browser-tested** — servers accept real-browser clients, including coalesced flights (epoch-0 key-establishing records sharing a datagram with the encrypted Finished); connection IDs (RFC 9146, project profile): a peer may announce a CID via the `connection_id` extension (54, length-prefixed value); honoring peers stamp it on every record after the epoch/sequence (offset 11) and inside the AEAD AAD (after epoch/sequence, before content type), receivers accept both CID and plain layouts (browsers ignore the extension), and the receiver arms its announced CID before the first handshake flight is read |
| SCTP | 9260/7496/6951/6525 | INIT/COOKIE handshake with state cookie, DATA/SACK with gap reports, retransmission, ordered + unordered streams, fragmentation/reassembly, PR-SCTP FORWARD-TSN, RE-CONFIG stream reset for datachannel close (RFC 8831 §6.4: outgoing reset, peer resets its side in turn, deferred until the sender's last assigned TSN is cumulative), HEARTBEAT, graceful SHUTDOWN |
| DCEP | 8832/8831 | DATA_CHANNEL_OPEN/ACK, reliable + partially-reliable channel types, PPIDs 50/51/53/56/57, DTLS-client=even streams rule |

Demultiplexing on the single UDP socket follows RFC 7983: first byte
0–3 → STUN, 20–63 → DTLS. SCTP rides inside DTLS application data.

**Single-socket mux (`PeerMux`, all three native stacks).** Many
signaled peers share one bound UDP socket. Routing: STUN by the ICE
username's local ufrag; username-less Binding Successes are offered
to every endpoint (each agent consumes only its own
integrity-checked transaction); a first-flight ClientHello — which
carries no CID on the wire — routes by the private `DcPairHint`
extension (65282, carrying the remote peer's ICE ufrag); every later
record routes by the connection id at offset 11 against the
endpoint's allocated CID (fixed 10 bytes: shared port big-endian
uint16 + counter big-endian uint64, exact map lookup); the learned
source address is the fallback for peers that ignore the
`connection_id` extension. Because records no longer route by
source, two muxes can peer with each other and NAT rebinding does
not strand DTLS. TURN works on muxed peers: the allocation's UDP
leg rides a dedicated per-peer socket (an allocation pins a
concrete 5-tuple), so TURN traffic never touches the shared
socket; TCP/TLS TURN rides its own stream as usual. The scenario (two pairs sharing one server
socket; two pairs mux-to-mux) is generated by grpc-dc codegen
into all three stacks' test trees, and the cross-stack matrix pairs
mux against mux across Rust/Go/JS.


## Lossy and unordered channels

Data channels are not limited to reliable, ordered delivery.
All three stacks implement the DCEP channel-type space end to
end, and PR-SCTP (RFC 3758) abandonment on top of it:

- **Unordered**: channel type `0x80`; messages carry the U flag
  and are delivered on arrival, with no head-of-line waiting
  for earlier stream sequence numbers.
- **Partially reliable (lossy)**: channel types `0x01`
  (max retransmissions) and `0x02` (max lifetime in ms). The
  sender abandons a message once its retransmit count or
  lifetime budget is spent, then sends FORWARD-TSN so the
  receiver skips the abandoned sequence numbers and the stream
  keeps flowing. Both negotiating and accepting these types is
  implemented, including from browsers (native
  `RTCDataChannelInit: { maxRetransmits, maxPacketLifeTime,
  ordered: false }`).

Per-stack surface:

- Rust: `ChannelParams { ordered: false,
  reliability: Reliability::MaxRetransmits(n) |
  MaxLifetimeMs(ms), .. }` (`webrtc/rust/src/dcep.rs`).
- JS: `openChannel({ ordered: false,
  reliability: { kind: "retransmits", count: n } })` (or
  `{ kind: "lifetime", ms }`).
- Go: `ChannelParams{Ordered: false, MaxRetransmits: &n}` (or
  `MaxLifetimeMs: &ms`).

The generated runtimes' Direct adapters expose the raw
endpoint next to the transport helpers --
`direct_client_endpoint` / `accept_direct_endpoint` (Rust),
`DirectClientEndpoint` / `AcceptDirectEndpoint` (Go),
`directClientStackEndpoint` / `openDirectChannel` (JS) -- so
applications can open lossy or unordered channels alongside
the "grpc" one (proven next to live gRPC traffic in the Rust,
Go, and JS adapter tests).

One deliberate restriction: the "grpc" channel itself always
runs reliable and ordered. grpc-dc framing (stream ids,
trailers, resets, half-close) assumes in-order reliable
delivery; a dropped frame would corrupt call state. Use lossy
channels for application data that tolerates drops and
reordering (telemetry, presence, game state), not for gRPC.

Tests: `webrtc/rust/tests/sctp.rs` (`unordered_delivery`,
`loss_and_rto_retransmit`,
`partial_reliability_abandons_and_unblocks_stream`) and the
matching SCTP suites in `webrtc/js/test/sctp.test.js` and
`webrtc/go`, plus the adapter-level lossy-channel tests named
above.

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
  `RequestIPv6Relay` when dialing one. The homegrown Rust TLS
  client offers ECDHE-ECDSA and ECDHE-RSA with ECDSA and
  RSA-PKCS#1 signature algorithms, and its TURNS coturn leg
  verifies an RSA certificate against a pinned root.
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
  `direct_client_turn`), the
  Go adapter `go/webrtc_direct.go` (`DirectListener`,
  `AcceptDirectTransport`, `DirectClientTransport`,
  `DirectClientTurnTransport`), and the JS (Node) adapter
  `js/src/webrtc_direct.js` (`directListener`,
  `acceptDirectEndpoint`, `directClientEndpoint`,
  `directClientTurnEndpoint`;
  tested by `js/test/webrtc_direct.test.js`).
- **All other languages**: the Rust binary
  `webrtc/rust/examples/direct_sidecar.rs` owns the stack and
  bridges one `grpc` datachannel to a local TCP socket with u32
  big-endian length-prefixed messages (one prefix per
  DataChannel message). `dial` mode dials a listener (optionally
  over TURN); `listen` mode is the listener and connects each
  accepted channel to a language server socket. Both modes
  bridge one thread per connection, so a single sidecar pair
  carries concurrent Direct sessions (proven with three
  concurrent clients in Python and Go). Generated
  runtimes plug in with a stdlib-only framed-TCP transport
  (reference: `grpcdc.SidecarTransport` in Python; the framing is identical in
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

## HTTP/POST signaling (browser → server)

Browsers cannot dial a Direct multiaddr and `RTCPeerConnection`
always needs an SDP exchange, so the generated runtimes ship an
optional single-POST signaling contract as the minimal browser
on-ramp — an exchange, not a signaling server:

- **Contract**: `POST /grpc-dc/signal` with JSON
  `{"type":"offer","sdp":...}` returns `200`
  `{"type":"answer","sdp":...}`. Errors are JSON
  `{"error":...}` (400 malformed/invalid offer, 405 non-POST,
  404 other paths on the standalone servers). Bodies are
  limited to 1 MiB. Non-trickle only: the browser waits for ICE
  gathering to complete before POSTing, and the server answers
  from the candidates its Peer holds at creation.
- **Browser side**: generated JS `httpSignalingChannel(url)`
  (`js/src/signaling.js`) builds the `RTCPeerConnection`, opens
  the `grpc` channel, performs the POST with `fetch`, and
  returns a `Channel` for generated clients.
- **Server side**: one fresh full `Peer` per POST — created on
  the signaling server's shared `PeerMux`, so all sessions use
  one UDP socket (srflx gathered once per STUN-server list and
  adopted by later peers; mDNS resolution shares one process
  resolver). The answer returns immediately and the peer
  connects in the background, serving the `grpc` channel and
  closing with it. Hosts may supply their own mux
  (`options.mux` in JS, `HttpSignalingOptions.Mux` /
  `NewHttpSignalingServer` in Go,
  `serve_http_signaling_muxed` in Rust) to share one socket
  across several signaling servers in a process. Generated
  adapters: JS `signalingHandler` / `serveHttpSignaling`
  (`js/src/signaling_server.js`), Go `HttpSignalingHandler` /
  `ServeHttpSignaling` (`go/http_signaling.go`), Rust
  `serve_http_signaling(_with|_muxed)`
  (`rust/src/http_signaling.rs`, std-only HTTP listener).
- **Scope**: auth and CORS belong to the host application
  (mount the handler forms behind them). STUN/TURN for the
  server peer are Peer(Options|Config) settings; the browser's
  own are `iceServers` options.
- **Tests**: `browser-test/signaling.test.mjs` (Chromium,
  Firefox, WebKit page → Node signaling server, unary +
  server-streaming), `js/test/signaling.test.js`,
  `go/http_signaling_test.go`, and
  `rust/tests/http_signaling.rs` (native offerer POST + Echo).

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
- **Raw Ethernet gRPC framing** (`EthFraming` in `net.rs`):
  whole grpc-dc wire messages travel directly in Ethernet II
  frames (EtherType `0x88B5`, IEEE 802 Local Experimental 1), so
  a bare-metal target with only a NIC driver runs generated
  clients/servers with no IP/UDP/ICE at all. Messages fragment
  into 1491-byte chunks (magic, message sequence, byte offset,
  last-fragment flag) and reassemble in order; point-to-point
  only, and a lost fragment drops its message (resync on the
  next), like a serial link. The generated Rust runtime ships it
  as the `EthDc` `DcTransport` (webrtc feature) over any
  `EthFramePort`; `dc-webrtc`'s `RawEthernetPort` is the virtual-
  cable implementation used by the tests.
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
  constant is generated from `webrtc-spec.rkt` into all three
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
