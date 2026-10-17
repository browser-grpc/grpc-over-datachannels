// Generated JS message classes (<base>_pb.js) from the native
// protoc-gen-grpc-dc-js plugin: kitchen-sink round-trip plus a
// protoc oracle — protoc's own --encode bytes must decode to the
// same message and re-encode byte-identically.

import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { promisify } from "node:util";
import test from "node:test";

const run = promisify(execFile);
const ROOT = fileURLToPath(new URL("../..", import.meta.url));
const TESTDATA = join(ROOT, "webapp", "testdata");

const KITCHEN_TEXT = `
d: 1.5 f: 2.5 i32: -3 i64: -4 u32: 5 u64: 6 s32: -7 s64: -8
f32: 9 f64: 10 sf32: -11 sf64: -12 flag: true name: "sink"
blob: "\\x01\\x02\\x03" color: GREEN
nested { note: "n" level: 3 }
item { sku: "abc" quantity: 2 }
nums: [1, -2, 300] words: ["a", "", "bc"]
manys { note: "m" level: 1 }
vals: [0.5, -1.25]
counts { key: "x" value: 1 } counts { key: "y" value: -2 }
by_id { key: 7 value { note: "z" level: 9 } }
text: "chosen" big_negative: -9007199254740993 neg32: -123456
`;

test("native JS plugin emits working <base>_pb.js", async () => {
  const out = await mkdtemp(join(tmpdir(), "grpcdc-js-pb-"));
  const plugin = join(ROOT, "bin", "protoc-gen-grpc-dc-js");
  await run("protoc", [
    `--plugin=protoc-gen-grpc-dc-js=${plugin}`,
    `--grpc-dc-js_out=${out}`,
    "-I", TESTDATA, "common.proto", "kitchen.proto",
  ], { cwd: TESTDATA });
  // echo.proto too, for the golden-byte vector.
  await run("protoc", [
    `--plugin=protoc-gen-grpc-dc-js=${plugin}`,
    `--grpc-dc-js_out=${out}`,
    "-I", join(ROOT, "proto"), "echo.proto",
  ], { cwd: ROOT });

  const commonPb = await import(pathToFileURL(join(out, "common_pb.js")));
  const kitchenPb = await import(pathToFileURL(join(out, "kitchen_pb.js")));
  const echoPb = await import(pathToFileURL(join(out, "echo_pb.js")));
  const { Kitchen, Nested, Color } = kitchenPb;
  const { Item } = commonPb;
  const { EchoRequest } = echoPb;

  const enc = EchoRequest.encode(new EchoRequest({ message: "hi", count: 2 }));
  assert.equal(Buffer.from(enc).toString("hex"), "0a0268691002");

  const k = new Kitchen({
    d: 1.5, f: 2.5, i32: -3, i64: -4n, u32: 5, u64: 6n, s32: -7, s64: -8n,
    f32: 9, f64: 10n, sf32: -11, sf64: -12n, flag: true, name: "sink",
    blob: new Uint8Array([1, 2, 3]), color: Color.GREEN,
    nested: new Nested({ note: "n", level: 3 }),
    item: new Item({ sku: "abc", quantity: 2 }),
    nums: [1, -2, 300], words: ["a", "", "bc"],
    manys: [new Nested({ note: "m", level: 1 })],
    vals: [0.5, -1.25],
    counts: new Map([["x", 1], ["y", -2]]),
    byId: new Map([[7n, new Nested({ note: "z", level: 9 })]]),
    text: "chosen", bigNegative: -9007199254740993n, neg32: -123456,
  });
  assert.deepEqual(Kitchen.decode(Kitchen.encode(k)), k);
  assert.equal(Kitchen.encode(new Kitchen()).length, 0);
  assert.deepEqual(Kitchen.decode(new Uint8Array(0)), new Kitchen());

  const protocBytes = await new Promise((resolve, reject) => {
    import("node:child_process").then(({ spawn }) => {
      const p = spawn("protoc", ["--encode=kitchen.v1.Kitchen", "-I", TESTDATA, "kitchen.proto"], { cwd: TESTDATA });
      const chunks = [];
      p.stdout.on("data", (c) => chunks.push(c));
      p.on("error", reject);
      p.on("close", (code) => (code === 0 ? resolve(Buffer.concat(chunks)) : reject(new Error("protoc exit " + code))));
      p.stdin.end(KITCHEN_TEXT);
    }, reject);
  });
  const fromProtoc = Kitchen.decode(new Uint8Array(protocBytes));
  assert.deepEqual(fromProtoc, k);
  assert.equal(
    Buffer.from(Kitchen.encode(fromProtoc)).toString("hex"),
    Buffer.from(protocBytes).toString("hex"),
  );
});
