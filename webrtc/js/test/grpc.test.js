// gRPC over the reimplemented WebRTC stack (ICE+DTLS+SCTP+DCEP):
// generated Echo client and server, two full JS peers.

import { test } from "node:test";
import assert from "node:assert/strict";

import { Peer } from "../peer.js";
import { Channel, Server } from "../../../js/index.js";
import { EchoRequest, EchoResponse } from "../../../js/examples/echo_pb.js";
import { EchoClient, createEchoService } from "../../../js/examples/echo_grpc_dc.js";

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

test("gRPC echo over the own WebRTC stack", { timeout: 60000 }, async (t) => {
  const offerer = await Peer.create({ localIps: ["127.0.0.1"] });
  const answerer = await Peer.create({ localIps: ["127.0.0.1"] });
  t.after(async () => {
    await offerer.close();
    await answerer.close();
  });

  const offer = offerer.createOffer();
  const answer = answerer.handleOffer(offer);
  offerer.handleAnswer(answer);

  const [offererEnd, answererEnd] = await Promise.all([offerer.connect(), answerer.connect()]);

  answererEnd.onchannel = (channel) => {
    const server = new Server();
    server.addService(createEchoService(handlers));
    server.serve(channel);
  };

  const client = new EchoClient(new Channel(offererEnd.openChannel({ label: "grpc" })));

  const unary = await client.unary(req("hello"));
  assert.equal(unary.message, "echo: hello");

  const ticks = [];
  for await (const resp of await client.serverStream(req("tick", 3))) ticks.push(resp.index);
  assert.deepEqual(ticks, [0, 1, 2]);

  const joined = await client.clientStream(fromList([req("a"), req("b")]));
  assert.equal(joined.message, "a+b");

  const echoed = [];
  for await (const resp of await client.bidi(fromList([req("x"), req("y")]))) {
    echoed.push(resp.message);
  }
  assert.deepEqual(echoed, ["x", "y"]);
});
