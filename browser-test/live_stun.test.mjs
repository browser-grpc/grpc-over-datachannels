// Live STUN smoke test, browser counterpart of the native
// stacks' live_stun tests: a real browser RTCPeerConnection
// configured with Google's public STUN servers must gather a
// server-reflexive (srflx) candidate. This is the only browser
// leg that crosses a real public NAT mapping; every other
// browser test uses fake TURN/STUN on loopback.
//
// Opt-in like the native ones: exits SKIP unless
// GRPC_DC_LIVE_STUN is set (make test-live-stun sets it; the
// CI-full-run gate enables it when CI=true). Engines mirror
// go_server.test.mjs: argv[2] picks chromium|firefox|webkit|all.

import assert from "node:assert/strict";
import { createServer } from "node:http";
import { chromium, firefox, webkit } from "playwright";

if (!process.env.GRPC_DC_LIVE_STUN) {
  console.log("live_stun: SKIP (GRPC_DC_LIVE_STUN not set)");
  process.exit(0);
}

const server = createServer((_req, res) => {
  res.writeHead(200, { "content-type": "text/html" });
  res.end(`<!doctype html><script>
    window.__candidates = [];
    window.__done = false;
    const pc = new RTCPeerConnection({
      iceServers: [{ urls: [
        "stun:stun.l.google.com:19302",
        "stun:stun1.l.google.com:19302",
      ] }],
    });
    pc.onicecandidate = (e) => {
      if (e.candidate) {
        window.__candidates.push(e.candidate.candidate);
      } else {
        window.__done = true;
      }
    };
    pc.createDataChannel("live-stun");
    pc.createOffer().then((o) => pc.setLocalDescription(o));
  </script>`);
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const pageUrl = `http://127.0.0.1:${server.address().port}/`;

async function runBrowser(name, engine) {
  const launchOptions = { args: ["--no-sandbox", "--disable-dev-shm-usage"] };
  if (name === "webkit") delete launchOptions.args; // Chromium-only flags
  const browser = await engine.launch(launchOptions);
  try {
    const page = await browser.newPage();
    await page.goto(pageUrl);
    await page.waitForFunction(() => window.__done, null, { timeout: 30000 });
    const candidates = await page.evaluate(() => window.__candidates);
    const srflx = candidates.find((c) => c.includes(" typ srflx "));
    assert.ok(srflx, `${name}: no srflx candidate from Google STUN:\n${candidates.join("\n")}`);
    console.log(`${name}: live srflx OK: ${srflx}`);
  } finally {
    await browser.close();
  }
}

try {
  const which = process.argv[2] ?? "chromium";
  const enginesToRun = which === "all" ? ["chromium", "firefox", "webkit"] : [which];
  for (const engineName of enginesToRun) {
    await runBrowser(engineName, { chromium, firefox, webkit }[engineName]);
  }
  console.log("live_stun: PASSED");
} finally {
  server.close();
}
