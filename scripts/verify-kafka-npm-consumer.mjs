// Published-package consumer verification for kafka-grpc
// (npm): install the *registry* kafka-grpc + grpc-dc into a
// fresh temp consumer (never the repo's own node_modules or
// path deps), then run a Metadata + Produce round trip with
// the installed KafkaClient against an in-process Kafka
// service built from the installed createKafkaService over a
// loopback transport. This is the npm counterpart of the C#
// packed-nupkg consumer gate: it catches packaging breakage
// (missing files, bad exports, version skew with grpc-dc)
// that in-repo tests cannot see.
//
//   node scripts/verify-kafka-npm-consumer.mjs [version]
// Version defaults to the registry's latest. Network required;
// intentionally not part of `make test`. Run via
// `make verify-kafka-npm`.

import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const version = process.argv[2] ?? "latest";
const dir = mkdtempSync(join(tmpdir(), "kafka-npm-consumer-"));

const consumer = `
import assert from "node:assert/strict";
import { Channel, Server, memoryDataChannelPair } from "grpc-dc";
import {
  BrokerMetadata,
  KafkaClient,
  MetadataRequest,
  MetadataResponse,
  PartitionMetadata,
  ProduceRequest,
  ProduceResponse,
  Record,
  TopicMetadata,
  createKafkaService,
} from "kafka-grpc";

const notUsed = () => { throw new Error("handler not exercised by this smoke"); };
const handlers = {
  async metadata(req) {
    assert.deepEqual(req.topics, ["events"]);
    return new MetadataResponse({
      brokers: [new BrokerMetadata({ nodeId: 1, host: "broker.local", port: 9092 })],
      clusterId: "consumer-smoke",
      controllerId: 1,
      topics: [new TopicMetadata({
        name: "events",
        partitions: [new PartitionMetadata({ id: 0, leaderId: 1, replicas: [1], isr: [1] })],
      })],
    });
  },
  async produce(req) {
    assert.equal(req.topic, "events");
    assert.equal(req.records.length, 1);
    assert.equal(new TextDecoder().decode(req.records[0].value), "hello-kafka");
    return new ProduceResponse({ partition: req.partition, baseOffset: 41n, errorCode: 0 });
  },
  openProducer: notUsed, closeProducer: notUsed, endTransaction: notUsed,
  consume: notUsed, subscribe: notUsed, listOffsets: notUsed,
  commitOffset: notUsed, fetchOffset: notUsed,
  createTopics: notUsed, deleteTopics: notUsed,
};

const [a, b] = memoryDataChannelPair();
const server = new Server();
server.addService(createKafkaService(handlers));
server.serve(b);

const client = new KafkaClient(new Channel(a));
const meta = await client.metadata(new MetadataRequest({ topics: ["events"] }));
assert.equal(meta.clusterId, "consumer-smoke");
assert.equal(meta.brokers[0].host, "broker.local");
assert.equal(meta.topics[0].partitions[0].leaderId, 1);

const produced = await client.produce(new ProduceRequest({
  topic: "events",
  partition: 0,
  records: [new Record({ value: new TextEncoder().encode("hello-kafka") })],
}));
assert.equal(produced.baseOffset, 41n);
assert.equal(produced.errorCode, 0);

console.log("KAFKA_NPM_CONSUMER_OK metadata+produce via installed kafka-grpc");
`;

writeFileSync(join(dir, "package.json"), JSON.stringify({ type: "module" }));
writeFileSync(join(dir, "consumer.mjs"), consumer);

const install = spawnSync("npm", ["install", "--no-audit", "--no-fund", `kafka-grpc@${version}`], {
  cwd: dir,
  stdio: "inherit",
});
if (install.status !== 0) {
  console.error(`npm install kafka-grpc@${version} failed in ${dir}`);
  process.exit(1);
}
const installed = JSON.parse(readFileSync(join(dir, "node_modules/kafka-grpc/package.json"), "utf8"));
const runtime = JSON.parse(readFileSync(join(dir, "node_modules/grpc-dc/package.json"), "utf8"));
console.log(`installed kafka-grpc@${installed.version} with grpc-dc@${runtime.version} in ${dir}`);

const run = spawnSync("node", ["consumer.mjs"], { cwd: dir, stdio: "inherit" });
if (run.status !== 0) {
  console.error(`consumer smoke failed (dir kept for inspection: ${dir})`);
  process.exit(1);
}
console.log(`KAFKA_NPM_CONSUMER_VERIFIED kafka-grpc@${installed.version}`);
