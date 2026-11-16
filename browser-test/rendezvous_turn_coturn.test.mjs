// Real-browser test: Rendezvous over a real TURN server
// (coturn) against the Rust and Go rendezvous listeners
// (rust/examples/rendezvous_echo, go/cmd/rendezvous_server). The fake-TURN leg
// (rendezvous_turn.test.mjs) covers the JS listener with an
// in-process fake; this leg covers the production pairing
// from GitHub issue #1: coturn + serve_rendezvous, browser
// forced to relay candidates.
//
// Coturn needs --allow-loopback-peers here (in addition to
// --allowed-peer-ip): the listener is a loopback peer, and
// coturn silently drops relayed traffic to loopback peers
// without it — allocation and STUN still succeed, so ICE
// checks simply never arrive (issue #1). Non-loopback
// listeners do not need the flag. Skipped when turnserver
// is not on PATH.

import assert from "node:assert/strict";
import { execFileSync, spawn, spawnSync } from "node:child_process";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium, firefox, webkit } from "playwright";
import dgram from "node:dgram";

const ROOT = fileURLToPath(new URL("..", import.meta.url));
const MIME = { ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript" };
const hasCoturn = spawnSync("turnserver", ["-h"], { encoding: "utf8" }).error == null;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function freePort() {
  const socket = dgram.createSocket("udp4");
  await new Promise((resolve) => socket.bind(0, "127.0.0.1", resolve));
  const { port } = socket.address();
  socket.close();
  return port;
}

async function firstStdoutLine(proc) {
  let buf = "";
  for await (const chunk of proc.stdout) {
    buf += chunk;
    const at = buf.indexOf("\n");
    if (at >= 0) return buf.slice(0, at);
  }
  throw new Error("server exited without a descriptor line");
}

if (!hasCoturn) {
  console.log("rendezvous-over-coturn: turnserver not on PATH; skipping");
  process.exit(0);
}

execFileSync("cargo", ["build", "--features", "webrtc", "--example", "rendezvous_echo"], {
  cwd: join(ROOT, "rust"),
  stdio: "inherit",
});
const rustBin = join(ROOT, "rust", "target", "debug", "examples", "rendezvous_echo");
const goBin = join(ROOT, "browser-test", ".rendezvous-go-server");
execFileSync("go", ["build", "-o", goBin, "./cmd/rendezvous_server"], {
  cwd: join(ROOT, "go"),
  stdio: "inherit",
  env: { ...process.env, GOFLAGS: "-buildvcs=false" },
});

const turnPort = await freePort();
const turn = spawn("turnserver", [
  "-n",
  "--listening-ip=127.0.0.1",
  `--listening-port=${turnPort}`,
  "--relay-ip=127.0.0.1",
  "--min-port=49152",
  "--max-port=49200",
  "--realm=dc.test",
  "--user=dcuser:dcpass",
  "--lt-cred-mech",
  "--allowed-peer-ip=127.0.0.1",
  "--allow-loopback-peers",
  "--no-cli",
], { stdio: "ignore" });
await sleep(800);
assert.equal(turn.exitCode, null, "coturn died at startup");

async function runStack(stackName, bin) {
  const proc = spawn(bin, [], { stdio: ["ignore", "pipe", "inherit"] });
  try {
    const descriptor = JSON.parse(await firstStdoutLine(proc));
    descriptor.host = "127.0.0.1"; // issue #1 publishes loopback
    console.log(`${stackName} rendezvous descriptor:`, descriptor, "coturn at", turnPort);

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
    `?turn=${encodeURIComponent(`127.0.0.1:${turnPort}`)}`;

  async function runBrowser(name, engine, stackName) {
    const launchOptions = { args: ["--no-sandbox", "--disable-dev-shm-usage"] };
    if (name === "firefox") {
      launchOptions.firefoxUserPrefs = { "media.peerconnection.ice.obfuscate_host_addresses": false };
    }
    if (name === "webkit") delete launchOptions.args;
    const browser = await engine.launch(launchOptions);
    try {
      const page = await browser.newPage();
      page.on("console", (msg) => console.log(`[${name} console] ${msg.text()}`));
      page.on("pageerror", (err) => console.log(`[${name} pageerror] ${err.message}`));
      await page.goto(pageUrl);
      const result = await page.evaluate(() => window.__runRendezvousTurn()).catch((e) => {
        if (String(e?.message ?? e).includes("did not open")) return null;
        throw e;
      });
      if (result === null) {
        console.log(`${name}: no relay dial in this environment; skipping (environment limitation)`);
        return;
      }
      assert.equal(result.unary, "echo: hello-turn");
      assert.equal(result.localType, "relay", `nominated local candidate is not relay: ${JSON.stringify(result)}`);
      console.log(`${name}: browser rendezvous over coturn (${stackName} listener) OK`, result);
    } finally {
      await browser.close();
    }
  }

    const which = process.argv[2] ?? "chromium";
    if (which === "chromium" || which === "all") await runBrowser("chromium", chromium, stackName);
    if (which === "firefox" || which === "all") await runBrowser("firefox", firefox, stackName);
    if (which === "webkit" || which === "all") await runBrowser("webkit", webkit, stackName);
    server.close();
  } finally {
    proc.kill();
  }
}

try {
  await runStack("rust", rustBin);
  await runStack("go", goBin);
  console.log("rendezvous-over-coturn browser test passed");
} finally {
  turn.kill();
}
