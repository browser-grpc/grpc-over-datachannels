# Browser signaling post — DRAFT, prepared for the v0.41.0 release

Status: DRAFT ONLY. Publish with the v0.41.0 release (scheduled
2026-11-16); links below point at that release and must be
verified live before posting. Never mention the generator
internals in public copy.

Links (verify at publication):
- Release: https://github.com/browser-grpc/grpc-over-datachannels/releases/tag/v0.41.0
- Repo: https://github.com/browser-grpc/grpc-over-datachannels
- Examples: examples/rendezvous and examples/signaling in the repo

---

## dev.to article (primary, long form)

Title: **Browser gRPC with no signaling at all: dial an address, not a server**

Tags: grpc, webrtc, webdev, javascript

Body:

Every WebRTC tutorial starts the same way: stand up a
signaling server. Before your browser can open a DataChannel
to your service, something has to carry the SDP offer and
answer — usually a WebSocket service you now own forever.

If your server's address is fixed, that exchange turns out to
be unnecessary. A WebRTC endpoint can be described by five
small values: host, port, an ICE username fragment, an ICE
password, and the SHA-256 fingerprint of its DTLS
certificate. Publish those once — hardcode them, put them in
a config file, serve them as a tiny JSON file — and the
browser can synthesize the server's SDP locally, answer it
in-page, and start ICE. Nothing is ever sent out of band
again. We call this a **Rendezvous** endpoint:

```js
import { rendezvousChannel } from "grpc-dc";
const descriptor = { host: "203.0.113.10", port: 8443,
  iceUfrag: "…", icePwd: "…", fingerprint: "AB:CD:…" };
const client = new EchoClient(await rendezvousChannel(descriptor));
```

The server side is a fixed listener, generated for Node, Go,
and Rust: one UDP socket, one fixed ICE credential pair, one
fixed certificate. Each browser that dials is recognized by
the username fragment in its first connectivity check and
gets its own session on that same socket. The browser
authenticates the server by the published fingerprint,
exactly as it would with an SDP-carried one — only the
transport for those five values changed, from a live exchange
to a published constant. This is the same trick WebRTC-Direct
uses for native clients with its printed multiaddr, finally
available to a browser tab.

When the address *cannot* be fixed in advance, the release
also generates the smallest possible fallback: one HTTP POST.

```
POST /grpc-dc/signal  {"type":"offer","sdp":"..."}
200                   {"type":"answer","sdp":"..."}
```

The browser waits for ICE gathering to finish, so the single
offer carries every candidate. The server answers, connects
in the background, and every session still shares one
multiplexed UDP socket — a hundred concurrent browsers cost
the server exactly one UDP port to publish, forward, and
firewall, with reflexive candidates gathered once per socket
rather than once per browser.

Honest limits, stated up front:

- Rendezvous needs a fixed, published address. If your
  server's address is ephemeral, use the POST shape — or
  republish the descriptor when the address changes; browsers
  pick up the new one on their next page load.
- The descriptor's host is an IP literal, not a DNS name:
  ICE candidate lines carry addresses. Publish the address
  your DNS name resolves to, or fetch the descriptor from the
  name over HTTPS at page load.
- There is no ICE restart on a Rendezvous session: restart
  renegotiates SDP, and SDP is exactly what Rendezvous does
  not exchange. A dropped session redials the descriptor.
- Browsers still cannot dial WebRTC-Direct multiaddrs — there
  are no UDP sockets in a page. Direct remains the
  native-to-native path; Rendezvous and the POST shape are
  the browser paths to the same services, over the same wire.

Auth stays with your application in both shapes. The
examples run same-origin with no auth at all
(`examples/rendezvous`, `examples/signaling`: one Node
process serves the page and the Echo service — open
http://localhost:8080/ and it just works).

Why it matters: the browser was the last place grpc-dc still
needed an introducer. Native clients dial a printed address;
now browsers dial a published descriptor. There is no
signaling server left in the architecture diagram — for a
fixed-address server, there is no signaling, period.

---

## Short version (release notes / social)

Browser gRPC with no signaling server — and, for
fixed-address servers, no signaling at all: publish a
five-value Rendezvous descriptor (host, port, ICE
credentials, DTLS fingerprint) and browsers synthesize the
SDP locally and dial. Dynamic address instead? One POST to
`/grpc-dc/signal`. Server half generated for Node, Go, and
Rust; every browser session shares one UDP socket. Examples:
`node examples/rendezvous/server.mjs`, open localhost:8080.
