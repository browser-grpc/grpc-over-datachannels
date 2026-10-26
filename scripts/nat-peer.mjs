// NAT e2e peer (scripts/nat-e2e.sh runs two of these in
// separate network namespaces behind separate NATs):
//   --role stun     answer STUN Binding requests on --addr
//   --role offer    ICE offerer; --grpc client|server picks the
//                   gRPC direction over the established channel
//   --role answer   ICE answerer; same --grpc choice
// Signaling rides files in --signal-dir (SDP offer/answer), the
// way the other cross-process harnesses pass transcripts.
// gRPC traffic is the generated Echo service (unary,
// server-stream, bidi) from the JS runtime — the point is real
// gRPC calls, not echo bytes, across two NATs.

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import dgram from "node:dgram";

const args = {};
for (let i = 2; i < process.argv.length; i += 2) {
  args[process.argv[i].replace(/^--/, "")] = process.argv[i + 1];
}
const role = args.role;
const dir = args["signal-dir"] ?? "/tmp/nat-e2e";
mkdirSync(dir, { recursive: true });

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function waitFor(file, what, timeoutMs = 60000) {
  const path = join(dir, file);
  const deadline = Date.now() + timeoutMs;
  while (!existsSync(path)) {
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await sleep(100);
  }
  return readFileSync(path, "utf8");
}

if (role === "stun") {
  const { StunMessage } = await import("../webrtc/js/stun.js");
  const { StunAttribute, StunMessageType } = await import("../webrtc/js/proto_gen.js");
  const { xorMappedAddress } = await import("../webrtc/js/stun.js");
  const [host, port] = args.addr.split(":");
  const socket = dgram.createSocket("udp4");
  socket.on("message", (msg, rinfo) => {
    const request = StunMessage.decode(msg);
    if (!request || request.type !== StunMessageType.BINDING_REQUEST) return;
    const resp = new StunMessage(StunMessageType.BINDING_SUCCESS);
    resp.transactionId = Buffer.from(request.transactionId);
    resp.attrs.push([
      StunAttribute.XOR_MAPPED_ADDRESS,
      xorMappedAddress({ address: rinfo.address, port: rinfo.port }, request.transactionId),
    ]);
    socket.send(resp.encode(null), rinfo.port, rinfo.address);
  });
  await new Promise((resolve) => socket.bind(Number(port), host, resolve));
  console.log(`stun server on ${args.addr}`);
  await waitFor("stop-stun", "stop-stun file", 10 * 60 * 1000).catch(() => {});
  process.exit(0);
}

const { Peer } = await import("../webrtc/js/peer.js");
const { Channel, Server } = await import("../js/index.js");
const { EchoRequest, EchoResponse } = await import("../js/examples/echo_pb.js");
const { EchoClient, createEchoService } = await import("../js/examples/echo_grpc_dc.js");

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

const req = (message, count = 0) => new EchoRequest({ message, count });
async function* fromList(items) {
  yield* items;
}

const result = { name: args.name, role, grpc: args.grpc, ok: false, checks: [] };
const fail = (err) => {
  result.error = String(err?.stack ?? err);
  writeFileSync(join(dir, `result-${args.name}.json`), JSON.stringify(result, null, 2));
  console.error(`[${args.name}] FAIL`, err);
  process.exit(1);
};

try {
  // Fixed local port: the harness NAT (scripts/nat-e2e.sh) is a
  // full-cone NAT with a pinned 1:1 port mapping for this port,
  // so the STUN-learned srflx endpoint is the endpoint peers
  // must use (endpoint-independent mapping).
  const socket = dgram.createSocket("udp4");
  await new Promise((resolve) => socket.bind(50000, "0.0.0.0", resolve));
  const peer = await Peer.createWithSocket(socket, { stunServers: [args.stun] });
  let endpoint;
  if (role === "offer") {
    const offer = peer.createOffer();
    result.srflx = offer.split("\r\n").find((l) => l.includes("typ srflx")) ?? null;
    if (!result.srflx) throw new Error(`no srflx candidate in offer:\n${offer}`);
    writeFileSync(join(dir, "offer.txt"), offer);
    const answer = await waitFor("answer.txt", "answer");
    peer.handleAnswer(answer);
    endpoint = await peer.connect();
  } else if (role === "answer") {
    const offer = await waitFor("offer.txt", "offer");
    const answer = peer.handleOffer(offer);
    result.srflx = answer.split("\r\n").find((l) => l.includes("typ srflx")) ?? null;
    if (!result.srflx) throw new Error(`no srflx candidate in answer:\n${answer}`);
    writeFileSync(join(dir, "answer.txt"), answer);
    endpoint = await peer.connect();
  } else {
    throw new Error(`unknown role ${role}`);
  }

  if (args.grpc === "server") {
    endpoint.onchannel = (channel) => {
      const server = new Server();
      server.addService(createEchoService(handlers));
      server.serve(channel);
    };
    result.ok = true;
    result.checks.push("serving");
    writeFileSync(join(dir, `result-${args.name}.json`), JSON.stringify(result, null, 2));
    console.log(`[${args.name}] serving gRPC over DataChannel`);
    await waitFor("stop", "stop file", 180000).catch(() => {});
    await peer.close();
    process.exit(0);
  }

  // gRPC client over the channel the peer opened.
  const client = new EchoClient(new Channel(endpoint.openChannel({ label: "grpc" })));
  const unary = await client.unary(req("hello-nat"));
  if (unary.message !== "echo: hello-nat") throw new Error(`unary: ${unary.message}`);
  result.checks.push("unary");

  const ticks = [];
  for await (const resp of await client.serverStream(req("tick", 3))) ticks.push(resp.index);
  if (JSON.stringify(ticks) !== "[0,1,2]") throw new Error(`serverStream: ${ticks}`);
  result.checks.push("serverStream");

  const joined = await client.clientStream(fromList([req("a"), req("b")]));
  if (joined.message !== "a+b") throw new Error(`clientStream: ${joined.message}`);
  result.checks.push("clientStream");

  const echoed = [];
  for await (const resp of await client.bidi(fromList([req("x"), req("y")]))) {
    echoed.push(resp.message);
  }
  if (JSON.stringify(echoed) !== '["x","y"]') throw new Error(`bidi: ${echoed}`);
  result.checks.push("bidi");

  result.ok = true;
  writeFileSync(join(dir, `result-${args.name}.json`), JSON.stringify(result, null, 2));
  console.log(`[${args.name}] gRPC across NAT OK (${result.checks.join(", ")}) srflx: ${result.srflx}`);
  writeFileSync(join(dir, `done-${args.name}`), "done");
  await peer.close();
  process.exit(0);
} catch (err) {
  fail(err);
}
