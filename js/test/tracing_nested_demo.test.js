// Video demo gate: js/examples/tracing_nested_demo.mjs (used by
// video/scripts/tracing.json) must print one parented span tree.
import { spawn } from "node:child_process";
import test from "node:test";
import assert from "node:assert/strict";

test("nested tracing demo prints one parented tree", async () => {
  const out = await new Promise((resolve, reject) => {
    const p = spawn("node", ["examples/tracing_nested_demo.mjs"], {
      cwd: new URL("..", import.meta.url),
    });
    let buf = "";
    p.stdout.on("data", (d) => (buf += d));
    p.stderr.on("data", (d) => (buf += d));
    p.on("close", (c) => (c === 0 ? resolve(buf) : reject(new Error(`exit ${c}\n${buf}`))));
  });
  const lines = out.trim().split("\n");
  assert.equal(lines.length, 9);
  assert.match(lines[8], /response: echo: nested/);
  const trace = (l) => l.match(/trace=([0-9a-f]+)/)[1];
  const span = (l) => l.match(/span=([0-9a-f]+)/)[1];
  const parent = (l) => (l.match(/parent=([0-9a-f-]+)/) || [])[1];
  assert.ok(lines.slice(0, 8).every((l) => trace(l) === trace(lines[0])));
  assert.equal(parent(lines[1]), span(lines[0]));
  assert.equal(parent(lines[2]), span(lines[1]));
  assert.equal(parent(lines[3]), span(lines[2]));
});
