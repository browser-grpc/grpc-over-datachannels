// DC message chunking (Peer chunkMessages): binary messages
// over 64 KiB cross the endpoint as [0xF0, flags] chunks and
// reassemble whole — the path that lets browser peers (256 KiB
// RTCDataChannel message cap) exchange multi-MB grpc-dc
// frames. Mirrors js/test/chunking.test.js (runtime shim).

import assert from "node:assert/strict";
import test from "node:test";
import { Peer } from "../peer.js";

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function echoPair(chunkMessages, size) {
  const offerer = await Peer.create({ localIps: ["127.0.0.1"], chunkMessages });
  const answerer = await Peer.create({ localIps: ["127.0.0.1"], chunkMessages });
  try {
    const offer = offerer.createOffer();
    offerer.handleAnswer(answerer.handleOffer(offer));
    const [oEp, aEp] = await Promise.all([offerer.connect(), answerer.connect()]);
    const channel = oEp.openChannel({ label: "chunk" });
    aEp.onchannel = (ch) => {
      ch.onmessage = (e) => ch.send(e.data);
    };
    let reply = null;
    channel.onmessage = (e) => {
      reply = Buffer.isBuffer(e.data) ? e.data : Buffer.from(e.data);
    };
    const big = Buffer.alloc(size, 65);
    channel.send(big);
    const deadline = Date.now() + 30000;
    while (!reply && Date.now() < deadline) await sleep(25);
    assert.ok(reply, "no echo");
    assert.ok(reply.equals(big), `echo mismatch at ${size} bytes`);
  } finally {
    await offerer.close();
    await answerer.close();
  }
}

test("chunked peers echo 1 MiB", { timeout: 60000 }, async () => {
  await echoPair(true, 1024 * 1024);
});

test("chunked peers keep small messages intact", { timeout: 60000 }, async () => {
  await echoPair(true, 100);
});
