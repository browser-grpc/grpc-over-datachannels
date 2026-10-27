// Event-bus browser test: a Chromium/Firefox/WebKit page uses the
// grpc-dc JS EventBus client (subscribe with a tag filter, then
// publish) against the generated Go EventBusBroker served by the
// native Go WebRTC stack. Mirrors go_server.test.mjs (native
// answerer, SDP through files). The page asserts containment
// filtering end-to-end: it publishes one noise event that its own
// filter must drop. Exits non-zero on any mismatch.

import assert from "node:assert/strict";
import { spawn, execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, existsSync } from "node:fs";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium, firefox, webkit } from "playwright";

const ROOT = fileURLToPath(new URL("..", import.meta.url));
const MIME = { ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript" };

const server = createServer(async (req, res) => {
  try {
    const path = normalize(join(ROOT, decodeURIComponent(new URL(req.url, "http://x").pathname)));
    if (!path.startsWith(ROOT)) throw new Error("outside root");
    const body = await readFile(path);
    res.writeHead(200, { "content-type": MIME[extname(path)] ?? "application/octet-stream" });
    res.end(body);
  } catch {
    res.writeHead(404);
    res.end("not found");
  }
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const pageUrl = `http://127.0.0.1:${server.address().port}/browser-test/eventbus_page.html`;

// Build the Go event-bus server harness.
const dir = mkdtempSync(join(tmpdir(), "grpc-eventbus-"));
const harness = join(dir, "grpc_webrtc_eventbus_server");
execFileSync("go", ["build", "-o", harness, "./cmd/grpc_webrtc_eventbus_server"], {
  cwd: join(ROOT, "go"),
  stdio: "inherit",
});
let signalBase = join(dir, "signal");

async function waitForFile(path, timeoutMs = 30000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (existsSync(path)) {
      const content = readFileSync(path, "utf8");
      if (content.trim()) return content;
    }
    await new Promise((r) => setTimeout(r, 50));
  }
  throw new Error(`timed out waiting for ${path}`);
}

async function runBrowser(name, engine) {
  const proc = spawn(harness, [signalBase], { stdio: ["ignore", "inherit", "inherit"] });
  const launchOptions = { args: ["--no-sandbox", "--disable-dev-shm-usage"] };
  if (name === "firefox") {
    launchOptions.firefoxUserPrefs = {
      "media.peerconnection.ice.obfuscate_host_addresses": false,
    };
  }
  if (name === "webkit") delete launchOptions.args; // Chromium-only flags
  const browser = await engine.launch(launchOptions);
  try {
    const page = await browser.newPage();
    page.on("console", (msg) => console.log(`[${name} console] ${msg.text()}`));
    page.on("pageerror", (err) => console.log(`[${name} pageerror] ${err.message}`));
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
  const which = process.argv[2] ?? "chromium";
  const enginesToRun = which === "all" ? ["chromium", "firefox", "webkit"] : [which];
  for (const [i, engineName] of enginesToRun.entries()) {
    signalBase = join(dir, `signal-${i}`);
    await runBrowser(engineName, { chromium, firefox, webkit }[engineName]);
  }
  console.log("eventbus browser test passed");
} finally {
  server.close();
}
