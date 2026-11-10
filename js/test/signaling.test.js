import assert from "node:assert/strict";
import test from "node:test";

import { Channel, Server } from "../index.js";
import { EchoRequest, EchoResponse } from "../examples/echo_pb.js";
import { EchoClient, createEchoService } from "../examples/echo_grpc_dc.js";
import { serveHttpSignaling } from "../src/signaling_server.js";
import { Peer } from "../../webrtc/js/peer.js";

function echoServer() {
  const server = new Server();
  server.addService(
    createEchoService({
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
    }),
  );
  return server;
}

async function post(port, path, body, method = "POST") {
  return fetch(`http://127.0.0.1:${port}${path}`, {
    method,
    headers: { "content-type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

test("HTTP/POST signaling: offer in, answer out, Echo over the channel", async () => {
  const httpServer = serveHttpSignaling(echoServer(), { host: "127.0.0.1", port: 0 });
  await new Promise((resolve) => httpServer.once("listening", resolve));
  const port = httpServer.address().port;
  const offerer = await Peer.create({ localIps: ["127.0.0.1"] });
  try {
    // Contract negatives first: wrong method and malformed body.
    const getRes = await post(port, "/grpc-dc/signal", undefined, "GET");
    assert.equal(getRes.status, 405);
    const badRes = await post(port, "/grpc-dc/signal", { type: "offer", sdp: "" });
    assert.equal(badRes.status, 400);

    const offer = offerer.createOffer();
    const res = await post(port, "/grpc-dc/signal", { type: "offer", sdp: offer });
    assert.equal(res.status, 200);
    const answer = await res.json();
    assert.equal(answer.type, "answer");
    assert.equal(typeof answer.sdp, "string");
    assert.match(answer.sdp, /a=setup:active/);

    offerer.handleAnswer(answer.sdp);
    const endpoint = await offerer.connect();
    const dc = endpoint.openChannel({ label: "grpc" });
    const client = new EchoClient(new Channel(dc));
    const unary = await client.unary(new EchoRequest({ message: "hello" }));
    assert.equal(unary.message, "echo: hello");
    dc.close();
    await endpoint.close();
  } finally {
    await offerer.close();
    httpServer.close();
    await httpServer.closeSignaling();
  }
});
