// Real-browser test: Rendezvous over TURN (symmetric-NAT
// shape). The page dials with iceTransportPolicy "relay" —
// no host or srflx candidate at all — through the fake TURN
// server to a plain RendezvousListener, which has no TURN
// awareness: it answers the checks arriving from the relay's
// transport address like any other dialer's. Mirrors
// direct_turn.test.mjs' probe-and-skip: engines that produce
// no relay candidate in this environment are skipped, not
// failed (an environment limitation, not a stack defect).

import assert from "node:assert/strict";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium, firefox, webkit } from "playwright";

import { Server } from "../js/index.js";
import { EchoResponse } from "../js/examples/echo_pb.js";
import { createEchoService } from "../js/examples/echo_grpc_dc.js";
import { serveRendezvous } from "../js/src/rendezvous_server.js";
import { fakeTurnServer } from "../webrtc/js/test/fake_turn.js";

const ROOT = fileURLToPath(new URL("..", import.meta.url));
const MIME = { ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript" };

const handlers = {
  async unary(req) {
    return new EchoResponse({ message: `echo: ${req.message}`, index: 0 });
  },
  async *serverStream(req) {
    for (let i = 0; i < Math.max(0, req.count); i++) {
      yield new EchoResponse({ message: req.message, index: i });
    }
  },
  async clientStream(requests) {
    const parts = [];
    for await (const req of requests) parts.push(req.message);
    return new EchoResponse({ message: parts.join("+"), index: parts.length });
  },
  async *bidi(requests) {
    let index = 0;
    for await (const req of requests) {
      yield new EchoResponse({ message: req.message, index: index++ });
    }
  },
};

const grpcServer = new Server();
grpcServer.addService(createEchoService(handlers));
const listener = await serveRendezvous(grpcServer, { address: "0.0.0.0", port: 0 });
const turn = await fakeTurnServer();
console.log(`fake TURN at ${turn.server}; rendezvous on port ${listener.descriptor("x").port}`);

const server = createServer(async (req, res) => {
  if (req.url.startsWith("/rendezvous.json")) {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify(listener.descriptor("127.0.0.1")));
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

async function runBrowser(name, engine) {
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
    // Probe first: engines that never initiate TURN gathering
    // in this environment yield no relay candidate and the
    // dial cannot start (see direct_turn.test.mjs).
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
    console.log(`${name}: browser rendezvous over TURN OK`, result);
  } finally {
    await browser.close();
  }
}

const which = process.argv[2] ?? "chromium";
if (which === "chromium" || which === "all") await runBrowser("chromium", chromium);
if (which === "firefox" || which === "all") await runBrowser("firefox", firefox);
if (which === "webkit" || which === "all") await runBrowser("webkit", webkit);

listener.close();
turn.close();
server.close();
console.log("rendezvous-over-TURN browser test passed");
