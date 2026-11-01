// WebRTC-Direct Echo client (Node, dependency-free generated runtime).
//
//   node examples/direct/client.mjs '/ip4/127.0.0.1/udp/4001/webrtc-direct/certhash/f...'
//
// With TURN (client behind a symmetric NAT; the server stays a plain
// Direct listener):
//
//   DIRECT_TURN=turn.example.com:3478 DIRECT_TURN_USER=grpc DIRECT_TURN_PASS=grpc \
//     node examples/direct/client.mjs '/ip4/...'
//
// DIRECT_TURN is host:port of a TURN server (coturn works; see
// docker-compose.yml in this directory). Without DIRECT_TURN the client
// dials the multiaddr directly over UDP.

import { Channel } from "../../js/index.js";
import {
  directClientEndpoint,
  directClientTurnEndpoint,
} from "../../js/src/webrtc_direct.js";
import { EchoRequest } from "../../js/examples/echo_pb.js";
import { EchoClient } from "../../js/examples/echo_grpc_dc.js";

const multiaddr = process.argv[2] || process.env.GRPC_DC_ADDR;
if (!multiaddr) {
  console.error("usage: client.mjs <multiaddr>   (or set GRPC_DC_ADDR)");
  process.exit(2);
}

const turnAddress = process.env.DIRECT_TURN;
let endpoint;
if (turnAddress) {
  endpoint = await directClientTurnEndpoint(multiaddr, {
    address: turnAddress,
    username: process.env.DIRECT_TURN_USER || "",
    password: process.env.DIRECT_TURN_PASS || "",
  });
  console.log(`mode: turn (allocation via ${turnAddress})`);
} else {
  endpoint = await directClientEndpoint(multiaddr);
  console.log("mode: direct (no TURN)");
}

const client = new EchoClient(new Channel(endpoint));
try {
  const unary = await client.unary(new EchoRequest({ message: "hello direct" }));
  console.log(`unary -> ${unary.message}`);
  const parts = [];
  for await (const resp of await client.serverStream(new EchoRequest({ message: "tick", count: 3 }))) {
    parts.push(`${resp.message}#${resp.index}`);
  }
  console.log(`serverStream -> ${parts.join(" ")}`);
  console.log("direct-echo OK");
} finally {
  await endpoint.directEndpoint.closeDirect?.() ?? endpoint.directEndpoint.close();
}
