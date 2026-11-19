// Generated protobuf codec micro-benchmark: encode/decode
// throughput and GC pressure for the *_pb.js classes, used as
// the before/after ruler for generator-level reuse work
// (mechanical-sympathy goal, step 1). Baseline numbers, not a
// correctness gate. Run: node --expose-gc codec_bench.mjs
import { PerformanceObserver } from "node:perf_hooks";
import { Event, TagValue } from "../js/src/events_pb.js";

let gcPauseMs = 0;
let gcCount = 0;
const obs = new PerformanceObserver((list) => {
  for (const e of list.getEntries()) {
    gcPauseMs += e.duration;
    gcCount += 1;
  }
});
obs.observe({ entryTypes: ["gc"], buffered: true });
function drainGc() {
  for (const e of obs.takeRecords()) {
    gcPauseMs += e.duration;
    gcCount += 1;
  }
}

function makeEvent() {
  return new Event({
    tags: [
      new TagValue({ tag: 1, stringValue: "orders" }),
      new TagValue({ tag: 2, stringValue: "eu-west" }),
      new TagValue({ tag: 3, intValue: 42n }),
    ],
    payload: new Uint8Array(1024).fill(7),
    seq: 123456789n,
    publisherId: "bench-publisher",
    timestampUnixMs: 1795000000000n,
  });
}

async function runPhase(name, fn, budgetMs = 2000) {
  // warmup (JIT)
  for (let i = 0; i < 2000; i++) fn(i);
  if (globalThis.gc) globalThis.gc();
  gcPauseMs = 0;
  gcCount = 0;
  const heapBefore = process.memoryUsage().heapUsed;
  let ops = 0;
  let sink = 0;
  const start = process.hrtime.bigint();
  const deadline = start + BigInt(budgetMs) * 1000000n;
  while (process.hrtime.bigint() < deadline) {
    for (let i = 0; i < 1000; i++) sink += fn(ops + i);
    ops += 1000;
  }
  const elapsedMs = Number(process.hrtime.bigint() - start) / 1e6;
  await new Promise((r) => setImmediate(r)); // let GC observer flush
  drainGc();
  if (globalThis.gc) globalThis.gc();
  const heapDeltaKb = (process.memoryUsage().heapUsed - heapBefore) / 1024;
  console.log(
    `${name}: ${(ops / (elapsedMs / 1000)).toFixed(0)} ops/s, ` +
      `${(elapsedMs * 1e6 / ops).toFixed(0)} ns/op, ` +
      `gc ${gcCount}x/${gcPauseMs.toFixed(1)}ms, heapΔ ${heapDeltaKb.toFixed(0)} KiB (sink ${sink})`
  );
  return ops;
}

const sample = makeEvent();
const encoded = Event.encode(sample);
console.log(`sample Event wire size: ${encoded.length} bytes`);

await runPhase("encode", () => Event.encode(sample).length);
await runPhase("decode", () => Event.decode(encoded).seq === 123456789n ? 1 : 0);
if (typeof Event.decodeInto === "function") {
  const reused = new Event();
  await runPhase("decodeInto", () => Event.decodeInto(reused, encoded).payload.length);
} else {
  console.log("decodeInto: (not generated in this build - skipped)");
}
await runPhase("roundtrip", () => Event.decode(Event.encode(sample)).payload.length);
obs.disconnect();
