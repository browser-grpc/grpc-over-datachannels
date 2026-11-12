// Real-browser test: HTTP/POST signaling end to end. A
// Chromium/Firefox page uses the generated httpSignalingChannel
// (single non-trickle POST to /grpc-dc/signal on the same
// origin) to reach a generated Echo server on the Node WebRTC
// stack, mounted via the generated signalingHandler. No test
// harness touches SDP here: the POST is the only signaling.

import assert from "node:assert/strict";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium, firefox, webkit } from "playwright";

import { Server } from "../js/index.js";
import { EchoResponse } from "../js/examples/echo_pb.js";
import { createEchoService } from "../js/examples/echo_grpc_dc.js";
import { signalingHandler } from "../js/src/signaling_server.js";

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
const signal = signalingHandler(grpcServer);

const server = createServer(async (req, res) => {
  if (await signal(req, res)) return;
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
const pageUrl = `http://127.0.0.1:${server.address().port}/browser-test/signaling_page.html`;

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
    const result = await page.evaluate(() => window.__runSignaling());
    assert.equal(result.unary, "echo: hello");
    assert.deepEqual(result.ticks, [0, 1, 2]);
    console.log(`${name}: browser gRPC via HTTP/POST signaling OK`, result);

    await page.goto(pageUrl.replace("signaling_page.html", "signaling_trickle_page.html"));
    const trickle = await page.evaluate(() => window.__runTrickle());
    assert.ok(trickle.session, "session id present");
    assert.equal(trickle.before, "echo: before");
    assert.equal(trickle.after, "echo: after");
    console.log(`${name}: browser trickle + restart via signaling OK`, trickle);
  } finally {
    await browser.close();
  }
}

const which = process.argv[2] ?? "chromium";
if (which === "chromium" || which === "all") await runBrowser("chromium", chromium);
if (which === "firefox" || which === "all") await runBrowser("firefox", firefox);
if (which === "webkit" || which === "all") await runBrowser("webkit", webkit);

await signal.closePeers();
server.close();
console.log("signaling browser test passed");
