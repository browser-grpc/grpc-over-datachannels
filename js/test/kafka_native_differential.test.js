// Kafka differential (JS): the same scenario through both
// form factors against the same broker — proxy-produced
// records must read back identically through the in-process
// native client, and vice versa.
//
// Env-gated: KAFKA_E2E_BROKER=host:port (broker),
// KAFKA_E2E_PROXY_ADDR=host:port (kafka_proxy --tcp), and
// GRPC_DC_KAFKA_NATIVE_ADDON=kafka_native_addon.node (see
// scripts/kafka-e2e.sh / `make test-kafka`). Skipped
// otherwise.

import assert from "node:assert/strict";
import { connect } from "node:net";
import { randomUUID } from "node:crypto";
import test from "node:test";

import { Channel } from "../index.js";
import { KafkaClient } from "../src/kafka_grpc_dc.js";
import { KafkaNativeClient } from "../src/kafka_native.js";
import {
  Acks,
  ConsumeRequest,
  CreateTopicsRequest,
  DeleteTopicsRequest,
  ListOffsetsRequest,
  NewTopic,
  ProduceRequest,
  Record,
} from "../src/kafka_pb.js";

const BROKER = process.env.KAFKA_E2E_BROKER ?? "";
const PROXY_ADDR = process.env.KAFKA_E2E_PROXY_ADDR ?? "";
const SKIP = !BROKER || !PROXY_ADDR;
const enc = (s) => new TextEncoder().encode(s);
const dec = (b) => new TextDecoder().decode(b);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** One length-prefixed TCP connection as a DataChannel-like object. */
function tcpDataChannel(host, port) {
  const socket = connect(port, host);
  let buffer = Buffer.alloc(0);
  const dc = {
    readyState: "open",
    onmessage: null,
    send(data) {
      const payload = Buffer.from(data instanceof Uint8Array ? data : new Uint8Array(data));
      const frame = Buffer.alloc(4 + payload.length);
      frame.writeUInt32BE(payload.length, 0);
      payload.copy(frame, 4);
      socket.write(frame);
    },
    close() {
      socket.destroy();
    },
  };
  socket.on("data", (chunk) => {
    buffer = Buffer.concat([buffer, chunk]);
    while (buffer.length >= 4) {
      const len = buffer.readUInt32BE(0);
      if (buffer.length < 4 + len) break;
      const msg = new Uint8Array(buffer.subarray(4, 4 + len));
      buffer = buffer.subarray(4 + len);
      dc.onmessage?.({ data: msg.buffer.slice(msg.byteOffset, msg.byteOffset + msg.byteLength) });
    }
  });
  return dc;
}

function proxyClient() {
  const sep = PROXY_ADDR.lastIndexOf(":");
  const dc = tcpDataChannel(PROXY_ADDR.slice(0, sep), Number(PROXY_ADDR.slice(sep + 1)));
  return { client: new KafkaClient(new Channel(dc)), dc };
}

async function consumeNative(native, topic, offset, want) {
  const values = [];
  const stream = native.consume(new ConsumeRequest({
    topic, partition: 0, offset: BigInt(offset), maxRecords: 10, maxWaitMs: 2000,
  }));
  for await (const chunk of stream) {
    assert.equal(chunk.errorCode, 0);
    for (const r of chunk.records) values.push(dec(r.value));
    if (values.length >= want) break;
  }
  stream.close();
  return values;
}

async function consumeProxy(proxy, topic, offset, want) {
  const values = [];
  const stream = await proxy.consume(new ConsumeRequest({
    topic, partition: 0, offset: BigInt(offset), maxRecords: 10, maxWaitMs: 2000,
  }));
  for await (const chunk of stream) {
    assert.equal(chunk.errorCode, 0);
    for (const r of chunk.records) values.push(dec(r.value));
    if (values.length >= want) break;
  }
  return values;
}

test("js differential: proxy vs native record-for-record", { skip: SKIP }, async (t) => {
  const native = new KafkaNativeClient(BROKER);
  const { client: proxy, dc } = proxyClient();
  const topic = `js-kafka-diff-${randomUUID().slice(0, 8)}`;
  t.after(async () => {
    try {
      await native.deleteTopics(new DeleteTopicsRequest({ topics: [topic], timeoutMs: 15000 }));
    } catch { /* best effort */ }
    native.close();
    dc.close();
  });

  const created = await native.createTopics(new CreateTopicsRequest({
    topics: [new NewTopic({ name: topic, numPartitions: 1, replicationFactor: 1 })],
    timeoutMs: 15000,
  }));
  assert.equal(created.results[0].errorCode, 0);
  const deadline = Date.now() + 15000;
  for (;;) {
    const latest = await native.listOffsets(new ListOffsetsRequest({
      topic, partition: 0, timestamp: -1n,
    }));
    if (latest.errorCode === 0) break;
    assert.ok(Date.now() < deadline, "topic never ready");
    await sleep(250);
  }

  // Proxy produces, native consumes.
  let produced = await proxy.produce(new ProduceRequest({
    topic,
    partition: 0,
    records: ["p1", "p2"].map((v) => new Record({ value: enc(v) })),
    acks: Acks.ACKS_ALL,
  }));
  assert.equal(produced.errorCode, 0);
  assert.deepEqual(await consumeNative(native, topic, -2, 2), ["p1", "p2"]);

  // Native produces, proxy consumes.
  produced = await native.produce(new ProduceRequest({
    topic,
    partition: 0,
    records: [new Record({ value: enc("n1") })],
    acks: Acks.ACKS_ALL,
  }));
  assert.equal(produced.errorCode, 0);
  assert.deepEqual(await consumeProxy(proxy, topic, 2, 1), ["n1"]);

  // Compressed batch through the proxy, read natively.
  const payload = ["z1", "z2", "z3"];
  produced = await proxy.produce(new ProduceRequest({
    topic,
    partition: 0,
    records: payload.map((v) => new Record({ value: enc(v) })),
    acks: Acks.ACKS_ALL,
    compression: 4, // COMPRESSION_ZSTD
  }));
  assert.equal(produced.errorCode, 0);
  assert.deepEqual(await consumeNative(native, topic, 3, 3), payload);
});
