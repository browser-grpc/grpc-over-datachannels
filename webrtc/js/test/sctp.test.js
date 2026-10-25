// SCTP state machine tests over a simulated link — mirroring
// webrtc/rust/tests/sctp.rs so both implementations prove the same
// behaviours on the same scenarios.

import assert from "node:assert/strict";
import test from "node:test";
import { Association } from "../sctp.js";

class Link {
  constructor() {
    this.client = Association.newClient();
    this.server = Association.newServer();
    this.now = 0;
  }
  toServer(packets) {
    const events = [];
    for (const p of packets) {
      const r = this.server.handlePacket(p, this.now);
      events.push(...r.events);
      // SACK-clocked sends (cwnd) deliver via this nested call;
      // its events are part of the same exchange.
      events.push(...this.toClient(r.packets));
    }
    return events;
  }
  toClient(packets) {
    const events = [];
    for (const p of packets) {
      const r = this.client.handlePacket(p, this.now);
      events.push(...r.events);
      if (r.packets.length) events.push(...this.toServer(r.packets));
    }
    return events;
  }
  handshake() {
    const init = this.client.connect(this.now);
    this.toServer([init]);
    assert.ok(this.client.isEstablished);
    assert.ok(this.server.isEstablished);
  }
  clientSend(stream, ppid, payload, opts = {}) {
    return this.toServer(this.client.sendData(stream, ppid, payload, opts, this.now));
  }
}

test("handshake and ordered data", () => {
  const link = new Link();
  link.handshake();
  const events = link.clientSend(0, 63, Buffer.from("hello sctp"));
  assert.deepEqual(events, [
    { type: "data", stream: 0, ppid: 63, payload: Buffer.from("hello sctp") },
  ]);
});

test("fragmented message reassembles", () => {
  const link = new Link();
  link.handshake();
  const payload = Buffer.alloc(5000);
  for (let i = 0; i < payload.length; i++) payload[i] = i % 251;
  const events = link.clientSend(3, 54, payload);
  assert.equal(events.length, 1);
  assert.deepEqual(events[0].payload, payload);
});

test("loss and RTO retransmit", () => {
  const link = new Link();
  link.handshake();
  link.client.sendData(0, 63, Buffer.from("lost once"), {}, link.now); // dropped
  link.now += 1500;
  const { packets } = link.client.tick(link.now);
  assert.ok(packets.length > 0);
  const events = link.toServer(packets);
  assert.equal(events.length, 1);
});

test("partial reliability abandons and unblocks stream", () => {
  const link = new Link();
  link.handshake();
  link.client.sendData(0, 63, Buffer.from("doomed"), { maxRetransmits: 0 }, link.now); // dropped
  const second = link.client.sendData(0, 63, Buffer.from("survivor"), {}, link.now);
  assert.deepEqual(link.toServer(second), []);
  link.now += 1500;
  const { packets } = link.client.tick(link.now);
  const events = link.toServer(packets);
  assert.deepEqual(events.map((e) => e.payload?.toString()), ["survivor"]);
});
