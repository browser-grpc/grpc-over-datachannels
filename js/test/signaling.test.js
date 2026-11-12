import assert from "node:assert/strict";
import test from "node:test";

import { Channel, Server } from "../index.js";
import { EchoRequest, EchoResponse } from "../examples/echo_pb.js";
import { EchoClient, createEchoService } from "../examples/echo_grpc_dc.js";
import { serveHttpSignaling } from "../src/signaling_server.js";
import { signalCandidateViaHttp, signalRestartViaHttp } from "../src/signaling.js";
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

    // Every session peer lives on the handler's one shared
    // PeerMux socket: the answer's candidates carry its port.
    const mux = await httpServer.getSignalingMux();
    assert.ok(answer.sdp.includes(` ${mux.address().port} typ host`), "answer candidates use the mux port");

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

test("signaling session: trickle candidate POST and ICE restart", async () => {
  const httpServer = serveHttpSignaling(echoServer(), { host: "127.0.0.1", port: 0 });
  await new Promise((resolve) => httpServer.once("listening", resolve));
  const url = `http://127.0.0.1:${httpServer.address().port}/grpc-dc/signal`;
  const offerer = await Peer.create({ localIps: ["127.0.0.1"] });
  try {
    const res = await fetch(url, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ type: "offer", sdp: offerer.createOffer() }),
    });
    assert.equal(res.status, 200);
    const answer = await res.json();
    assert.ok(answer.session, "answer carries a session id");
    offerer.handleAnswer(answer.sdp);

    // Unknown sessions are rejected; a real candidate is accepted.
    const badCandidate = await fetch(`${url}/candidate`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ session: "nope", candidate: "candidate:1 1 udp 1 127.0.0.1 9 typ host" }),
    });
    assert.equal(badCandidate.status, 404);
    const candidate = offerer.localCandidateLines()[0]?.replace(/^a=/, "");
    if (candidate) {
      await signalCandidateViaHttp(url, answer.session, candidate);
    }

    const endpoint = await offerer.connect();
    const dc = endpoint.openChannel({ label: "grpc" });
    const client = new EchoClient(new Channel(dc));
    const before = await client.unary(new EchoRequest({ message: "before" }));
    assert.equal(before.message, "echo: before");

    // ICE restart over the same session, then the same channel works.
    const restartOffer = await offerer.createRestartOffer();
    const restartAnswer = await signalRestartViaHttp(url, answer.session, restartOffer);
    await offerer.handleRestartAnswer(restartAnswer);
    const after = await client.unary(new EchoRequest({ message: "after" }));
    assert.equal(after.message, "echo: after");

    dc.close();
    await endpoint.close();
  } finally {
    await offerer.close();
    httpServer.close();
    await httpServer.closeSignaling();
  }
});
