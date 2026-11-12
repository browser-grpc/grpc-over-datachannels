// Kafka native end-to-end (JS): generated kafka_pb.js
// messages -> libkafka_native in-process via the N-API
// addon (no proxy, no gRPC hop).
//
// Env-gated: KAFKA_E2E_BROKER=host:port and
// GRPC_DC_KAFKA_NATIVE_ADDON=path to kafka_native_addon.node
// (see scripts/kafka-e2e.sh / `make test-kafka`). Skipped
// otherwise, so the plain `make test-js` run stays
// broker-free.

import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import test from "node:test";

import { KafkaNativeClient } from "../src/kafka_native.js";
import {
  Acks,
  ConsumeRequest,
  CreateTopicsRequest,
  DeleteTopicsRequest,
  ListOffsetsRequest,
  MetadataRequest,
  NewTopic,
  ProduceRequest,
  Record,
} from "../src/kafka_pb.js";

const BROKER = process.env.KAFKA_E2E_BROKER ?? "";
const enc = (s) => new TextEncoder().encode(s);
const dec = (b) => new TextDecoder().decode(b);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

test("KafkaNativeClient roundtrip", { skip: !BROKER }, async () => {
  const client = new KafkaNativeClient(BROKER);
  const topic = `js-kafka-native-${randomUUID().slice(0, 8)}`;
  try {
    const created = await client.createTopics(new CreateTopicsRequest({
      topics: [new NewTopic({
        name: topic, numPartitions: 1, replicationFactor: 1,
      })],
      timeoutMs: 15000,
    }));
    assert.equal(created.results.length, 1);
    assert.equal(created.results[0].errorCode, 0);

    const deadline = Date.now() + 15000;
    for (;;) {
      const meta = await client.metadata(
        new MetadataRequest({ topics: [topic] }));
      const ready = meta.topics.some(
        (t) => t.name === topic && t.partitions.length > 0);
      if (ready) break;
      assert.ok(Date.now() < deadline, "topic not visible");
      await sleep(250);
    }

    const produced = await client.produce(new ProduceRequest({
      topic,
      partition: 0,
      records: ["one", "two", "three"].map(
        (v) => new Record({ value: enc(v) })),
      acks: Acks.ACKS_ALL,
    }));
    assert.equal(produced.errorCode, 0);

    const stream = client.consume(new ConsumeRequest({
      topic, partition: 0, offset: -2n, maxRecords: 10, maxWaitMs: 2000,
    }));
    const values = [];
    for await (const chunk of stream) {
      assert.equal(chunk.errorCode, 0);
      for (const r of chunk.records) values.push(dec(r.value));
      if (values.length >= 3) break;
    }
    stream.close();
    assert.deepEqual(values, ["one", "two", "three"]);

    const latest = await client.listOffsets(new ListOffsetsRequest({
      topic, partition: 0, timestamp: -1n,
    }));
    assert.equal(latest.errorCode, 0);
    assert.equal(latest.offset, 3n);
  } finally {
    await client.deleteTopics(new DeleteTopicsRequest({
      topics: [topic], timeoutMs: 15000,
    }));
    client.close();
  }
});
