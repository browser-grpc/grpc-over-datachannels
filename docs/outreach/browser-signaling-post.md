# Browser signaling post — DRAFT, prepared for the v0.41.0 release

Status: DRAFT ONLY. Publish with the v0.41.0 release (scheduled
2026-11-16); links below point at that release and must be
verified live before posting. Never mention the generator
internals in public copy.

Links (verify at publication):
- Release: https://github.com/browser-grpc/grpc-over-datachannels/releases/tag/v0.41.0
- Repo: https://github.com/browser-grpc/grpc-over-datachannels
- Example: examples/signaling in the repo (server + page, ~150 lines total)

---

## dev.to article (primary, long form)

Title: **Browser gRPC with no signaling server: one POST, one UDP socket**

Tags: grpc, webrtc, webdev, javascript

Body:

Every WebRTC tutorial starts the same way: stand up a
signaling server. Before your browser can open a DataChannel
to your service, something has to carry the SDP offer and
answer — usually a WebSocket service you now own forever.

grpc-over-datachannels now generates that away for the
browser-to-server case. The page makes one HTTP POST:

```
POST /grpc-dc/signal  {"type":"offer","sdp":"..."}
200                   {"type":"answer","sdp":"..."}
```

The browser waits for ICE gathering to finish, so the single
offer carries every candidate. The server answers, connects
in the background, and the gRPC calls run over the DataChannel
as usual. From the page it is one call:

```js
import { httpSignalingChannel } from "grpc-dc";
const client = new EchoClient(await httpSignalingChannel("/grpc-dc/signal"));
```

The server half is generated for the Node, Go, and Rust
stacks, and every session lives on one shared multiplexed UDP
socket: a hundred concurrent browsers still cost the server
exactly one UDP port to publish, forward, and firewall.
STUN reflexive candidates are gathered once for that socket,
not once per browser, and `.local` mDNS candidates from every
browser resolve through a single shared resolver.

Two honest limits, stated up front:

- This is non-trickle signaling. The browser waits for ICE
  gathering before POSTing, which costs a little connect
  latency and buys zero session state on the HTTP side.
- Browsers still cannot dial WebRTC-Direct multiaddrs — there
  are no UDP sockets in a page. Direct remains the
  native-to-native path; this POST shape is the browser path
  to the same services, over the same gRPC wire.

Auth and CORS stay with your application. Mount the handler
behind yours, or serve same-origin the way the example does
(`examples/signaling`: one Node process serves the page, the
signaling endpoint, and the Echo service — open
http://localhost:8080/ and it just works).

Why it matters: the browser was the last place grpc-dc still
needed an introducer. Native clients dial a printed address;
now browsers POST to an endpoint on the server they were
already talking to. The signaling server is gone from the
architecture diagram.

---

## Short version (release notes / social)

Browser gRPC, no signaling server: the page POSTs its
ICE-complete offer to `/grpc-dc/signal`, the server (Node, Go,
or Rust — generated) answers, and every browser session shares
one multiplexed UDP socket on the server. Example:
`node examples/signaling/server.mjs`, open localhost:8080.
