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

test("kafka streams session window merges by gap", { skip: !PROXY_ADDR }, async (t) => {
  const { dc, kafka, streams } = makeClients();
  const id = randomUUID().slice(0, 12);
  const source = `streams-sess-in-${id}`;
  const sink = `streams-sess-out-${id}`;
  const name = `sess-${id}`;
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
  const T0 = 1_699_999_980_000n;
  const info = await streams.createTopology(new CreateTopologyRequest({
    topology: new Topology({
      name, sourceTopic: source, sinkTopic: sink,
      steps: [
        new Step({ operator: Operator.SELECT_KEY, param: "value" }),
        new Step({ operator: Operator.GROUP_BY_KEY }),
        new Step({ operator: Operator.WINDOW_SESSION, gapMs: 30000n }),
        new Step({ operator: Operator.COUNT }),
      ],
    }),
  }));
  assert.equal(info.state, "RUNNING");
  const at = async (word, off) => {
    const resp = await kafka.produce(new ProduceRequest({
      topic: source, partition: 0,
      records: [new Record({ value: enc(word), timestampMs: T0 + off })],
    }));
    assert.equal(resp.errorCode, 0);
  };
  // clicks at +0s, +10s (same session, gap 30s), +120s (new).
  await at("click", 0n);
  await at("click", 10_000n);
  await at("click", 120_000n);
  const fetchWin = async (start, end) => {
    let got = null;
    for (let i = 0; i < 80; i++) {
      got = await streams.fetchWindow(new FetchWindowRequest({
        topology: name, key: "click", windowStartMs: start, windowEndMs: end,
      }));
      if (got.found) break;
      await sleep(250);
    }
    return got;
  };
  const s1 = await fetchWin(T0, T0 + 10_001n);
  assert.equal(s1.found, true);
  assert.equal(s1.value, 2n);
  const s2 = await fetchWin(T0 + 120_000n, T0 + 120_001n);
  assert.equal(s2.value, 1n);
});

test("kafka streams cogroup folds extra topics into the store", { skip: !PROXY_ADDR }, async (t) => {
  const { dc, kafka, streams } = makeClients();
  const id = randomUUID().slice(0, 12);
  const source = `streams-cg-in-${id}`;
  const extra = `streams-cg-extra-${id}`;
  const sink = `streams-cg-out-${id}`;
  const name = `cg-${id}`;
  t.after(async () => {
    try {
      await streams.deleteTopology(new DeleteTopologyRequest({ name }));
      await kafka.deleteTopics(new DeleteTopicsRequest({ topics: [source, extra, sink] }));
    } catch { /* best effort */ }
    dc.close();
  });
  for (const topic of [source, extra, sink]) {
    const created = await kafka.createTopics(new CreateTopicsRequest({
      topics: [new NewTopic({ name: topic, numPartitions: 1, replicationFactor: 1 })],
      timeoutMs: 15000,
    }));
    assert.deepEqual(created.results.map((r) => r.errorCode), [0]);
  }
  const { Step } = await import("../src/kafka_streams_pb.js");
  const info = await streams.createTopology(new CreateTopologyRequest({
    topology: new Topology({
      name, sourceTopic: source, sinkTopic: sink, cogroupSources: [extra],
      steps: [
        new Step({ operator: Operator.GROUP_BY_KEY }),
        new Step({ operator: Operator.COGROUP }),
        new Step({ operator: Operator.AGGREGATE, aggregator: 2 /* SUM */ }),
      ],
    }),
  }));
  assert.equal(info.state, "RUNNING");
  const put = async (topic, k, v) => {
    const resp = await kafka.produce(new ProduceRequest({
      topic, partition: 0, records: [new Record({ key: enc(k), value: enc(v) })],
    }));
    assert.equal(resp.errorCode, 0);
  };
  await put(source, "a", "5");
  await put(extra, "a", "7");
  await put(extra, "b", "3");
  // Store for "a": main aggregate (5) + cogroup fold (7) in
  // some order; wait until the total reaches 12.
  let got = null;
  for (let i = 0; i < 80; i++) {
    got = await streams.getStoreValue(new GetStoreValueRequest({ topology: name, key: "a" }));
    if (got.found && got.value === 12n) break;
    await sleep(250);
  }
  assert.equal(got?.value, 12n, `cogroup total wrong: ${got?.value}`);
  const b = await streams.getStoreValue(new GetStoreValueRequest({ topology: name, key: "b" }));
  assert.equal(b.value, 3n);
});

test("kafka streams global table join sees all partitions", { skip: !PROXY_ADDR }, async (t) => {
  const { dc, kafka, streams } = makeClients();
  const id = randomUUID().slice(0, 12);
  const source = `streams-gt-in-${id}`;
  const table = `streams-gt-table-${id}`;
  const sink = `streams-gt-out-${id}`;
  const name = `gt-${id}`;
  t.after(async () => {
    try {
      await streams.deleteTopology(new DeleteTopologyRequest({ name }));
      await kafka.deleteTopics(new DeleteTopicsRequest({ topics: [source, table, sink] }));
    } catch { /* best effort */ }
    dc.close();
  });
  for (const [topic, parts] of [[source, 1], [table, 3], [sink, 1]]) {
    const created = await kafka.createTopics(new CreateTopicsRequest({
      topics: [new NewTopic({ name: topic, numPartitions: parts, replicationFactor: 1 })],
      timeoutMs: 15000,
    }));
    assert.deepEqual(created.results.map((r) => r.errorCode), [0]);
  }
  // Table entries spread across all 3 partitions.
  for (let p = 0; p < 3; p++) {
    const resp = await kafka.produce(new ProduceRequest({
      topic: table, partition: p,
      records: [new Record({ key: enc(`k${p}`), value: enc(`T${p}`) })],
    }));
    assert.equal(resp.errorCode, 0);
  }
  const { Step } = await import("../src/kafka_streams_pb.js");
  const info = await streams.createTopology(new CreateTopologyRequest({
    topology: new Topology({
      name, sourceTopic: source, tableTopic: table, sinkTopic: sink,
      steps: [new Step({ operator: Operator.JOIN_GLOBAL_TABLE, param: "=" })],
    }),
  }));
  assert.equal(info.state, "RUNNING");
  for (let p = 0; p < 3; p++) {
    const resp = await kafka.produce(new ProduceRequest({
      topic: source, partition: 0,
      records: [new Record({ key: enc(`k${p}`), value: enc("hit") })],
    }));
    assert.equal(resp.errorCode, 0);
  }
  const joined = {};
  let total = 0;
  for (let i = 0; i < 60 && total < 3; i++) {
    const stream = await kafka.consume(new ConsumeRequest({ topic: sink, partition: 0, offset: 0n, maxRecords: 50 }));
    const iter = stream[Symbol.asyncIterator]();
    const first = await Promise.race([iter.next(), sleep(1000).then(() => null)]);
    if (first && !first.done) {
      total = 0;
      for (const r of first.value.records) { joined[dec(r.key)] = dec(r.value); total++; }
    }
    await iter.return?.();
    if (total < 3) await sleep(250);
  }
  assert.deepEqual(joined, { k0: "hit=T0", k1: "hit=T1", k2: "hit=T2" });
});

test("kafka streams PROCESS routes through a client-hosted processor", { skip: !PROXY_ADDR }, async (t) => {
  const { createServer } = await import("node:net");
  const { Server } = await import("../index.js");
  const { createStreamsProcessorService, ProcessorContextClient } = await import("../src/kafka_streams_processor_grpc_dc.js");
  const { ProcessResult, OutRecord } = await import("../src/kafka_streams_processor_pb.js");
  const { StreamDataChannel } = await import("../src/stdio.js");

  const { dc, kafka, streams } = makeClients();
  const id = randomUUID().slice(0, 12);
  const source = `streams-proc-in-${id}`;
  const sink = `streams-proc-out-${id}`;
  const name = `proc-${id}`;

  // Processor host: uppercase the value, and count calls
  // per key in the topology store via ProcessorContext.
  const ctxDc = tcpChannelForAddr(PROXY_ADDR);
  const ctx = new ProcessorContextClient(new Channel(ctxDc));
  const { GetStateRequest, PutStateRequest } = await import("../src/kafka_streams_processor_pb.js");
  const procServer = new Server();
  procServer.addService(createStreamsProcessorService({
    async process(req) {
      const prev = await ctx.getState(new GetStateRequest({ topology: req.topology, key: dec(req.key) || "calls" }));
      const n = (prev.found ? prev.value : 0n) + 1n;
      await ctx.putState(new PutStateRequest({ topology: req.topology, key: dec(req.key) || "calls", value: n }));
      return new ProcessResult({
        records: [new OutRecord({ key: req.key, value: enc(dec(req.value).toUpperCase()) })],
      });
    },
  }));
  const procSockets = new Set();
  const listener = createServer((socket) => {
    procSockets.add(socket);
    socket.on("close", () => procSockets.delete(socket));
    procServer.serve(new StreamDataChannel(socket));
  });
  await new Promise((resolve) => listener.listen(0, "127.0.0.1", resolve));
  const procPort = listener.address().port;
  t.after(async () => {
    try {
      await streams.deleteTopology(new DeleteTopologyRequest({ name }));
      await kafka.deleteTopics(new DeleteTopicsRequest({ topics: [source, sink] }));
    } catch { /* best effort */ }
    for (const s of procSockets) s.destroy();
    listener.close();
    ctxDc.close();
    dc.close();
  });
  for (const topic of [source, sink]) {
    const created = await kafka.createTopics(new CreateTopicsRequest({
      topics: [new NewTopic({ name: topic, numPartitions: 1, replicationFactor: 1 })],
      timeoutMs: 15000,
    }));
    assert.deepEqual(created.results.map((r) => r.errorCode), [0]);
  }
  const { Step } = await import("../src/kafka_streams_pb.js");
  const info = await streams.createTopology(new CreateTopologyRequest({
    topology: new Topology({
      name, sourceTopic: source, sinkTopic: sink,
      steps: [new Step({ operator: Operator.PROCESS, param: `tcp://127.0.0.1:${procPort}` })],
    }),
  }));
  assert.equal(info.state, "RUNNING");
  for (const [k, v] of [["a", "hello"], ["a", "again"], ["b", "world"]]) {
    const resp = await kafka.produce(new ProduceRequest({
      topic: source, partition: 0, records: [new Record({ key: enc(k), value: enc(v) })],
    }));
    assert.equal(resp.errorCode, 0);
  }
  const got = {};
  let total = 0;
  for (let i = 0; i < 60 && total < 3; i++) {
    const stream = await kafka.consume(new ConsumeRequest({ topic: sink, partition: 0, offset: 0n, maxRecords: 50 }));
    const iter = stream[Symbol.asyncIterator]();
    const first = await Promise.race([iter.next(), sleep(1000).then(() => null)]);
    if (first && !first.done) {
      total = 0;
      for (const r of first.value.records) { got[dec(r.value)] = dec(r.key); total++; }
    }
    await iter.return?.();
    if (total < 3) await sleep(250);
  }
  assert.deepEqual(got, { HELLO: "a", AGAIN: "a", WORLD: "b" });
  // ProcessorContext wrote call counts into the topology store.
  const calls = await streams.getStoreValue(new GetStoreValueRequest({ topology: name, key: "a" }));
  assert.equal(calls.value, 2n);
});

// Generated-scenario legs: cases come from
// racket/kafka-streams-spec.rkt (one table for every
// language; Python interprets the same data). The dedicated
// tests above cover the operators these scenarios don't.
import { KAFKA_STREAMS_SCENARIOS } from "./kafka_streams_scenarios.generated.js";

for (const scenario of KAFKA_STREAMS_SCENARIOS) {
  test(`kafka streams generated scenario: ${scenario.name}`, { skip: !PROXY_ADDR }, async (t) => {
    const { Step, Aggregator } = await import("../src/kafka_streams_pb.js");
    const { kafka, streams, source, sink, name } = await setupStreams(t);
    void kafka;
    void streams;
    void source;
    void sink;
    void name;
    // setupStreams pre-created the legacy word-count
    // topology; generated scenarios need custom chains, so
    // this leg builds its own.
    const { dc, kafka: k2, streams: s2 } = makeClients();
    const id = randomUUID().slice(0, 12);
    const src = `gen-in-${id}`;
    const out = `gen-out-${id}`;
    const topoName = `gen-${scenario.name}-${id}`;
    t.after(async () => {
      try {
        await s2.deleteTopology(new DeleteTopologyRequest({ name: topoName }));
        await k2.deleteTopics(new DeleteTopicsRequest({ topics: [src, out] }));
      } catch { /* best effort */ }
      dc.close();
    });
    for (const topic of [src, out]) {
      const created = await k2.createTopics(new CreateTopicsRequest({
        topics: [new NewTopic({ name: topic, numPartitions: 1, replicationFactor: 1 })],
        timeoutMs: 15000,
      }));
      assert.deepEqual(created.results.map((r) => r.errorCode), [0]);
    }
    const steps = scenario.chain.map((st) => new Step({
      operator: Operator[st.operator],
      param: st.param,
      aggregator: st.aggregator,
    }));
    const info = await s2.createTopology(new CreateTopologyRequest({
      topology: new Topology({ name: topoName, sourceTopic: src, sinkTopic: out, steps }),
    }));
    assert.equal(info.state, "RUNNING");
    await produceLines(k2, src, scenario.lines);
    for (const [key, value] of Object.entries(scenario.store)) {
      await waitStore(s2, topoName, key, BigInt(value));
    }
    const { finalCounts } = await drainSink(k2, out, 1);
    assert.deepEqual(finalCounts, scenario.sink);
  });
}

test("kafka streams state_dir restores from changelog on recreate", { skip: !PROXY_ADDR }, async (t) => {
  const { kafka, streams, source, sink, name } = await setupStreams(t);
  // Recreate with state_dir from the start (same name/app).
  await streams.deleteTopology(new DeleteTopologyRequest({ name }));
  await sleep(600);
  const mk = () => streams.createTopology(new CreateTopologyRequest({
    topology: new Topology({
      name, sourceTopic: source, sinkTopic: sink, stateDir: "state",
      operators: [Operator.TOKENIZE_WORDS, Operator.GROUP_BY_KEY, Operator.COUNT],
    }),
  }));
  // The default topology from setupStreams had no records;
  // recreate as stateful, count, delete, recreate, and the
  // store must come back from the changelog WITHOUT
  // replaying the source (sink gets no duplicate counts).
  await mk();
  await produceLines(kafka, source, ["persist persist me"]);
  await waitStore(streams, name, "persist", 2n);
  const sinkBefore = (await drainSink(kafka, sink, 1)).total;
  await streams.deleteTopology(new DeleteTopologyRequest({ name }));
  await sleep(600);
  await mk();
  // Store restored from changelog before any new record.
  let restored = null;
  for (let i = 0; i < 40; i++) {
    restored = await streams.getStoreValue(new GetStoreValueRequest({ topology: name, key: "persist" }));
    if (restored.found && restored.value === 2n) break;
    await sleep(250);
  }
  assert.equal(restored?.value, 2n, "store was not restored from changelog");
  await produceLines(kafka, source, ["persist"]);
  await waitStore(streams, name, "persist", 3n);
  const sinkAfter = (await drainSink(kafka, sink, 1)).total;
  assert.equal(sinkAfter, sinkBefore + 1, "restore replayed source records into the sink");
});

test("kafka streams windowed stream-stream join", { skip: !PROXY_ADDR }, async (t) => {
  const { dc, kafka, streams } = makeClients();
  const id = randomUUID().slice(0, 12);
  const source = `streams-sj-left-${id}`;
  const join = `streams-sj-right-${id}`;
  const sink = `streams-sj-out-${id}`;
  const name = `sj-${id}`;
  t.after(async () => {
    try {
      await streams.deleteTopology(new DeleteTopologyRequest({ name }));
      await kafka.deleteTopics(new DeleteTopicsRequest({ topics: [source, join, sink] }));
    } catch { /* best effort */ }
    dc.close();
  });
  for (const topic of [source, join, sink]) {
    const created = await kafka.createTopics(new CreateTopicsRequest({
      topics: [new NewTopic({ name: topic, numPartitions: 1, replicationFactor: 1 })],
      timeoutMs: 15000,
    }));
    assert.deepEqual(created.results.map((r) => r.errorCode), [0]);
  }
  const { Step } = await import("../src/kafka_streams_pb.js");
  const T0 = 1_699_999_980_000n;
  const info = await streams.createTopology(new CreateTopologyRequest({
    topology: new Topology({
      name, sourceTopic: source, joinTopic: join, sinkTopic: sink,
      steps: [new Step({ operator: Operator.JOIN_STREAM, windowSizeMs: 60000n, graceMs: 120000n, param: "+" })],
    }),
  }));
  assert.equal(info.state, "RUNNING");
  const put = async (topic, k, v, off) => {
    const resp = await kafka.produce(new ProduceRequest({
      topic, partition: 0,
      records: [new Record({ key: enc(k), value: enc(v), timestampMs: T0 + off })],
    }));
    assert.equal(resp.errorCode, 0);
  };
  await put(source, "k1", "L1", 1000n);
  await put(join, "k1", "R1", 5000n);      // same window: joins
  await put(join, "k2", "R2", 2000n);      // no left yet
  await put(source, "k2", "L2", 3000n);    // joins from buffer
  await put(join, "k1", "LATE", 61000n);   // next window: no join
  const joined = {};
  let total = 0;
  for (let i = 0; i < 60 && total < 2; i++) {
    const stream = await kafka.consume(new ConsumeRequest({ topic: sink, partition: 0, offset: 0n, maxRecords: 50 }));
    const iter = stream[Symbol.asyncIterator]();
    const first = await Promise.race([iter.next(), sleep(1000).then(() => null)]);
    if (first && !first.done) {
      total = 0;
      for (const r of first.value.records) { joined[dec(r.key)] = dec(r.value); total++; }
    }
    await iter.return?.();
    if (total < 2) await sleep(250);
  }
  assert.deepEqual(joined, { k1: "L1+R1", k2: "L2+R2" });
  assert.equal(total, 2);
});

test("kafka streams table-table join emits on either side update", { skip: !PROXY_ADDR }, async (t) => {
  const { dc, kafka, streams } = makeClients();
  const id = randomUUID().slice(0, 12);
  const source = `streams-tt-src-${id}`;
  const left = `streams-tt-left-${id}`;
  const right = `streams-tt-right-${id}`;
  const sink = `streams-tt-out-${id}`;
  const name = `tt-${id}`;
  t.after(async () => {
    try {
      await streams.deleteTopology(new DeleteTopologyRequest({ name }));
      await kafka.deleteTopics(new DeleteTopicsRequest({ topics: [source, left, right, sink] }));
    } catch { /* best effort */ }
    dc.close();
  });
  for (const topic of [source, left, right, sink]) {
    const created = await kafka.createTopics(new CreateTopicsRequest({
      topics: [new NewTopic({ name: topic, numPartitions: 1, replicationFactor: 1 })],
      timeoutMs: 15000,
    }));
    assert.deepEqual(created.results.map((r) => r.errorCode), [0]);
  }
  const { Step } = await import("../src/kafka_streams_pb.js");
  const info = await streams.createTopology(new CreateTopologyRequest({
    topology: new Topology({
      name, sourceTopic: source, tableTopic: left, joinTopic: right, sinkTopic: sink,
      steps: [new Step({ operator: Operator.JOIN_TABLE_TABLE, param: "|" })],
    }),
  }));
  assert.equal(info.state, "RUNNING");
  const put = async (topic, k, v) => {
    const resp = await kafka.produce(new ProduceRequest({
      topic, partition: 0, records: [new Record({ key: enc(k), value: enc(v) })],
    }));
    assert.equal(resp.errorCode, 0);
  };
  await put(left, "x", "L1");
  await put(right, "x", "R1");   // -> x = L1|R1
  // Wait for the first combined emission before updating
  // the left side (a single fetch batch would otherwise
  // collapse L1 and L2 into one emission).
  for (let i = 0; i < 60; i++) {
    const stream = await kafka.consume(new ConsumeRequest({ topic: sink, partition: 0, offset: 0n, maxRecords: 50 }));
    const iter = stream[Symbol.asyncIterator]();
    const first = await Promise.race([iter.next(), sleep(500).then(() => null)]);
    await iter.return?.();
    if (first && !first.done && first.value.records.length >= 1) break;
    await sleep(250);
  }
  await put(left, "x", "L2");    // -> x = L2|R1 (left update re-emits)
  const seen = [];
  for (let i = 0; i < 60 && seen.length < 2; i++) {
    const stream = await kafka.consume(new ConsumeRequest({ topic: sink, partition: 0, offset: 0n, maxRecords: 50 }));
    const iter = stream[Symbol.asyncIterator]();
    const first = await Promise.race([iter.next(), sleep(1000).then(() => null)]);
    if (first && !first.done) {
      seen.length = 0;
      for (const r of first.value.records) seen.push(`${dec(r.key)}=${dec(r.value)}`);
    }
    await iter.return?.();
    if (seen.length < 2) await sleep(250);
  }
  assert.deepEqual(seen, ["x=L1|R1", "x=L2|R1"]);
});
