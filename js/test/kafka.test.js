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
  CloseShareGroupRequest,
  ConsumeRequest,
  CreateTopicsRequest,
  DeleteTopicsRequest,
  DescribeGroupsRequest,
  GroupSubscribeRequest,
  ListOffsetsRequest,
  NewTopic,
  OpenShareGroupRequest,
  ProduceRequest,
  Record,
  ShareAckEntry,
  ShareAckRequest,
  SharePollRequest,
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
  // Register cleanup first: if setup fails below, the socket
  // must still close or the test process never exits.
  t.after(async () => {
    try {
      await client.deleteTopics(new DeleteTopicsRequest({ topics: [topic] }));
    } catch {
      /* best effort */
    }
    dc.close();
  });
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

test("kafka share group accept/release redelivery", { skip: !PROXY_ADDR }, async (t) => {
  // KIP-932 via the session RPCs: ACCEPT retires, RELEASE
  // redelivers with deliveryCount incremented. Brokers without
  // share-group support (e.g. Redpanda) refuse the open; skip.
  const { client, topic } = await makeClient(t);
  const group = `js-share-group-${randomUUID().slice(0, 16)}`;
  let opened;
  try {
    opened = await client.openShareGroup(
      new OpenShareGroupRequest({ groupId: group, topics: [topic] }),
    );
  } catch (err) {
    return t.skip(`share group open raised: ${err.message}`);
  }
  if (opened.errorCode !== 0) {
    return t.skip(`broker refused share group (error ${opened.errorCode})`);
  }
  const session = opened.sessionId;
  assert.ok(session);
  // Assignment settles asynchronously (bounded in the service);
  // it may still be empty here under load. Delivery below is
  // what proves it arrived.
  assert.ok(opened.assignment);

  const poll = async (want) => {
    const out = [];
    const deadline = Date.now() + 30000;
    while (out.length < want && Date.now() < deadline) {
      const resp = await client.sharePoll(
        new SharePollRequest({ sessionId: session, maxRecords: 10, maxWaitMs: 500 }),
      );
      assert.equal(resp.errorCode, 0);
      out.push(...resp.records);
      if (out.length === 0) await new Promise((r) => setTimeout(r, 200));
    }
    return out;
  };

  // A share partition's start offset is taken at its first
  // fetch; initialize it before producing.
  const init = await client.sharePoll(
    new SharePollRequest({ sessionId: session, maxRecords: 10, maxWaitMs: 500 }),
  );
  assert.equal(init.errorCode, 0);
  assert.deepEqual(init.records, []);

  await produce(client, topic, ["s1", "s2"]);
  const first = await poll(2);
  if (first.length === 0 && opened.assignment.partitions.length === 0) {
    // The coordinator never assigned and nothing delivers:
    // this broker cannot initialize share state (e.g. a
    // combined-mode SASL fixture whose share persister cannot
    // authenticate internally — the reference share consumer
    // stalls identically there). Delivery failures WITH an
    // assignment still fail below.
    return t.skip("share assignment never delivered on this broker");
  }
  assert.equal(first.length, 2, "share delivery timed out");
  assert.deepEqual(first.map((r) => dec(r.value)), ["s1", "s2"]);
  assert.ok(first.every((r) => r.deliveryCount === 1));

  const acked = await client.shareAck(
    new ShareAckRequest({
      sessionId: session,
      entries: first.map(
        (r) => new ShareAckEntry({ topic, partition: 0, offset: r.offset, ackType: 1 }),
      ),
    }),
  );
  assert.equal(acked.errorCode, 0);
  const empty = await client.sharePoll(
    new SharePollRequest({ sessionId: session, maxRecords: 10, maxWaitMs: 500 }),
  );
  assert.equal(empty.errorCode, 0);
  assert.deepEqual(empty.records, []);

  await produce(client, topic, ["s3"]);
  const third = await poll(1);
  assert.equal(third.length, 1, "share delivery of s3 timed out");
  assert.equal(third[0].deliveryCount, 1);
  const released = await client.shareAck(
    new ShareAckRequest({
      sessionId: session,
      entries: [
        new ShareAckEntry({ topic, partition: 0, offset: third[0].offset, ackType: 2 }),
      ],
    }),
  );
  assert.equal(released.errorCode, 0);
  const redelivered = await poll(1);
  assert.equal(redelivered.length, 1, "release redelivery timed out");
  assert.equal(redelivered[0].offset, third[0].offset);
  assert.equal(redelivered[0].deliveryCount, 2);

  const closed = await client.closeShareGroup(
    new CloseShareGroupRequest({ sessionId: session }),
  );
  assert.equal(closed.errorCode, 0);
});

test("kafka subscribe cancel leaves group", { skip: !PROXY_ADDR }, async (t) => {
  const { client, topic } = await makeClient(t);
  await produce(client, topic, ["x"]);
  const group = `js-kafka-group-${randomUUID().slice(0, 12)}`;
  const stream = await client.subscribe(
    new GroupSubscribeRequest({
      groupId: group,
      topics: [topic],
      sessionTimeoutMs: 30000,
      maxPollRecords: 10,
      autoOffsetReset: "earliest",
    }),
  );
  let assigned = false;
  for await (const resp of stream) {
    if (resp.assignment?.partitions?.length) {
      assigned = true;
      break; // breaking the iteration cancels the call (RST)
    }
    if (resp.groupError) break;
  }
  assert.ok(assigned, "no assignment from subscribe");
  // The cancellation must reach the proxy, which leaves the
  // group: the member disappears from describe.
  let members = -1;
  for (let i = 0; i < 80 && members !== 0; i++) {
    const described = await client.describeGroups(
      new DescribeGroupsRequest({ groupIds: [group] }),
    );
    members = described.groups[0]?.members?.length ?? 0;
    if (members !== 0) await new Promise((r) => setTimeout(r, 250));
  }
  assert.equal(members, 0);
  // The channel is still usable after the cancellation.
  const latest = await client.listOffsets(
    new ListOffsetsRequest({ topic, partition: 0, timestamp: -1n }),
  );
  assert.equal(latest.errorCode, 0);
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
