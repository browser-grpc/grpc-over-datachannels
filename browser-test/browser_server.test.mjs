// Browser-as-server test: a Chromium/Firefox page speaking native
// WebRTC runs the grpc-dc JS SERVER over an RTCDataChannel, and the
// native Go WebRTC stack (webrtc/go) drives it with the generated Go
// grpc-dc client. Mirrors go_server.test.mjs with the roles flipped:
// the native side offers, the browser answers and serves. SDP is
// exchanged through files. Exits non-zero on any mismatch.

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
const pageUrl = `http://127.0.0.1:${server.address().port}/browser-test/grpc_server_page.html`;

// Build the Go client harness.
const dir = mkdtempSync(join(tmpdir(), "grpc-go-client-"));
const harness = join(dir, "grpc_webrtc_client");
execFileSync("go", ["build", "-o", harness, "./cmd/grpc_webrtc_client"], {
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
  const launchOptions = { args: ["--no-sandbox", "--disable-dev-shm-usage", "--disable-features=WebRtcHideLocalIpsWithMdns"] };
  if (name === "firefox") {
    launchOptions.firefoxUserPrefs = {
      "media.peerconnection.ice.obfuscate_host_addresses": false,
    };
  }
  if (name === "webkit") delete launchOptions.args; // Chromium-only flags; MiniBrowser rejects them
  const browser = await engine.launch(launchOptions);
  try {
    const page = await browser.newPage();
    page.on("console", (msg) => console.log(`[${name} console] ${msg.text()}`));
    page.on("pageerror", (err) => console.log(`[${name} pageerror] ${err.message}`));
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

const which = process.argv[2] ?? "chromium";
// Fresh signal base per engine: the harness watches <base>.offer
// and a previous engine's .answer would otherwise be consumed
// as this engine's answer (silent cross-engine hang in "all").
const enginesToRun = which === "all" ? ["chromium", "firefox", "webkit"] : [which];
for (const [i, engineName] of enginesToRun.entries()) {
  signalBase = join(dir, `signal-${i}`);
  await runBrowser(engineName, { chromium, firefox, webkit }[engineName]);
}

server.close();
console.log("browser-as-server test passed");
