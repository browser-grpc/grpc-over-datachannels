// OTLP example smoke test: examples/tracing/otlp.mjs runs the
// nested call chain against its self-check collector and must
// report the four-span verified payload.
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");

test("otlp example self-check", async () => {
  const { stdout } = await execFileAsync(
    process.execPath,
    [path.join(root, "examples/tracing/otlp.mjs")],
    { cwd: root, timeout: 30000, env: { ...process.env, OTEL_EXPORTER_OTLP_TRACES_ENDPOINT: "" } },
  );
  assert.match(stdout, /OTLP_EXAMPLE_OK spans=4 trace=[0-9a-f]{32}/);
});
