// Dart/Wasm nested tracing test: the native Dart runtime
// compiled to WasmGC runs a nested call chain — client -> front
// callee -> downstream service — over memory transports in the
// page, with a recording span observer in the module. Asserts
// one shared trace id and the full parent chain in real browser
// engines.

import assert from "node:assert/strict";
import { launchBrowser, newPage, runEngines, startStaticServer } from "./harness.mjs";

const { server, pageUrl } = await startStaticServer("browser-test/dart_wasm_tracing_page.html", { isolated: true });

async function runBrowser(name) {
  const browser = await launchBrowser(name);
  try {
    const page = await newPage(browser, name);
    await page.goto(pageUrl);
    await page.waitForFunction(() => window.__runTracing || window.__wasmError, null, { timeout: 30000 });
    if (await page.evaluate(() => window.__wasmError)) {
      console.log(`${name}: Dart/Wasm unavailable, skipping tracing leg`);
      return;
    }
    const result = await page.evaluate(() => window.__runTracing());
    assert.equal(result.message, "echo: nested");
    assert.deepEqual(result.starts.map((s) => s[0]), ["client", "server", "client", "server"]);
    const [outerClient, outerServer, innerClient, innerServer] = result.starts;
    assert.ok(result.starts.every((s) => s[1] === outerClient[1]));
    assert.equal(outerServer[3], outerClient[2]);
    assert.equal(innerClient[3], outerServer[2]);
    assert.equal(innerServer[3], innerClient[2]);
    assert.equal(result.seenSpan, outerServer[2]);
    assert.equal(result.ends.length, 4);
    assert.equal(result.ends.filter((k) => k === "client").length, 2);
    assert.equal(result.ends.filter((k) => k === "server").length, 2);
    console.log(`${name}: Dart/Wasm nested tracing OK`);
  } finally {
    await browser.close();
  }
}

try {
  await runEngines(process.argv[2], runBrowser);
  console.log("dart wasm tracing test passed");
} finally {
  server.close();
}
