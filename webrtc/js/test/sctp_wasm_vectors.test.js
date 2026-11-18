// Shared-core conformance for the Wasm SCTP adapter: the
// fixtures/sctp_vectors.json scenarios plus the sack-drain
// bundling scenario, executed against the Rust core through
// sctp_wasm.js (mirrors sctp_vectors.test.js / the Rust and
// Go bundling tests).
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { loadSctpWasm } from "../sctp_wasm.js";

const pkgBytes = readFileSync(
  new URL("../../../browser-test/dc_sctp_gen/dc_sctp_wasm_bg.wasm", import.meta.url)
);
const { Association } = await loadSctpWasm(pkgBytes);

const file = JSON.parse(
  readFileSync(new URL("../../../fixtures/sctp_vectors.json", import.meta.url), "utf8")
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
  test(`sctp wasm vector: ${sc.name}`, () => {
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

test("wasm: small messages bundle on sack drain", () => {
  const now = 0;
  const client = Association.newClient();
  const server = Association.newServer();
  handshake(client, server, now);
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
  const msg = Buffer.alloc(200, 7);
  const held = [];
  for (let i = 0; i < 40; i++) held.push(...client.sendData(1, 63, msg, {}, now));
  assert.ok(held.length > 0, "first window should emit packets");
  const events = pump(client, server, held);
  const delivered = events.filter(
    (e) => e.type === "data" && Buffer.compare(e.payload, msg) === 0
  ).length;
  assert.equal(delivered, 40, "all bundled payloads delivered intact");
  const stats = client.stats();
  assert.ok(stats.chunksSent >= 40, `chunksSent ${stats.chunksSent}`);
  assert.ok(
    stats.packetsSent < stats.chunksSent,
    `bundling: ${stats.packetsSent} packets for ${stats.chunksSent} chunks`
  );
});
