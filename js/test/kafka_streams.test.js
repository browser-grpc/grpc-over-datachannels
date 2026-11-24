// Kafka Streams over gRPC end-to-end (word count): generated
// JS clients -> Rust kafka_proxy -> Apache Kafka / Redpanda.
//
// The client creates a TOKENIZE_WORDS -> GROUP_BY_KEY ->
// COUNT topology, produces sentences to the source topic,
// then reads (word, count) records back from the sink and
// queries the topology store with GetStoreValue.
//
// Env-gated: set KAFKA_E2E_PROXY_ADDR=host:port of a running
// kafka_proxy (see scripts/kafka-e2e.sh / `make test-kafka`).
// Skipped otherwise.

import assert from "node:assert/strict";
import { connect } from "node:net";
import { randomUUID } from "node:crypto";
import test from "node:test";

import { Channel } from "../index.js";
import { KafkaStreamsClient } from "../src/kafka_streams_grpc_dc.js";
import {
  CreateTopologyRequest,
  DeleteTopologyRequest,
  GetStoreValueRequest,
  Operator,
  Topology,
} from "../src/kafka_streams_pb.js";
import { KafkaClient } from "../src/kafka_grpc_dc.js";
import {
  ConsumeRequest,
  CreateTopicsRequest,
  DeleteTopicsRequest,
  NewTopic,
  ProduceRequest,
  Record,
} from "../src/kafka_pb.js";

const PROXY_ADDR = process.env.KAFKA_E2E_PROXY_ADDR ?? "";
const enc = (s) => new TextEncoder().encode(s);
const dec = (b) => new TextDecoder().decode(b);

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

function makeClients() {
  const sep = PROXY_ADDR.lastIndexOf(":");
  const dc = tcpDataChannel(PROXY_ADDR.slice(0, sep), Number(PROXY_ADDR.slice(sep + 1)));
  const channel = new Channel(dc);
  return { dc, kafka: new KafkaClient(channel), streams: new KafkaStreamsClient(channel) };
}

async function makeTopic(kafka, name) {
  const created = await kafka.createTopics(
    new CreateTopicsRequest({
      topics: [new NewTopic({ name, numPartitions: 1, replicationFactor: 1 })],
      timeoutMs: 15000,
    }),
  );
  assert.deepEqual(created.results.map((r) => r.errorCode), [0]);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

test("kafka streams word count over gRPC", { skip: !PROXY_ADDR }, async (t) => {
  const { dc, kafka, streams } = makeClients();
  const id = randomUUID().slice(0, 12);
  const source = `streams-in-${id}`;
  const sink = `streams-out-${id}`;
  const name = `wc-${id}`;
  t.after(async () => {
    try {
      await streams.deleteTopology(new DeleteTopologyRequest({ name }));
      await kafka.deleteTopics(new DeleteTopicsRequest({ topics: [source, sink] }));
    } catch {
      /* best effort */
    }
    dc.close();
  });
  await makeTopic(kafka, source);
  await makeTopic(kafka, sink);

  const info = await streams.createTopology(
    new CreateTopologyRequest({
      topology: new Topology({
        name,
        sourceTopic: source,
        sinkTopic: sink,
        operators: [Operator.TOKENIZE_WORDS, Operator.GROUP_BY_KEY, Operator.COUNT],
      }),
    }),
  );
  assert.equal(info.state, "RUNNING");
  assert.equal(info.applicationId, `streams-${name}`);

  // An unsupported chain is rejected, not silently ignored.
  await assert.rejects(
    streams.createTopology(
      new CreateTopologyRequest({
        topology: new Topology({
          name: `bad-${id}`,
          sourceTopic: source,
          sinkTopic: sink,
          operators: [Operator.COUNT],
        }),
      }),
    ),
  );

  const lines = ["hello world hello", "world of streams", "hello streams"];
  for (const line of lines) {
    const resp = await kafka.produce(
      new ProduceRequest({
        topic: source,
        partition: 0,
        records: [new Record({ value: enc(line) })],
      }),
    );
    assert.equal(resp.errorCode, 0);
  }

  // Interactive query: hello x3, world x2, streams x2, of x1.
  const want = { hello: 3n, world: 2n, streams: 2n, of: 1n };
  for (const [word, count] of Object.entries(want)) {
    let got = null;
    for (let i = 0; i < 60; i++) {
      got = await streams.getStoreValue(
        new GetStoreValueRequest({ topology: name, key: word }),
      );
      if (got.found && got.value === count) break;
      await sleep(250);
    }
    assert.equal(got.found, true, `store never counted ${word}`);
    assert.equal(got.value, count, `wrong count for ${word}`);
  }
  const missing = await streams.getStoreValue(
    new GetStoreValueRequest({ topology: name, key: "absent" }),
  );
  assert.equal(missing.found, false);

  // The sink carries the running counts; the last record per
  // word is its final count.
  const finalCounts = {};
  const stream = await kafka.consume(
    new ConsumeRequest({ topic: sink, partition: 0, offset: 0n, maxRecords: 50 }),
  );
  let seen = 0;
  for await (const chunk of stream) {
    assert.equal(chunk.errorCode, 0);
    for (const r of chunk.records) {
      finalCounts[dec(r.key)] = dec(r.value);
      seen++;
    }
    if (seen >= 7) break;
  }
  assert.deepEqual(finalCounts, { hello: "3", world: "2", streams: "2", of: "1" });
});
