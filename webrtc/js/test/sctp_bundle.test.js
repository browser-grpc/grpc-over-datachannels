// SCTP bundling: small messages queued behind a full cwnd
// drain in fewer packets than chunks (RFC 9260 bundling),
// all payloads delivered intact. Mirrors the Rust/Go tests
// of the same name.
import assert from "node:assert/strict";
import test from "node:test";
import { loadSctpWasm } from "../sctp_wasm.js";
import { readFileSync } from "node:fs";

const { Association } = await loadSctpWasm(
  readFileSync(new URL("../../../browser-test/dc_sctp_gen/dc_sctp_wasm_bg.wasm", import.meta.url)),
);

test("small messages bundle on sack drain", () => {
  const now = 0;
  const client = Association.newClient();
  const server = Association.newServer();

  const init = client.connect(now);
  let r = server.handlePacket(init, now);
  r = client.handlePacket(r.packets[0], now);
  for (const p of r.packets) {
    const replies = server.handlePacket(p, now);
    for (const q of replies.packets) client.handlePacket(q, now);
  }
  assert.ok(client.isEstablished && server.isEstablished);

  const pump = (from, to, packets) => {
    const events = [];
    let pending = packets;
    while (pending.length) {
      const out = [];
      for (const p of pending) {
        const res = to.handlePacket(p, now);
        out.push(...res.packets);
        events.push(...res.events);
      }
      [from, to] = [to, from];
      pending = out;
    }
    return events;
  };

  // Fill the initial cwnd (4 * 1152 payload bytes) with held
  // packets; further sends queue in outQueue.
  const msg = Buffer.alloc(200, 7);
  const held = [];
  for (let i = 0; i < 40; i++) held.push(...client.sendData(1, 63, msg, {}, now));
  assert.ok(held.length > 0, "first window should emit packets");

  const events = pump(client, server, held);
  const delivered = events.filter(
    (e) => e.type === "data" && Buffer.compare(e.payload, msg) === 0,
  ).length;
  assert.equal(delivered, 40, "all bundled payloads delivered intact");

  const stats = client.stats();
  assert.ok(stats.chunksSent >= 40, `chunksSent ${stats.chunksSent}`);
  assert.ok(
    stats.packetsSent < stats.chunksSent,
    `bundling: ${stats.packetsSent} packets for ${stats.chunksSent} chunks`,
  );
});
