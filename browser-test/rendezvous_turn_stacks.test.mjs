// Real-browser test: Rendezvous over TURN against the NATIVE
// (Rust dc-webrtc) stack — the matrix cell rendezvous_turn
// .test.mjs does not cover (it pairs the JS stack's listener
// with the fake TURN server).
//
// The page dials the Rust rendezvous_echo server with
// iceTransportPolicy "relay" through a real coturn
// (long-term credentials dcuser/dcpass, matching
// rendezvous_turn_page.html), falling back to the repo's fake
// TURN server when no turnserver binary is available.
//
// STATUS: FAILING as of v0.42.0 — see
// https://github.com/browser-grpc/grpc-over-datachannels/issues/1
// The browser gathers host/srflx/relay candidates and the TURN
// allocation succeeds, but ICE against the Rust listener goes
// checking -> disconnected -> failed and the data channel
// never opens. Direct (non-relay) dials to the same listener
// (rendezvous_stacks.test.mjs) pass, and the JS stack passes
// its fake-TURN test, so the defect is specific to
// browser + real TURN relay + native listener.

import assert from "node:assert/strict";
import { execFileSync, spawn, spawnSync } from "node:child_process";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium, firefox, webkit } from "playwright";

import { fakeTurnServer } from "../webrtc/js/test/fake_turn.js";

const ROOT = fileURLToPath(new URL("..", import.meta.url));
const MIME = { ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript" };
const TURN_PORT = 3478;

function firstStdoutLine(proc) {
  return new Promise((resolve, reject) => {
    let buf = "";
    proc.stdout.on("data", (chunk) => {
      buf += chunk;
      const at = buf.indexOf("\n");
      if (at >= 0) resolve(buf.slice(0, at));
    });
    proc.on("exit", (code) => reject(new Error(`server exited early (${code}): ${buf}`)));
    setTimeout(() => reject(new Error(`server printed no descriptor: ${buf}`)), 120000);
  });
}

async function buildRustServer() {
  execFileSync("cargo", ["build", "--features", "webrtc", "--example", "rendezvous_echo"], {
    cwd: join(ROOT, "rust"),
    stdio: "inherit",
  });
  return join(ROOT, "rust", "target", "debug", "examples", "rendezvous_echo");
}

function startCoturn() {
  const probe = spawnSync("turnserver", ["--help"], { stdio: "ignore" });
  if (probe.error) return null;
  const proc = spawn("turnserver", [
    "-p", String(TURN_PORT),
    "-l", "127.0.0.1",
    "--min-port", "49152", "--max-port", "49200",
    "--lt-cred-mech", "--user", "dcuser:dcpass", "--realm", "dc.test",
    "--log-file", "stdout", "--simple-log",
    "--no-multicast-peers", "--allowed-peer-ip=127.0.0.1",
  ], { stdio: ["ignore", "inherit", "inherit"] });
  return { server: `127.0.0.1:${TURN_PORT}`, close: () => proc.kill(), real: true };
}

async function startTurn() {
  const coturn = startCoturn();
  if (coturn) {
    console.log(`using real coturn at ${coturn.server}`);
    // Give coturn a moment to bind before browsers allocate.
    await new Promise((r) => setTimeout(r, 1000));
    return coturn;
  }
  const fake = await fakeTurnServer();
  console.log(`turnserver not found; using fake TURN at ${fake.server}`);
  return { ...fake, real: false };
}

const turn = await startTurn();
const bin = await buildRustServer();
const proc = spawn(bin, [], { stdio: ["ignore", "pipe", "inherit"] });
try {
  const descriptor = JSON.parse(await firstStdoutLine(proc));
  console.log("rust rendezvous descriptor:", descriptor);

  const server = createServer(async (req, res) => {
    if (req.url.startsWith("/rendezvous.json")) {
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify(descriptor));
      return;
    }
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
  const pageUrl =
    `http://127.0.0.1:${server.address().port}/browser-test/rendezvous_turn_page.html` +
    `?turn=${encodeURIComponent(turn.server)}`;
  try {
    const which = process.argv[2] ?? "chromium";
    if (which === "chromium" || which === "all") await runBrowser("chromium", chromium, pageUrl);
    if (which === "firefox" || which === "all") await runBrowser("firefox", firefox, pageUrl);
    if (which === "webkit" || which === "all") await runBrowser("webkit", webkit, pageUrl);
  } finally {
    server.close();
  }
} finally {
  proc.kill();
  turn.close();
}
console.log("rendezvous-over-TURN (native stack) browser test passed");

async function runBrowser(name, engine, pageUrl) {
  const launchOptions = { args: ["--no-sandbox", "--disable-dev-shm-usage"] };
  if (name === "firefox") {
    launchOptions.firefoxUserPrefs = {
      "media.peerconnection.ice.obfuscate_host_addresses": false,
    };
  }
  if (name === "webkit") delete launchOptions.args;
  const browser = await engine.launch(launchOptions);
  try {
    const page = await browser.newPage();
    page.on("console", (msg) => console.log(`[${name} console] ${msg.text()}`));
    page.on("pageerror", (err) => console.log(`[${name} pageerror] ${err.message}`));
    await page.goto(pageUrl);
    // No probe-and-skip here (unlike rendezvous_turn.test.mjs):
    // a relay candidate IS gathered in this environment (see
    // issue #1), so "did not open" is the failure under test,
    // not an environment limitation.
    const result = await page.evaluate(() => window.__runRendezvousTurn());
    assert.equal(result.unary, "echo: hello-turn");
    assert.equal(result.localType, "relay", `nominated local candidate is not relay: ${JSON.stringify(result)}`);
    console.log(`${name}: browser rendezvous over TURN (native stack, real=${turn.real}) OK`, result);
  } finally {
    await browser.close();
  }
}
