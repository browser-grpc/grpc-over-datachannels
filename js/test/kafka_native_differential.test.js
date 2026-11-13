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
  CloseShareGroupRequest,
  DescribeShareGroupsRequest,
  EndTransactionRequest,
  ListOffsetsRequest,
  NewTopic,
  OpenProducerRequest,
  OpenShareGroupRequest,
  ProduceRequest,
  Record,
  ShareAckEntry,
  ShareAckRequest,
  SharePollRequest,
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

test("js differential: transactional read_committed across proxy and native", { skip: SKIP }, async (t) => {
  const native = new KafkaNativeClient(BROKER);
  const { client: proxy, dc } = proxyClient();
  const topic = `js-kafka-txn-${randomUUID().slice(0, 8)}`;
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

  // Transactional produce through one form factor,
  // read_committed consume through the other (mirrors the
  // Python differential): committed records are visible,
  // aborted ones are not.
  async function txn(client, label, commit) {
    const opened = await client.openProducer(new OpenProducerRequest({
      transactionalId: `grpc-dc-js-diff-txn-${label}-${randomUUID().slice(0, 8)}`,
      transactionTimeoutMs: 60000,
    }));
    assert.equal(opened.errorCode, 0, String(opened.errorCode));
    const produced = await client.produce(new ProduceRequest({
      topic,
      partition: 0,
      records: [new Record({ value: enc(label) })],
      acks: Acks.ACKS_ALL,
      sessionId: opened.sessionId,
    }));
    assert.equal(produced.errorCode, 0, String(produced.errorCode));
    const ended = await client.endTransaction(new EndTransactionRequest({
      sessionId: opened.sessionId,
      commit,
    }));
    assert.equal(ended.errorCode, 0, String(ended.errorCode));
  }

  async function consumeCommitted(client, isNative, want) {
    const values = [];
    const deadline = Date.now() + 20000;
    while (Date.now() < deadline) {
      const stream = isNative
        ? native.consume(new ConsumeRequest({
          topic, partition: 0, offset: -2n, maxRecords: 10, maxWaitMs: 1000, readCommitted: true,
        }))
        : await client.consume(new ConsumeRequest({
          topic, partition: 0, offset: -2n, maxRecords: 10, maxWaitMs: 1000, readCommitted: true,
        }));
      try {
        for await (const chunk of stream) {
          assert.equal(chunk.errorCode, 0);
          for (const r of chunk.records) values.push(dec(r.value));
          if (values.length >= want) break;
        }
      } finally {
        stream.close?.();
      }
      if (values.length >= want) break;
      values.length = 0;
      await sleep(250);
    }
    return values;
  }

  await txn(proxy, "tx-proxy-commit", true);
  await txn(proxy, "tx-proxy-abort", false);
  assert.deepEqual(await consumeCommitted(native, true, 1), ["tx-proxy-commit"]);

  await txn(native, "tx-native-commit", true);
  await txn(native, "tx-native-abort", false);
  assert.deepEqual(
    await consumeCommitted(proxy, false, 2),
    ["tx-proxy-commit", "tx-native-commit"],
  );
});

test("js differential: share groups across proxy and native (KIP-932 77/78/79)", { skip: SKIP }, async (t) => {
  // Share APIs through both form factors against one broker:
  // proxy produces, the native client share-consumes and
  // ACCEPTs; native produces, the proxy share-consumes,
  // RELEASEs, and sees redelivery. Brokers without share-group
  // support refuse the open; skip there (mirrors kafka.test.js).
  const native = new KafkaNativeClient(BROKER);
  const { client: proxy, dc } = proxyClient();
  const topic = `js-kafka-share-${randomUUID().slice(0, 8)}`;
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

  async function shareRound(client, label) {
    const group = `js-share-diff-${label}-${randomUUID().slice(0, 8)}`;
    let opened;
    try {
      opened = await client.openShareGroup(new OpenShareGroupRequest({ groupId: group, topics: [topic] }));
    } catch (err) {
      return { skipped: `share group open raised: ${err.message}` };
    }
    if (opened.errorCode !== 0) return { skipped: `broker refused share group (error ${opened.errorCode})` };
    const session = opened.sessionId;
    assert.ok(session);
    const poll = async (want) => {
      const out = [];
      const deadline = Date.now() + 30000;
      while (out.length < want && Date.now() < deadline) {
        const resp = await client.sharePoll(new SharePollRequest({
          sessionId: session, maxRecords: 10, maxWaitMs: 500,
        }));
        assert.equal(resp.errorCode, 0);
        out.push(...resp.records);
        if (out.length === 0) await sleep(200);
      }
      return out;
    };
    // Initialize the share partition start offset before producing.
    await client.sharePoll(new SharePollRequest({ sessionId: session, maxRecords: 10, maxWaitMs: 500 }));
    return { group, session, poll, client };
  }

  async function produce(client, values) {
    const produced = await client.produce(new ProduceRequest({
      topic,
      partition: 0,
      records: values.map((v) => new Record({ value: enc(v) })),
      acks: Acks.ACKS_ALL,
    }));
    assert.equal(produced.errorCode, 0);
  }

  // Proxy produces -> native share-consumes + ACCEPT retires.
  const nativeRound = await shareRound(native, "native");
  if (nativeRound.skipped) return t.skip(nativeRound.skipped);
  await produce(proxy, ["s1", "s2"]);
  const first = await nativeRound.poll(2);
  assert.equal(first.length, 2, "native share delivery timed out");
  assert.deepEqual(first.map((r) => dec(r.value)), ["s1", "s2"]);
  assert.ok(first.every((r) => r.deliveryCount === 1));
  const acked = await native.shareAck(new ShareAckRequest({
    sessionId: nativeRound.session,
    entries: first.map((r) => new ShareAckEntry({ topic, partition: 0, offset: r.offset, ackType: 1 })),
  }));
  assert.equal(acked.errorCode, 0);
  const described = await native.describeShareGroups(
    new DescribeShareGroupsRequest({ groupIds: [nativeRound.group] }));
  assert.equal(described.errorCode, 0);
  await native.closeShareGroup(new CloseShareGroupRequest({ sessionId: nativeRound.session }));

  // Native produces -> proxy share-consumes, RELEASE redelivers.
  const proxyRound = await shareRound(proxy, "proxy");
  if (proxyRound.skipped) return t.skip(proxyRound.skipped);
  await produce(native, ["s3"]);
  const third = await proxyRound.poll(1);
  assert.equal(third.length, 1, "proxy share delivery timed out");
  assert.equal(dec(third[0].value), "s3");
  const released = await proxy.shareAck(new ShareAckRequest({
    sessionId: proxyRound.session,
    entries: [new ShareAckEntry({ topic, partition: 0, offset: third[0].offset, ackType: 2 })],
  }));
  assert.equal(released.errorCode, 0);
  const redelivered = await proxyRound.poll(1);
  assert.equal(redelivered.length, 1, "release redelivery timed out");
  assert.equal(redelivered[0].offset, third[0].offset);
  assert.equal(redelivered[0].deliveryCount, 2);
  await proxy.closeShareGroup(new CloseShareGroupRequest({ sessionId: proxyRound.session }));
});
