// LinkStats live (JS): DcEndpoint.linkStats() fills the SCTP
// leg on a live peer connection (TCP/HTTP2 legs stay null on
// a plain DataChannel).

import assert from "node:assert/strict";
import test from "node:test";

import { Peer } from "../peer.js";

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function waitFor(fn, timeoutMs = 15000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const v = fn();
    if (v) return v;
    await sleep(20);
  }
  return null;
}

test("DcEndpoint.linkStats fills the SCTP leg on a live call", { timeout: 60000 }, async (t) => {
  const offerer = await Peer.create({ localIps: ["127.0.0.1"] });
  const answerer = await Peer.create({ localIps: ["127.0.0.1"] });
  t.after(async () => {
    await offerer.close();
    await answerer.close();
  });
  const offer = offerer.createOffer();
  const answer = answerer.handleOffer(offer);
  offerer.handleAnswer(answer);
  const [offererEp, answererEp] = await Promise.all([offerer.connect(), answerer.connect()]);

  const channel = offererEp.openChannel({ label: "grpc" });
  answererEp.onchannel = (ch) => {
    ch.onmessage = (event) => {
      const data = Buffer.isBuffer(event.data) ? event.data : Buffer.from(event.data);
      ch.send(data);
    };
  };
  let reply = null;
  channel.onmessage = (event) => {
    reply = Buffer.isBuffer(event.data) ? event.data.toString() : String(event.data);
  };
  channel.send(Buffer.from("hello-stats"));
  const got = await waitFor(() => reply);
  assert.equal(got, "hello-stats");

  const stats = offererEp.linkStats();
  assert.ok(stats.sctp, "sctp leg missing");
  assert.ok(stats.sctp.chunksSent > 0, JSON.stringify(stats.sctp));
  assert.ok(stats.sctp.chunksReceived > 0, JSON.stringify(stats.sctp));
  assert.equal(stats.tcp, null);
  assert.equal(stats.http2, null);
});
