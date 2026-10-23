// Real-browser test against the native Go WebRTC stack: a Chromium/
// Firefox page speaking native WebRTC runs the grpc-dc JS client over
// an RTCDataChannel against a gRPC server on webrtc/go (grpcdc Echo).
// Mirrors test.mjs; the answerer is a Go process with SDP exchanged
// through files. Exits non-zero on any mismatch.

import assert from "node:assert/strict";
import { spawn, execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium, firefox } from "playwright";

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
const pageUrl = `http://127.0.0.1:${server.address().port}/browser-test/grpc_page.html`;

// Build the Go server harness.
const dir = mkdtempSync(join(tmpdir(), "grpc-go-server-"));
const harness = join(dir, "grpc_webrtc_server");
execFileSync("go", ["build", "-o", harness, "./cmd/grpc_webrtc_server"], {
  cwd: join(ROOT, "go"),
  stdio: "inherit",
});
const signalBase = join(dir, "signal");

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
    // Playwright's Firefox answers no mDNS queries for its obfuscated
  // .local candidates and will not initiate checks to same-IP pairs,
  // so legs where our stack must reach it need raw IP candidates.
  // Chromium needs no equivalent (it answers mDNS queries itself).
  const launchOptions = { args: ["--no-sandbox", "--disable-dev-shm-usage"] };
  if (name === "firefox") {
    launchOptions.firefoxUserPrefs = {
      "media.peerconnection.ice.obfuscate_host_addresses": false,
    };
  }
  const browser = await engine.launch(launchOptions);
  try {
    const page = await browser.newPage();
    page.on("console", (msg) => console.log(`[${name} console] ${msg.text()}`));
    page.on("pageerror", (err) => console.log(`[${name} pageerror] ${err.message}`));
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

const which = process.argv[2] ?? "chromium";
if (which === "chromium" || which === "all") await runBrowser("chromium", chromium);
if (which === "firefox" || which === "all") await runBrowser("firefox", firefox);

server.close();
console.log("go-server browser test passed");
