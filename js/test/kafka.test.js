// Kafka proxy end-to-end: generated JS client -> Rust kafka_proxy
// (--tcp) -> Apache Kafka / Redpanda.
//
// Env-gated: set KAFKA_E2E_PROXY_ADDR=host:port of a running
// kafka_proxy (see scripts/kafka-e2e.sh / `make test-kafka`).
// Skipped otherwise, so the plain `make test-js` run stays
// broker-free.

import assert from "node:assert/strict";
import { connect } from "node:net";
import { randomUUID } from "node:crypto";
import test from "node:test";

import { Channel } from "../index.js";
import { http2Channel } from "../src/http2.js";
import { KafkaClient } from "../src/kafka_grpc_dc.js";
import {
  ConsumeRequest,
  CreateTopicsRequest,
  DeleteTopicsRequest,
  ListOffsetsRequest,
  NewTopic,
  ProduceRequest,
  Record,
} from "../src/kafka_pb.js";

const PROXY_ADDR = process.env.KAFKA_E2E_PROXY_ADDR ?? "";
// HTTP/2 ingress (stock gRPC transport -> grpc-dc-proxy ->
// kafka_proxy --webrtc-direct): authority of the bridge.
const HTTP2_ADDR = process.env.KAFKA_E2E_HTTP2_ADDR ?? "";
const enc = (s) => new TextEncoder().encode(s);
const dec = (b) => new TextDecoder().decode(b);

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

async function makeClient(t) {
  const sep = PROXY_ADDR.lastIndexOf(":");
  const dc = tcpDataChannel(PROXY_ADDR.slice(0, sep), Number(PROXY_ADDR.slice(sep + 1)));
  const client = new KafkaClient(new Channel(dc));
  const topic = `js-kafka-e2e-${randomUUID().slice(0, 16)}`;
  const created = await client.createTopics(
    new CreateTopicsRequest({
      topics: [new NewTopic({ name: topic, numPartitions: 1, replicationFactor: 1 })],
      timeoutMs: 15000,
    }),
  );
  assert.deepEqual(created.results.map((r) => r.errorCode), [0]);
  // Wait until the partition is visible.
  for (let i = 0; i < 60; i++) {
    const latest = await client.listOffsets(
      new ListOffsetsRequest({ topic, partition: 0, timestamp: -1n }),
    );
    if (latest.errorCode === 0) break;
    await new Promise((r) => setTimeout(r, 250));
  }
  t.after(async () => {
    try {
      await client.deleteTopics(new DeleteTopicsRequest({ topics: [topic] }));
    } catch {
      /* best effort */
    }
    dc.close();
  });
  return { client, topic };
}

async function produce(client, topic, values) {
  const offsets = [];
  for (const value of values) {
    const resp = await client.produce(
      new ProduceRequest({
        topic,
        partition: 0,
        records: [new Record({ key: enc(`k-${value}`), value: enc(value) })],
      }),
    );
    assert.equal(resp.errorCode, 0);
    offsets.push(Number(resp.baseOffset));
  }
  return offsets;
}

async function consume(client, topic, offset, count) {
  const got = [];
  const stream = await client.consume(
    new ConsumeRequest({ topic, partition: 0, offset: BigInt(offset), maxRecords: count }),
  );
  for await (const chunk of stream) {
    assert.equal(chunk.errorCode, 0);
    got.push(...chunk.records);
    if (got.length >= count) break;
  }
  return got;
}

test("kafka produce/consume roundtrip", { skip: !PROXY_ADDR }, async (t) => {
  const { client, topic } = await makeClient(t);
  assert.deepEqual(await produce(client, topic, ["v0", "v1", "v2"]), [0, 1, 2]);
  const latest = await client.listOffsets(
    new ListOffsetsRequest({ topic, partition: 0, timestamp: -1n }),
  );
  assert.equal(Number(latest.offset), 3);
  assert.equal(latest.errorCode, 0);
  const got = await consume(client, topic, 0, 3);
  assert.deepEqual(got.map((r) => dec(r.value)), ["v0", "v1", "v2"]);
  assert.deepEqual(got.map((r) => dec(r.key)), ["k-v0", "k-v1", "k-v2"]);
});

test("kafka per-partition ordering", { skip: !PROXY_ADDR }, async (t) => {
  const { client, topic } = await makeClient(t);
  const values = Array.from({ length: 10 }, (_, i) => `seq-${String(i).padStart(2, "0")}`);
  assert.deepEqual(await produce(client, topic, values), values.map((_, i) => i));
  const got = await consume(client, topic, 0, 10);
  assert.deepEqual(got.map((r) => dec(r.value)), values);
});

test("kafka offset resume", { skip: !PROXY_ADDR }, async (t) => {
  const { client, topic } = await makeClient(t);
  await produce(client, topic, ["a", "b", "c", "d"]);
  const first = await consume(client, topic, 0, 2);
  assert.deepEqual(first.map((r) => dec(r.value)), ["a", "b"]);
  const rest = await consume(client, topic, 2, 2);
  assert.deepEqual(rest.map((r) => dec(r.value)), ["c", "d"]);
});

test("kafka over HTTP/2 ingress", { skip: !HTTP2_ADDR }, async (t) => {
  const channel = http2Channel(HTTP2_ADDR);
  const client = new KafkaClient(channel);
  const topic = `js-kafka-http2-${randomUUID().slice(0, 16)}`;
  t.after(() => channel.endpoint.dataChannel.close());
  t.after(async () => {
    try {
      await client.deleteTopics(new DeleteTopicsRequest({ topics: [topic] }));
    } catch {
      /* best effort */
    }
  });
  const created = await client.createTopics(
    new CreateTopicsRequest({
      topics: [new NewTopic({ name: topic, numPartitions: 1, replicationFactor: 1 })],
      timeoutMs: 15000,
    }),
  );
  assert.deepEqual(created.results.map((r) => r.errorCode), [0]);
  assert.deepEqual(await produce(client, topic, ["v0", "v1", "v2"]), [0, 1, 2]);
  const got = await consume(client, topic, 0, 3);
  assert.deepEqual(got.map((r) => dec(r.value)), ["v0", "v1", "v2"]);
});
