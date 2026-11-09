// Sustained-blast regression: 256 x 30KiB messages over a lossless
// in-order link must all arrive. Root cause of the original stall:
// onInitOrData retransmits SACK-cumulatively-acked-but-undelivered
// fragments; feed() keyed the retransmitted fragment as a fresh
// partial instead of the partial already holding its TSN, splitting
// one message across two partials that could never complete
// (the END-holding one is merge-exempt), wedging ordered delivery
// while SACKs kept acking.
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
    this.toServer([this.client.connect(this.now)]);
    assert.ok(this.client.isEstablished);
    assert.ok(this.server.isEstablished);
  }
}

test("sustained 256-message blast: every message delivered", () => {
  const link = new Link();
  link.handshake();
  const payload = Buffer.alloc(30000, 0x5a);
  const N = 256;
  let delivered = 0;
  for (let i = 0; i < N; i++) {
    const evts = link.toServer(link.client.sendData(0, 63, payload, {}, link.now));
    delivered += evts.filter((e) => e.type === "data").length;
    link.now += 1;
  }
  assert.equal(delivered, N, `delivered ${delivered}/${N}`);
});
