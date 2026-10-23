// DataChannel close via SCTP stream reset (RFC 6525): both
// sides observe the close, a second channel keeps working, and
// a reset with an in-flight gap is deferred until cumulative.

import assert from "node:assert/strict";
import test from "node:test";
import { Peer } from "../peer.js";
import { Association } from "../sctp.js";

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function waitFor(fn, timeoutMs = 10000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const value = fn();
    if (value) return value;
    await sleep(20);
  }
  return null;
}

test("channel close resets the stream on both sides", { timeout: 30000 }, async (t) => {
  const offerer = await Peer.create({ localIps: ["127.0.0.1"] });
  const answerer = await Peer.create({ localIps: ["127.0.0.1"] });
  t.after(async () => {
    await offerer.close();
    await answerer.close();
  });
  const offer = offerer.createOffer();
  const answer = answerer.handleOffer(offer);
  offerer.handleAnswer(answer);
  const [epA, epB] = await Promise.all([offerer.connect(), answerer.connect()]);

  const messages = [];
  let remoteClosed = false;
  epB.onchannel = (channel) => {
    channel.onmessage = (event) => messages.push(Buffer.from(event.data).toString());
    channel.onclose = () => {
      remoteClosed = true;
    };
  };
  const ch1 = epA.openChannel({ label: "one" });
  let localClosed = false;
  ch1.onclose = () => {
    localClosed = true;
  };
  ch1.send(Buffer.from("before-close"));
  assert.equal(await waitFor(() => messages[0]), "before-close");

  ch1.close();
  assert.equal(await waitFor(() => localClosed || null), true);
  assert.equal(await waitFor(() => remoteClosed || null), true);
  assert.equal(ch1.readyState, "closed");

  const ch2 = epA.openChannel({ label: "two" });
  ch2.send(Buffer.from("after-close"));
  assert.equal(await waitFor(() => messages[1]), "after-close");
});

test("reset defers until sender-last-assigned TSN is cumulative", () => {
  const client = Association.newClient();
  const server = Association.newServer();
  const exchange = (assoc, packets, now = 0) => {
    let out = [];
    let events = [];
    for (const p of packets) {
      const r = assoc.handlePacket(p, now);
      out = out.concat(r.packets);
      events = events.concat(r.events);
    }
    return { packets: out, events };
  };
  let r = exchange(server, [client.connect(0)]);
  r = exchange(client, r.packets);
  r = exchange(server, r.packets);
  exchange(client, r.packets);
  assert.ok(client.isEstablished && server.isEstablished);

  const PPID_BINARY = 53;
  const pkts1 = client.sendData(0, PPID_BINARY, Buffer.from("first"), {}, 0);
  const pkts2 = client.sendData(0, PPID_BINARY, Buffer.from("second"), {}, 0);
  let res = exchange(server, pkts1);
  exchange(client, res.packets);
  assert.equal(res.events.filter((e) => e.type === "data").map((e) => e.payload.toString())[0], "first");

  const resetPkts = client.closeStream(0);
  res = exchange(server, resetPkts);
  assert.ok(!res.events.some((e) => e.type === "stream-reset"), "reset fired across a TSN gap");
  let clientPackets = res.packets;

  res = exchange(server, pkts2);
  clientPackets = clientPackets.concat(res.packets);
  assert.ok(res.events.some((e) => e.type === "data" && e.payload.toString() === "second"));

  // Server applied the deferred reset and auto-reset its own
  // outgoing side; one more round trip completes both sides.
  res = exchange(client, clientPackets);
  assert.ok(res.events.some((e) => e.type === "stream-reset"), "client never completed the close");
  res = exchange(server, res.packets);
  assert.ok(res.events.some((e) => e.type === "stream-reset"), "reset never applied after gap filled");
});
