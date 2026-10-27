// Real-browser test against the native Go WebRTC stack: a Chromium/
// Firefox page speaking native WebRTC runs the grpc-dc JS client over
// an RTCDataChannel against a gRPC server on webrtc/go (grpcdc Echo).
// Mirrors test.mjs; the answerer is a Go process with SDP exchanged
// through files. Exits non-zero on any mismatch.

import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { buildGoHarness, launchBrowser, newPage, runEngines, startStaticServer, waitForFile } from "./harness.mjs";

const { server, pageUrl } = await startStaticServer("browser-test/grpc_page.html");

const { dir, bin: harness } = buildGoHarness("grpc_webrtc_server", "grpc-go-server-");
let signalBase = join(dir, "signal");


async function runBrowser(name) {
  const proc = spawn(harness, [signalBase], { stdio: ["ignore", "inherit", "inherit"] });
    // Playwright's Firefox answers no mDNS queries for its obfuscated
  // .local candidates and will not initiate checks to same-IP pairs,
  // so legs where our stack must reach it need raw IP candidates.
  // Chromium needs no equivalent (it answers mDNS queries itself).
  const browser = await launchBrowser(name);
  try {
    const page = await newPage(browser, name);
    await page.goto(pageUrl);
    await page.waitForFunction(() => window.__offer, null, { timeout: 30000 });

    const offer = await page.evaluate(() => window.__offer);
    writeFileSync(`${signalBase}.offer`, offer);
    const answer = await waitForFile(`${signalBase}.answer`);
    await page.evaluate((sdp) => window.__acceptAnswer(sdp), answer);

    const result = await page.evaluate(() => window.__runGrpc());
    assert.equal(result.unary, "echo: hello");
    assert.deepEqual(result.ticks, [0, 1, 2]);
    assert.deepEqual(result.echoed, ["x", "y"]);
    console.log(`${name}: browser gRPC over Go WebRTC stack OK`, result);
  } finally {
    await browser.close();
    proc.kill();
  }
}

await runEngines(process.argv[2], async (name, i) => {
  signalBase = join(dir, `signal-${i}`);
  await runBrowser(name);
});

server.close();
console.log("go-server browser test passed");
