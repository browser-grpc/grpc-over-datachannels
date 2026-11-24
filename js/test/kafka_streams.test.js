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
import { randomUUID } from "node:crypto";
import test from "node:test";

import { Channel } from "../index.js";
import { dec, enc, sleep, tcpChannelForAddr } from "./kafka_helpers.js";
import { KafkaStreamsClient } from "../src/kafka_streams_grpc_dc.js";
import {
  CreateTopologyRequest,
  DeleteTopologyRequest,
  DescribeTopologyRequest,
  GetStoreValueRequest,
  ListTopologiesRequest,
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
function makeClients() {
  const dc = tcpChannelForAddr(PROXY_ADDR);
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

async function setupStreams(t, { partitions = 1 } = {}) {
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
  for (const topic of [source, sink]) {
    const created = await kafka.createTopics(
      new CreateTopicsRequest({
        topics: [new NewTopic({ name: topic, numPartitions: partitions, replicationFactor: 1 })],
        timeoutMs: 15000,
      }),
    );
    assert.deepEqual(created.results.map((r) => r.errorCode), [0]);
  }
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
  return { kafka, streams, source, sink, name };
}

async function produceLines(kafka, topic, lines, partition = 0) {
  for (const line of lines) {
    const resp = await kafka.produce(
      new ProduceRequest({
        topic,
        partition,
        records: [new Record({ value: enc(line) })],
      }),
    );
    assert.equal(resp.errorCode, 0);
  }
}

async function waitStore(streams, name, word, count) {
  let got = null;
  for (let i = 0; i < 80; i++) {
    got = await streams.getStoreValue(new GetStoreValueRequest({ topology: name, key: word }));
    if (got.found && got.value === count) return got;
    await sleep(250);
  }
  assert.fail(`store never reached ${word}=${count} (last: found=${got?.found} value=${got?.value})`);
}

async function drainSink(kafka, sink, partitions) {
  const finalCounts = {};
  let total = 0;
  for (let p = 0; p < partitions; p++) {
    const stream = await kafka.consume(
      new ConsumeRequest({ topic: sink, partition: p, offset: 0n, maxRecords: 200 }),
    );
    // The consume stream only yields when records exist, so
    // an empty partition would block forever: race the first
    // chunk against a timeout and move on when it loses.
    const iter = stream[Symbol.asyncIterator]();
    const first = await Promise.race([
      iter.next(),
      sleep(3000).then(() => null),
    ]);
    if (first && !first.done) {
      const chunk = first.value;
      assert.equal(chunk.errorCode, 0);
      for (const r of chunk.records) {
        finalCounts[dec(r.key)] = dec(r.value);
        total++;
      }
    }
    await iter.return?.();
  }
  return { finalCounts, total };
}

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

test("kafka streams topology lifecycle errors", { skip: !PROXY_ADDR }, async (t) => {
  const { dc, streams } = makeClients();
  t.after(() => dc.close());
  // Unknown topology: NOT_FOUND everywhere.
  await assert.rejects(
    streams.describeTopology(new DescribeTopologyRequest({ name: "nope" })),
    /unknown topology/,
  );
  await assert.rejects(
    streams.getStoreValue(new GetStoreValueRequest({ topology: "nope", key: "x" })),
    /unknown topology/,
  );
  await assert.rejects(
    streams.deleteTopology(new DeleteTopologyRequest({ name: "nope" })),
    /unknown topology/,
  );
  // Empty required fields: INVALID_ARGUMENT.
  await assert.rejects(
    streams.createTopology(
      new CreateTopologyRequest({ topology: new Topology({ operators: [] }) }),
    ),
  );
  // List contains a created topology; duplicate create fails;
  // delete then makes describe fail again.
  const { kafka, streams: s2, name } = await setupStreams(t);
  void kafka;
  const listed = await s2.listTopologies(new ListTopologiesRequest({}));
  assert.ok(listed.topologies.some((x) => x.name === name && x.state === "RUNNING"));
  await assert.rejects(
    s2.createTopology(
      new CreateTopologyRequest({
        topology: new Topology({
          name,
          sourceTopic: "x",
          sinkTopic: "y",
          operators: [Operator.TOKENIZE_WORDS, Operator.GROUP_BY_KEY, Operator.COUNT],
        }),
      }),
    ),
    /already exists/,
  );
  await s2.deleteTopology(new DeleteTopologyRequest({ name }));
  await assert.rejects(
    s2.describeTopology(new DescribeTopologyRequest({ name })),
    /unknown topology/,
  );
});

test("kafka streams delete/recreate resumes without double counting", { skip: !PROXY_ADDR }, async (t) => {
  const { kafka, streams, source, sink, name } = await setupStreams(t);
  await produceLines(kafka, source, ["one two", "two three"]);
  await waitStore(streams, name, "two", 2n);
  await waitStore(streams, name, "one", 1n);
  const before = (await drainSink(kafka, sink, 1)).finalCounts;
  assert.deepEqual(before, { one: "1", two: "2", three: "1" });

  // Delete + recreate with the same application id (derived
  // from the name): the new task must resume from committed
  // offsets, so the already-counted records are NOT replayed
  // and the store's final values stay exactly the same once
  // only the new line is added.
  await streams.deleteTopology(new DeleteTopologyRequest({ name }));
  await sleep(500);
  const recreated = await streams.createTopology(
    new CreateTopologyRequest({
      topology: new Topology({
        name,
        sourceTopic: source,
        sinkTopic: sink,
        operators: [Operator.TOKENIZE_WORDS, Operator.GROUP_BY_KEY, Operator.COUNT],
      }),
    }),
  );
  assert.equal(recreated.state, "RUNNING");
  await produceLines(kafka, source, ["three three"]);
  await waitStore(streams, name, "three", 3n);
  const two = await streams.getStoreValue(new GetStoreValueRequest({ topology: name, key: "two" }));
  assert.equal(two.found, true);
  assert.equal(two.value, 2n, "resume double-counted already-committed records");
  const after = (await drainSink(kafka, sink, 1)).finalCounts;
  assert.deepEqual(after, { one: "1", two: "2", three: "3" });
});

test("kafka streams word count over 3x3 partitions", { skip: !PROXY_ADDR }, async (t) => {
  const { kafka, streams, source, sink, name } = await setupStreams(t, { partitions: 3 });
  // Spread input over all source partitions.
  await produceLines(kafka, source, ["red blue red"], 0);
  await produceLines(kafka, source, ["blue green"], 1);
  await produceLines(kafka, source, ["red green blue"], 2);
  await waitStore(streams, name, "red", 3n);
  await waitStore(streams, name, "blue", 3n);
  await waitStore(streams, name, "green", 2n);
  const { finalCounts, total } = await drainSink(kafka, sink, 3);
  assert.deepEqual(finalCounts, { red: "3", blue: "3", green: "2" });
  // Every emitted count increment lands once: 3+2+3 tokens.
  assert.equal(total, 8);
});

test("kafka streams aggregation and stateless chain", { skip: !PROXY_ADDR }, async (t) => {
  const { dc, kafka, streams } = makeClients();
  const id = randomUUID().slice(0, 12);
  const source = `streams-agg-in-${id}`;
  const sink = `streams-agg-out-${id}`;
  const name = `agg-${id}`;
  t.after(async () => {
    try {
      await streams.deleteTopology(new DeleteTopologyRequest({ name }));
      await kafka.deleteTopics(new DeleteTopicsRequest({ topics: [source, sink] }));
    } catch { /* best effort */ }
    dc.close();
  });
  for (const topic of [source, sink]) {
    const created = await kafka.createTopics(new CreateTopicsRequest({
      topics: [new NewTopic({ name: topic, numPartitions: 1, replicationFactor: 1 })],
      timeoutMs: 15000,
    }));
    assert.deepEqual(created.results.map((r) => r.errorCode), [0]);
  }
  const { Step, Aggregator } = await import("../src/kafka_streams_pb.js");
  const info = await streams.createTopology(new CreateTopologyRequest({
    topology: new Topology({
      name,
      sourceTopic: source,
      sinkTopic: sink,
      steps: [
        new Step({ operator: Operator.FILTER, param: "value_gt:2" }),
        new Step({ operator: Operator.SELECT_KEY, param: "value" }),
        new Step({ operator: Operator.GROUP_BY_KEY }),
        new Step({ operator: Operator.AGGREGATE, aggregator: Aggregator.AGGREGATE_SUM }),
      ],
    }),
  }));
  assert.equal(info.state, "RUNNING");
  // Records carry their numeric payload in the value;
  // SELECT_KEY rekeys by it, FILTER drops <= 2.
  for (const v of ["1", "5", "5", "9", "2"]) {
    const resp = await kafka.produce(new ProduceRequest({
      topic: source, partition: 0,
      records: [new Record({ value: enc(v) })],
    }));
    assert.equal(resp.errorCode, 0);
  }
  // Key "5" sums 5+5=10, key "9" is 9; filtered values
  // never reach the store.
  let got;
  for (let i = 0; i < 80; i++) {
    got = await streams.getStoreValue(new GetStoreValueRequest({ topology: name, key: "5" }));
    if (got.found && got.value === 10n) break;
    await sleep(250);
  }
  assert.equal(got.value, 10n);
  const nine = await streams.getStoreValue(new GetStoreValueRequest({ topology: name, key: "9" }));
  assert.equal(nine.value, 9n);
  const one = await streams.getStoreValue(new GetStoreValueRequest({ topology: name, key: "1" }));
  assert.equal(one.found, false, "filtered record reached the store");
});

test("kafka streams tumbling window counts and FetchWindow", { skip: !PROXY_ADDR }, async (t) => {
  const { dc, kafka, streams } = makeClients();
  const id = randomUUID().slice(0, 12);
  const source = `streams-win-in-${id}`;
  const sink = `streams-win-out-${id}`;
  const name = `win-${id}`;
  t.after(async () => {
    try {
      await streams.deleteTopology(new DeleteTopologyRequest({ name }));
      await kafka.deleteTopics(new DeleteTopicsRequest({ topics: [source, sink] }));
    } catch { /* best effort */ }
    dc.close();
  });
  for (const topic of [source, sink]) {
    const created = await kafka.createTopics(new CreateTopicsRequest({
      topics: [new NewTopic({ name: topic, numPartitions: 1, replicationFactor: 1 })],
      timeoutMs: 15000,
    }));
    assert.deepEqual(created.results.map((r) => r.errorCode), [0]);
  }
  const { Step, FetchWindowRequest } = await import("../src/kafka_streams_pb.js");
  const T0 = 1_699_999_980_000n; // 60s-window aligned (T0 % 60000 == 0)
  const info = await streams.createTopology(new CreateTopologyRequest({
    topology: new Topology({
      name,
      sourceTopic: source,
      sinkTopic: sink,
      steps: [
        new Step({ operator: Operator.SELECT_KEY, param: "value" }),
        new Step({ operator: Operator.GROUP_BY_KEY }),
        new Step({ operator: Operator.WINDOW_TUMBLING, windowSizeMs: 60000n }),
        new Step({ operator: Operator.COUNT }),
      ],
    }),
  }));
  assert.equal(info.state, "RUNNING");
  const produceAt = async (word, ts) => {
    const resp = await kafka.produce(new ProduceRequest({
      topic: source, partition: 0,
      records: [new Record({ value: enc(word), timestampMs: ts })],
    }));
    assert.equal(resp.errorCode, 0);
  };
  // Window A [T0, T0+60s): apple x2, banana x1.
  // Window B [T0+60s, T0+120s): apple x1.
  await produceAt("apple", T0 + 1000n);
  await produceAt("apple", T0 + 2000n);
  await produceAt("banana", T0 + 3000n);
  await produceAt("apple", T0 + 61000n);
  const fetchWin = async (key, start, end) => {
    let got = null;
    for (let i = 0; i < 80; i++) {
      got = await streams.fetchWindow(new FetchWindowRequest({
        topology: name, key, windowStartMs: start, windowEndMs: end,
      }));
      if (got.found) break;
      await sleep(250);
    }
    return got;
  };
  const aApple = await fetchWin("apple", T0, T0 + 60000n);
  assert.equal(aApple.found, true);
  assert.equal(aApple.value, 2n);
  const bApple = await fetchWin("apple", T0 + 60000n, T0 + 120000n);
  assert.equal(bApple.value, 1n);
  const aBanana = await fetchWin("banana", T0, T0 + 60000n);
  assert.equal(aBanana.value, 1n);
  const none = await streams.fetchWindow(new FetchWindowRequest({
    topology: name, key: "apple", windowStartMs: T0 + 120000n, windowEndMs: T0 + 180000n,
  }));
  assert.equal(none.found, false);
});

test("kafka streams group membership splits partitions", { skip: !PROXY_ADDR }, async (t) => {
  const { dc, kafka, streams } = makeClients();
  const id = randomUUID().slice(0, 12);
  const source = `streams-grp-in-${id}`;
  const sinkA = `streams-grp-a-${id}`;
  const sinkB = `streams-grp-b-${id}`;
  const appId = `streams-app-${id}`;
  const names = [`m1-${id}`, `m2-${id}`];
  t.after(async () => {
    try {
      for (const n of names) await streams.deleteTopology(new DeleteTopologyRequest({ name: n }));
      await kafka.deleteTopics(new DeleteTopicsRequest({ topics: [source, sinkA, sinkB] }));
    } catch { /* best effort */ }
    dc.close();
  });
  for (const topic of [source, sinkA, sinkB]) {
    const created = await kafka.createTopics(new CreateTopicsRequest({
      topics: [new NewTopic({ name: topic, numPartitions: 4, replicationFactor: 1 })],
      timeoutMs: 15000,
    }));
    assert.deepEqual(created.results.map((r) => r.errorCode), [0]);
  }
  const chain = [Operator.TOKENIZE_WORDS, Operator.GROUP_BY_KEY, Operator.COUNT];
  const mk = (name, sinkTopic) => streams.createTopology(new CreateTopologyRequest({
    topology: new Topology({ name, applicationId: appId, sourceTopic: source, sinkTopic, operators: chain }),
  }));
  assert.equal((await mk(names[0], sinkA)).state, "RUNNING");
  assert.equal((await mk(names[1], sinkB)).state, "RUNNING");
  // Both members join the same group: together they must own
  // all 4 partitions, disjointly (poll until the rebalance
  // settles).
  let a = [], b = [];
  for (let i = 0; i < 80; i++) {
    const da = await streams.describeTopology(new DescribeTopologyRequest({ name: names[0] }));
    const db = await streams.describeTopology(new DescribeTopologyRequest({ name: names[1] }));
    a = [...da.assignedPartitions].map(Number).sort();
    b = [...db.assignedPartitions].map(Number).sort();
    if (a.length + b.length === 4 && new Set([...a, ...b]).size === 4) break;
    await sleep(250);
  }
  assert.deepEqual([...a, ...b].sort(), [0, 1, 2, 3], `assignments a=${a} b=${b}`);

  // Produce one sentence per source partition; the union of
  // both sinks must hold the full word counts (each word's
  // records within one partition are counted by its owner).
  for (let p = 0; p < 4; p++) {
    const resp = await kafka.produce(new ProduceRequest({
      topic: source, partition: p,
      records: [new Record({ value: enc("shared shared word") })],
    }));
    assert.equal(resp.errorCode, 0);
  }
  // "shared" appears twice per sentence x4 partitions = 8,
  // split across the two members' stores/sinks.
  let totalShared = 0;
  for (let i = 0; i < 80 && totalShared < 8; i++) {
    totalShared = 0;
    for (const n of names) {
      const v = await streams.getStoreValue(new GetStoreValueRequest({ topology: n, key: "shared" }));
      if (v.found) totalShared += Number(v.value);
    }
    if (totalShared < 8) await sleep(250);
  }
  assert.equal(totalShared, 8);
});

test("kafka streams exactly-once commits sink and offsets atomically", { skip: !PROXY_ADDR }, async (t) => {
  const { dc, kafka, streams } = makeClients();
  const id = randomUUID().slice(0, 12);
  const source = `streams-eos-in-${id}`;
  const sink = `streams-eos-out-${id}`;
  const name = `eos-${id}`;
  t.after(async () => {
    try {
      await streams.deleteTopology(new DeleteTopologyRequest({ name }));
      await kafka.deleteTopics(new DeleteTopicsRequest({ topics: [source, sink] }));
    } catch { /* best effort */ }
    dc.close();
  });
  for (const topic of [source, sink]) {
    const created = await kafka.createTopics(new CreateTopicsRequest({
      topics: [new NewTopic({ name: topic, numPartitions: 1, replicationFactor: 1 })],
      timeoutMs: 15000,
    }));
    assert.deepEqual(created.results.map((r) => r.errorCode), [0]);
  }
  const { ProcessingGuarantee } = await import("../src/kafka_streams_pb.js");
  const info = await streams.createTopology(new CreateTopologyRequest({
    topology: new Topology({
      name,
      sourceTopic: source,
      sinkTopic: sink,
      processingGuarantee: ProcessingGuarantee.EXACTLY_ONCE,
      operators: [Operator.TOKENIZE_WORDS, Operator.GROUP_BY_KEY, Operator.COUNT],
    }),
  }));
  assert.equal(info.state, "RUNNING");
  assert.equal(info.applicationId, `streams-${name}`);
  await produceLines(kafka, source, ["eos eos test", "eos"]);
  await waitStore(streams, name, "eos", 3n);
  // read_committed must see exactly the committed counts:
  // final records eos=3, test=1, and nothing aborted/duplicated.
  const finalCounts = {};
  let total = 0;
  const stream = await kafka.consume(new ConsumeRequest({
    topic: sink, partition: 0, offset: 0n, maxRecords: 50, readCommitted: true,
  }));
  const iter = stream[Symbol.asyncIterator]();
  const first = await Promise.race([iter.next(), sleep(8000).then(() => null)]);
  assert.ok(first && !first.done, "no read_committed records from EXACTLY_ONCE sink");
  for (const r of first.value.records) {
    finalCounts[dec(r.key)] = dec(r.value);
    total++;
  }
  await iter.return?.();
  assert.deepEqual(finalCounts, { eos: "3", test: "1" });
  // Every emitted increment committed exactly once:
  // eos: 1,2,3 (3 records) + test: 1 (1 record).
  assert.equal(total, 4);
});

test("kafka streams stream-table join enriches records", { skip: !PROXY_ADDR }, async (t) => {
  const { dc, kafka, streams } = makeClients();
  const id = randomUUID().slice(0, 12);
  const source = `streams-join-in-${id}`;
  const table = `streams-join-table-${id}`;
  const sink = `streams-join-out-${id}`;
  const name = `join-${id}`;
  t.after(async () => {
    try {
      await streams.deleteTopology(new DeleteTopologyRequest({ name }));
      await kafka.deleteTopics(new DeleteTopicsRequest({ topics: [source, table, sink] }));
    } catch { /* best effort */ }
    dc.close();
  });
  for (const topic of [source, table, sink]) {
    const created = await kafka.createTopics(new CreateTopicsRequest({
      topics: [new NewTopic({ name: topic, numPartitions: 1, replicationFactor: 1 })],
      timeoutMs: 15000,
    }));
    assert.deepEqual(created.results.map((r) => r.errorCode), [0]);
  }
  // Table: user id -> profile name.
  for (const [k, v] of [["u1", "Ada"], ["u2", "Grace"]]) {
    const resp = await kafka.produce(new ProduceRequest({
      topic: table, partition: 0,
      records: [new Record({ key: enc(k), value: enc(v) })],
    }));
    assert.equal(resp.errorCode, 0);
  }
  const { Step } = await import("../src/kafka_streams_pb.js");
  const info = await streams.createTopology(new CreateTopologyRequest({
    topology: new Topology({
      name,
      sourceTopic: source,
      tableTopic: table,
      sinkTopic: sink,
      steps: [new Step({ operator: Operator.JOIN_TABLE, param: ":" })],
    }),
  }));
  assert.equal(info.state, "RUNNING");
  // Source records are pre-keyed by user id; value = event.
  for (const [k, v] of [["u1", "clicked"], ["u3", "ghost"], ["u2", "bought"]]) {
    const resp = await kafka.produce(new ProduceRequest({
      topic: source, partition: 0,
      records: [new Record({ key: enc(k), value: enc(v) })],
    }));
    assert.equal(resp.errorCode, 0);
  }
  // Sink must carry enriched values and drop u3 (no table entry).
  const joined = {};
  let total = 0;
  for (let i = 0; i < 60 && total < 2; i++) {
    const stream = await kafka.consume(new ConsumeRequest({
      topic: sink, partition: 0, offset: 0n, maxRecords: 50,
    }));
    const iter = stream[Symbol.asyncIterator]();
    const first = await Promise.race([iter.next(), sleep(1000).then(() => null)]);
    if (first && !first.done) {
      total = 0;
      for (const r of first.value.records) {
        joined[dec(r.key)] = dec(r.value);
        total++;
      }
    }
    await iter.return?.();
    if (total < 2) await sleep(250);
  }
  assert.deepEqual(joined, { u1: "clicked:Ada", u2: "bought:Grace" });
  assert.equal(total, 2, "record without a table entry must be dropped");
});
