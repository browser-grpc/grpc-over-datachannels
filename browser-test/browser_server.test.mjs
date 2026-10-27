// Browser-as-server test: a Chromium/Firefox page speaking native
// WebRTC runs the grpc-dc JS SERVER over an RTCDataChannel, and the
// native Go WebRTC stack (webrtc/go) drives it with the generated Go
// grpc-dc client. Mirrors go_server.test.mjs with the roles flipped:
// the native side offers, the browser answers and serves. SDP is
// exchanged through files. Exits non-zero on any mismatch.

import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { join } from "node:path";
import { buildGoHarness, launchBrowser, newPage, runEngines, startStaticServer, waitForFile } from "./harness.mjs";

const { server, pageUrl } = await startStaticServer("browser-test/grpc_server_page.html");

const { dir, bin: harness } = buildGoHarness("grpc_webrtc_client", "grpc-go-client-");
let signalBase = join(dir, "signal");


async function runBrowser(name) {
  let stderrText = "";
  const proc = spawn(harness, [signalBase], { stdio: ["ignore", "pipe", "pipe"] });
  proc.stderr.on("data", (chunk) => {
    stderrText += chunk;
    process.stderr.write(`[${name} harness] ${chunk}`);
  });
  const exited = new Promise((resolve) => proc.on("close", resolve));
    // Playwright's Firefox answers no mDNS queries for its obfuscated
  // .local candidates and will not initiate checks to same-IP pairs,
  // so legs where our stack must reach it need raw IP candidates.
  // Chromium needs no equivalent (it answers mDNS queries itself).
  const browser = await launchBrowser(name, { extraArgs: ["--disable-features=WebRtcHideLocalIpsWithMdns"] });
  try {
    const page = await newPage(browser, name);
    await page.goto(pageUrl);

    const offer = await waitForFile(`${signalBase}.offer`);
    await page.evaluate((sdp) => window.__acceptOffer(sdp), offer);
    const answer = await page.evaluate(() => window.__answer);
    const { writeFileSync } = await import("node:fs");
    writeFileSync(`${signalBase}.answer`, answer);

    const code = await Promise.race([
      exited,
      new Promise((_, reject) => setTimeout(() => reject(new Error("client harness timed out")), 60000)),
    ]);
    assert.equal(code, 0, `client harness exit ${code}:\n${stderrText}`);
    assert.match(stderrText, /unary=echo: hello/);
    assert.match(stderrText, /server_stream=tick#0,tick#1,tick#2/);
    assert.match(stderrText, /client_stream=a\+b\+c/);
    assert.match(stderrText, /bidi=x,y/);
    const served = await page.evaluate(() => window.__servedChannels);
    assert.equal(served, 1, "browser should have served exactly one channel");
    console.log(`${name}: native gRPC client over Go WebRTC stack against browser server OK`);
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
console.log("browser-as-server test passed");
