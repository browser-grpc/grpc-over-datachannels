import assert from "node:assert/strict";
import test from "node:test";

import {
  DcChunkReassembler,
  MAX_DC_CHUNK_PAYLOAD,
  chunkedDataChannel,
  memoryDataChannelPair,
  splitDcMessage,
} from "../index.js";

test("small messages pass through byte-identical", () => {
  const msg = new Uint8Array([1, 2, 3, 4]);
  assert.deepEqual(splitDcMessage(msg), [msg]);
  const r = new DcChunkReassembler();
  assert.deepEqual(r.push(msg), msg);
});

test("split + reassemble round-trips 2 MiB", () => {
  const big = new Uint8Array(2 * 1024 * 1024);
  for (let i = 0; i < big.length; i++) big[i] = i % 251;
  const chunks = splitDcMessage(big);
  assert.ok(chunks.length > 2, "split into many chunks");
  assert.ok(chunks.every((c) => c.length <= MAX_DC_CHUNK_PAYLOAD + 2));
  const r = new DcChunkReassembler();
  let whole = null;
  for (const c of chunks) {
    const out = r.push(c);
    if (out !== null) whole = out;
  }
  assert.deepEqual(whole, big);
});

test("chunk header never collides with a grpc-dc frame type", () => {
  // 0xF0 is not a valid frame type (0x01..0x05), so a legacy
  // endpoint ignores chunk messages per the forward-compat
  // rule instead of decoding garbage.
  const chunks = splitDcMessage(new Uint8Array(MAX_DC_CHUNK_PAYLOAD + 1));
  assert.equal(chunks[0][0], 0xf0);
});

test("chunkedDataChannel pair moves 1 MiB each way; raw peer still works", async () => {
  const [a, b] = memoryDataChannelPair();
  const ca = chunkedDataChannel(a);
  const cb = chunkedDataChannel(b);
  const big = new Uint8Array(1024 * 1024).fill(7);
  const gotB = new Promise((res) => cb.addEventListener("message", (e) => res(e.data)));
  ca.send(big);
  assert.deepEqual(new Uint8Array(await gotB), big);

  const gotA = new Promise((res) => ca.addEventListener("message", (e) => res(e.data)));
  const small = new Uint8Array([9, 9, 9]);
  b.send(small); // raw (unchunked wrapper) send still delivers
  assert.deepEqual(new Uint8Array(await gotA), small);
});
