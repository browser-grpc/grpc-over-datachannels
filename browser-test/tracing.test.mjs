// Browser tracing test: a Chromium/Firefox page runs a nested
// grpc-dc call chain (client -> front callee -> downstream
// service) with a registered span observer. The front handler
// joins the trace via Channel.withTraceContext(ctx.traceContext)
// — the browser-safe propagation path (no ambient async
// context). Asserts one shared trace id and the full parent
// chain in a real browser engine.

import assert from "node:assert/strict";
import { launchBrowser, newPage, runEngines, startStaticServer } from "./harness.mjs";

const { server, pageUrl } = await startStaticServer("browser-test/tracing_page.html");

async function runBrowser(name) {
  const browser = await launchBrowser(name);
  try {
    const page = await newPage(browser, name);
    await page.goto(pageUrl);
    const result = await page.evaluate(() => window.__runTracing());
    assert.equal(result.message, "echo: nested");
    assert.deepEqual(
      result.starts.map((s) => s.kind),
      ["client", "server", "client", "server"],
    );
    const [outerClient, outerServer, innerClient, innerServer] = result.starts;
    assert.ok(result.starts.every((s) => s.traceId === outerClient.traceId));
    assert.equal(outerServer.parentSpanId, outerClient.spanId);
    assert.equal(innerClient.parentSpanId, outerServer.spanId);
    assert.equal(innerServer.parentSpanId, innerClient.spanId);
    assert.equal(result.seenSpanId, outerServer.spanId);
    assert.equal(result.ends.length, 4);
    assert.ok(result.ends.every((e) => e.status === "OK" && e.durationMs >= 0));
    console.log(`${name}: browser nested tracing OK`);
  } finally {
    await browser.close();
  }
}

try {
  await runEngines(process.argv[2], async (name) => {
    await runBrowser(name);
  });
  console.log("browser tracing test passed");
} finally {
  server.close();
}
