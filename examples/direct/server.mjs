// WebRTC-Direct Echo server (Node, dependency-free generated runtime).
//
//   node examples/direct/server.mjs
//
// Prints one line, MULTIADDR /ip4/.../webrtc-direct/certhash/f..., and
// serves the generated Echo service until killed. Give that line to any
// client: a browser cannot dial a multiaddr (no UDP in browsers), but
// every native language can, directly or through the Rust sidecar.
//
// The server side is identical for host and TURN runs: TURN is a
// client-side allocation used to reach this listener from behind a
// symmetric NAT. STUN is not needed by a Direct listener; it listens on
// a plain UDP socket. (Full-ICE peer examples use STUN; see README.md.)

import { Server } from "../../js/index.js";
import { acceptDirectEndpoint, directListener } from "../../js/src/webrtc_direct.js";
import { EchoResponse } from "../../js/examples/echo_pb.js";
import { createEchoService } from "../../js/examples/echo_grpc_dc.js";

const handlers = {
  async unary(req) {
    return new EchoResponse({ message: `echo: ${req.message}`, index: 0 });
  },
  async *serverStream(req) {
    for (let i = 0; i < Math.max(0, req.count); i++) {
      yield new EchoResponse({ message: req.message, index: i });
    }
  },
  async clientStream(requests) {
    const parts = [];
    for await (const req of requests) parts.push(req.message);
    return new EchoResponse({ message: parts.join("+"), index: parts.length });
  },
  async *bidi(requests) {
    let index = 0;
    for await (const req of requests) {
      yield new EchoResponse({ message: req.message, index: index++ });
    }
  },
};

// Bind address/port are env-overridable for containers and LAN use.
// With 0.0.0.0 the printed multiaddr contains 0.0.0.0; replace that
// part with the host's reachable IP before handing it to a client.
const listener = await directListener({
  address: process.env.DIRECT_ADDRESS || "127.0.0.1",
  port: Number(process.env.DIRECT_PORT || 0),
});
const server = new Server();
server.addService(createEchoService(handlers));
// Accept in a loop: every client (direct or via TURN) gets its own
// endpoint on the same listener.
(async () => {
  for (;;) {
    const endpoint = await acceptDirectEndpoint(listener);
    server.serve(endpoint);
  }
})().catch((err) => {
  console.error(`accept loop ended: ${err.message}`);
});

console.log(`MULTIADDR ${listener.multiaddr()}`);
console.log("direct-echo server ready; Ctrl-C to stop");
