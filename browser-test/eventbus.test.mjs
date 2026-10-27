// Event-bus browser test: a Chromium/Firefox/WebKit page uses the
// grpc-dc JS EventBus client (subscribe with a tag filter, then
// publish) against the generated Go EventBusBroker served by the
// native Go WebRTC stack. Mirrors go_server.test.mjs (native
// answerer, SDP through files). The page asserts containment
// filtering end-to-end: it publishes one noise event that its own
// filter must drop. Exits non-zero on any mismatch.

import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { join } from "node:path";
import { buildGoHarness, launchBrowser, newPage, runEngines, startStaticServer, waitForFile } from "./harness.mjs";

const { server, pageUrl } = await startStaticServer("browser-test/eventbus_page.html");

const { dir, bin: harness } = buildGoHarness("grpc_webrtc_eventbus_server", "grpc-eventbus-");
let signalBase = join(dir, "signal");


async function runBrowser(name) {
  const proc = spawn(harness, [signalBase], { stdio: ["ignore", "inherit", "inherit"] });
  const browser = await launchBrowser(name);
  try {
    const page = await newPage(browser, name);
    await page.goto(pageUrl);
    await page.waitForFunction(() => window.__offer, null, { timeout: 30000 });

    const { writeFileSync } = await import("node:fs");
    writeFileSync(`${signalBase}.offer`, await page.evaluate(() => window.__offer));
    const answer = await waitForFile(`${signalBase}.answer`);
    await page.evaluate((sdp) => window.__acceptAnswer(sdp), answer);

    const result = await page.evaluate(() => window.__runBus());
    assert.deepEqual(result.seqs, [1, 2, 3]);
    assert.deepEqual(result.received, ["1:o1", "3:o2"]);
    console.log(`${name}: browser event bus over Go broker OK`, result);
  } finally {
    await browser.close();
    proc.kill();
  }
}

try {
  await runEngines(process.argv[2], async (name, i) => {
    signalBase = join(dir, `signal-${i}`);
    await runBrowser(name);
  });
  console.log("eventbus browser test passed");
} finally {
  server.close();
}
