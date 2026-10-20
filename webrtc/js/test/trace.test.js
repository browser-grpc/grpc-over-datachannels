// Stack tracing parity: Peer.connect emits ice.nominated,
// dtls.handshake, endpoint.ready to the registered observer;
// dormant (and harmless) with none, and a throwing observer
// cannot break the connection.

import assert from "node:assert/strict";
import test from "node:test";
import { Peer } from "../peer.js";
import { setStackObserver } from "../trace.js";

async function connectPair() {
  const offerer = await Peer.create({ localIps: ["127.0.0.1"] });
  const answerer = await Peer.create({ localIps: ["127.0.0.1"] });
  const offer = offerer.createOffer();
  const answer = answerer.handleOffer(offer);
  offerer.handleAnswer(answer);
  const [a, b] = await Promise.all([offerer.connect(), answerer.connect()]);
  await offerer.close();
  await answerer.close();
  return [a, b];
}

test("connect emits stack events", { timeout: 60000 }, async () => {
  const events = [];
  setStackObserver((e) => events.push(e));
  try {
    await connectPair();
  } finally {
    setStackObserver(null);
  }
  for (const name of ["ice.nominated", "dtls.handshake", "endpoint.ready"]) {
    assert.equal(events.filter((e) => e.name === name).length, 2, `two ${name}: ${JSON.stringify(events)}`);
  }
  assert.ok(events.filter((e) => e.name === "dtls.handshake").every((e) => e.detail === "full"));
  const roles = events.filter((e) => e.name === "endpoint.ready").map((e) => e.detail).sort();
  assert.deepEqual(roles, ["client", "server"]);
});

test("dormant and throwing observers are safe", { timeout: 60000 }, async () => {
  setStackObserver(null);
  await connectPair();
  setStackObserver(() => { throw new Error("observer blew up"); });
  try {
    await connectPair();
  } finally {
    setStackObserver(null);
  }
});
