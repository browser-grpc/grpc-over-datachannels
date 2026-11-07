// Zig/Wasm nested tracing test: the native Zig runtime
// (wasm32-freestanding, in a Web Worker) runs a nested call
// chain — client -> front callee -> downstream service — with a
// recording span observer in the worker. Asserts one shared
// trace id and the full parent chain in real browser engines.

import assert from "node:assert/strict";
import { launchBrowser, newPage, runEngines, startStaticServer } from "./harness.mjs";

const { server, pageUrl } = await startStaticServer("browser-test/wasm_zig_tracing_page.html", { isolated: true });

async function runBrowser(name) {
  const browser = await launchBrowser(name);
  try {
    const page = await newPage(browser, name);
    await page.goto(pageUrl);
    await page.waitForFunction(() => window.__result || window.__error, null, { timeout: 30000 });
    const error = await page.evaluate(() => window.__error);
    assert.equal(error, undefined, `worker error: ${error}`);
    const result = await page.evaluate(() => window.__result);
    assert.equal(result.message, "echo: nested");
    assert.deepEqual(result.starts.map((s) => s[0]), ["client", "server", "client", "server"]);
    const [outerClient, outerServer, innerClient, innerServer] = result.starts;
    assert.ok(result.starts.every((s) => s[1] === outerClient[1]));
    assert.equal(outerServer[3], outerClient[2]);
    assert.equal(innerClient[3], outerServer[2]);
    assert.equal(innerServer[3], innerClient[2]);
    assert.equal(result.seenSpan, outerServer[2]);
    assert.equal(result.ends, 4);
    console.log(`${name}: Zig/Wasm nested tracing OK`);
  } finally {
    await browser.close();
  }
}

try {
  await runEngines(process.argv[2], runBrowser);
  console.log("zig wasm tracing test passed");
} finally {
  server.close();
}
