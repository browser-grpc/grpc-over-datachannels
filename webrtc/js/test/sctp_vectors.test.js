// Generated conformance vectors (fixtures/sctp_vectors.json):
// all three mirrored SCTP stacks run
// the same fragment-delivery scenarios. Thin interpreter only —
// scenarios are generated data.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { Association } from "../sctp.js";

const file = JSON.parse(
  readFileSync(new URL("../../../fixtures/sctp_vectors.json", import.meta.url), "utf8"),
);

function handshake(client, server, now) {
  const init = client.connect(now);
  let r = server.handlePacket(init, now);
  r = client.handlePacket(r.packets[0], now);
  for (const p of r.packets) {
    const replies = server.handlePacket(p, now);
    for (const q of replies.packets) client.handlePacket(q, now);
  }
  assert.ok(client.isEstablished && server.isEstablished);
}

for (const sc of file.scenarios) {
  test(`sctp vector: ${sc.name}`, () => {
    const now = 0;
    const client = Association.newClient();
    const server = Association.newServer();
    handshake(client, server, now);
    const packets = [];
    const want = [];
    for (const m of sc.messages) {
      const payload = Buffer.alloc(m.size, m.fill);
      want.push(payload);
      packets.push(...client.sendData(sc.stream, 63, payload, {}, now));
    }
    const got = [];
    for (const idx of sc.deliver) {
      for (const ev of server.handlePacket(packets[idx], now).events) {
        if (ev.type === "data") got.push(ev.payload);
      }
    }
    assert.deepEqual(got, sc.expect.map((i) => want[i]));
  });
}
