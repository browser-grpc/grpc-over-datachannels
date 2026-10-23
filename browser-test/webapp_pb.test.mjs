// Webapp JS message-class test: the browser-generated
// gen/js/<base>_pb.js classes must (a) round-trip a kitchen-sink
// message covering every protobuf scalar, repeated fields, nested
// messages/enums, maps, bytes, and a cross-file reference, (b) be
// byte-identical to protoc's own encoding of the same message, and
// (c) drive the generated Echo stub + JS runtime end-to-end over
// an in-memory DataChannel pair, so the downloaded zip runs as-is.

import assert from "node:assert/strict";
import { execFile, spawn } from "node:child_process";
import { createServer } from "node:http";
import { mkdtemp, readFile, writeFile, mkdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import { extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { chromium, firefox } from "playwright";

const run = promisify(execFile);
const ROOT = fileURLToPath(new URL("..", import.meta.url));
const MIME = {
  ".html": "text/html",
  ".js": "text/javascript",
  ".mjs": "text/javascript",
  ".wasm": "application/wasm",
  ".css": "text/css",
  ".proto": "text/plain",
};

const server = createServer(async (req, res) => {
  try {
    const path = normalize(join(ROOT, decodeURIComponent(new URL(req.url, "http://x").pathname)));
    if (!path.startsWith(ROOT)) throw new Error("outside root");
    const body = await readFile(path);
    // Cross-origin isolation for the Racket/Wasm plugin runner.
    res.writeHead(200, {
      "content-type": MIME[extname(path)] ?? "application/octet-stream",
      "cross-origin-opener-policy": "same-origin",
      "cross-origin-embedder-policy": "require-corp",
    });
    res.end(body);
  } catch {
    res.writeHead(404);
    res.end("not found");
  }
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const baseUrl = `http://127.0.0.1:${server.address().port}`;

function readZip(buf) {
  let eocd = -1;
  for (let i = buf.length - 22; i >= 0; i--) {
    if (buf.readUInt32LE(i) === 0x06054b50) { eocd = i; break; }
  }
  assert.notEqual(eocd, -1, "zip end of central directory not found");
  const count = buf.readUInt16LE(eocd + 10);
  let off = buf.readUInt32LE(eocd + 16);
  const entries = new Map();
  for (let n = 0; n < count; n++) {
    const nameLen = buf.readUInt16LE(off + 28);
    const extraLen = buf.readUInt16LE(off + 30);
    const commentLen = buf.readUInt16LE(off + 32);
    const size = buf.readUInt32LE(off + 20);
    const localOff = buf.readUInt32LE(off + 42);
    const name = buf.toString("utf8", off + 46, off + 46 + nameLen);
    const localNameLen = buf.readUInt16LE(localOff + 26);
    const localExtraLen = buf.readUInt16LE(localOff + 28);
    const dataStart = localOff + 30 + localNameLen + localExtraLen;
    entries.set(name, buf.subarray(dataStart, dataStart + size));
    off += 46 + nameLen + extraLen + commentLen;
  }
  return entries;
}

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

const HARNESS = `
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { EchoRequest, EchoResponse } from "./gen/echo_pb.js";
import { Kitchen, Nested, Color } from "./gen/kitchen_pb.js";
import { Item } from "./gen/common_pb.js";
import { EchoClient, createEchoService } from "./gen/echo_grpc_dc.js";
import { Channel } from "./runtime/channel.js";
import { Server } from "./runtime/server.js";
import { memoryDataChannelPair } from "./runtime/loopback.js";

// Golden protobuf bytes (same vector as js/test/echo.test.js).
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

// protoc oracle: decode protoc's encoding, re-encode byte-identically.
const protocBytes = new Uint8Array(readFileSync(new URL("./protoc.bin", import.meta.url)));
const fromProtoc = Kitchen.decode(protocBytes);
assert.deepEqual(fromProtoc, k);
assert.equal(Buffer.from(Kitchen.encode(fromProtoc)).toString("hex"), Buffer.from(protocBytes).toString("hex"));

// End-to-end: generated stub + generated messages + zip runtime.
const [a, b] = memoryDataChannelPair();
const server = new Server();
server.addService(createEchoService({
  async unary(req) { return new EchoResponse({ message: "echo: " + req.message, index: 0 }); },
  async *serverStream(req) { for (let i = 0; i < req.count; i++) yield new EchoResponse({ message: req.message, index: i }); },
  async clientStream(reqs) { const parts = []; for await (const r of reqs) parts.push(r.message); return new EchoResponse({ message: parts.join("+"), index: parts.length }); },
  async *bidi(reqs) { let i = 0; for await (const r of reqs) yield new EchoResponse({ message: r.message, index: i++ }); },
}));
server.serve(b);
const client = new EchoClient(new Channel(a));
const unary = await client.unary(new EchoRequest({ message: "hello" }));
assert.equal(unary.message, "echo: hello");
const streamed = [];
for await (const resp of await client.serverStream(new EchoRequest({ message: "tick", count: 3 }))) streamed.push(resp.index);
assert.deepEqual(streamed, [0, 1, 2]);
async function* reqs() { yield new EchoRequest({ message: "a" }); yield new EchoRequest({ message: "b" }); }
const joined = await client.clientStream(reqs());
assert.equal(joined.message, "a+b");
console.log("webapp pb harness OK");
`;

async function runCase(name, engine) {
  const browser = await engine.launch({});
  try {
    const page = await browser.newPage();
    page.on("pageerror", (err) => console.log(`[${name} pageerror] ${err.message}`));
    await page.goto(`${baseUrl}/webapp/index.html`);
    await page.waitForFunction(() => window.__webappReady, null, { timeout: 60000 });
    await page.waitForSelector("#status.ok", { timeout: 60000 });
    await page.setInputFiles("#upload", [join(ROOT, "webapp/testdata/common.proto"), join(ROOT, "webapp/testdata/kitchen.proto")]);
    await page.waitForFunction(
      () => document.querySelector("#tree").textContent.includes("kitchen.v1"),
      null,
      { timeout: 30000 },
    );
    await page.$$eval("#langs input[data-lang]", (els) => {
      for (const cb of els) cb.checked = cb.dataset.lang === "js";
    });
    const [download] = await Promise.all([
      page.waitForEvent("download", { timeout: 240000 }),
      page.click("#generate"),
    ]);
    // The zip under execution must come from the real Racket
    // plugins running in the Wasm runtime.
    const via = await page.evaluate(() => window.__generatedVia);
    assert.ok(typeof via === "string" && via.startsWith("Racket plugins in-browser"), `${name}: expected Racket/Wasm generation, got: ${via}`);
    const entries = readZip(await readFile(await download.path()));
    for (const f of ["echo_pb.js", "common_pb.js", "kitchen_pb.js", "echo_grpc_dc.js"]) {
      assert.ok(entries.has(`gen/js/${f}`), `zip missing gen/js/${f}`);
    }
    // In-browser preview: the page itself imported the generated
    // JS bundle and round-tripped every message class.
    await page.waitForFunction(() => window.__jsPreview && window.__jsPreview.ok, null, { timeout: 60000 });
    const preview = await page.evaluate(() => window.__jsPreview);
    assert.ok(preview.files >= 3, `preview covered the pb files: ${JSON.stringify(preview)}`);
    assert.ok(preview.classes >= 3, `preview round-tripped message classes: ${JSON.stringify(preview)}`);
    assert.match(await page.textContent("#preview"), /round-trip OK/);
    const dir = await mkdtemp(join(tmpdir(), "grpcdc-pb-"));
    await mkdir(join(dir, "gen"), { recursive: true });
    await mkdir(join(dir, "runtime"), { recursive: true });
    for (const [name, data] of entries) {
      if (name.startsWith("gen/js/")) await writeFile(join(dir, "gen", name.slice("gen/js/".length)), data);
      if (name.startsWith("runtime/js/")) await writeFile(join(dir, "runtime", name.slice("runtime/js/".length)), data);
      if (name === "runtime/wire_gen.js") await writeFile(join(dir, "wire_gen.js"), data);
    }
    const protocBytes = await new Promise((resolve, reject) => {
      const p = spawn("protoc", [
        "--encode=kitchen.v1.Kitchen",
        "-I", join(ROOT, "webapp/testdata"),
        "kitchen.proto",
      ], { cwd: join(ROOT, "webapp/testdata") });
      const chunks = [];
      p.stdout.on("data", (c) => chunks.push(c));
      p.on("error", reject);
      p.on("close", (code) => (code === 0 ? resolve(Buffer.concat(chunks)) : reject(new Error("protoc exit " + code))));
      p.stdin.end(KITCHEN_TEXT);
    });
    await writeFile(join(dir, "protoc.bin"), protocBytes);
    await writeFile(join(dir, "run.mjs"), HARNESS);
    const { stdout } = await run("node", [join(dir, "run.mjs")], { cwd: dir });
    assert.match(stdout, /webapp pb harness OK/);
    console.log(`${name}: webapp pb OK (round-trip, protoc oracle, loopback end-to-end)`);
  } finally {
    await browser.close();
  }
}

const which = process.argv[2] ?? "all";
if (which === "chromium" || which === "all") await runCase("chromium", chromium);
if (which === "firefox" || which === "all") await runCase("firefox", firefox);
console.log("webapp pb test passed");
server.close();
