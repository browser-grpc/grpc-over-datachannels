// Real-browser test: Rendezvous end to end. A
// Chromium/Firefox/WebKit page dials a pre-published fixed
// WebRTC endpoint (descriptor JSON) with the generated
// rendezvousChannel — no signaling exchange at all — and runs
// gRPC against a generated Echo server behind the JS stack's
// RendezvousListener (one UDP socket, fixed ICE credentials
// and DTLS certificate, sessions demuxed by browser ufrag).

import assert from "node:assert/strict";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium, firefox, webkit } from "playwright";

import { networkInterfaces } from "node:os";

import { Server } from "../js/index.js";
import { EchoResponse } from "../js/examples/echo_pb.js";
import { createEchoService } from "../js/examples/echo_grpc_dc.js";
import { serveRendezvous } from "../js/src/rendezvous_server.js";

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

// Publish the outward IPv4 (as a real deployment publishes its
// public address): Firefox will not pair a non-loopback local
// candidate with a loopback remote candidate.
const hostIp = Object.values(networkInterfaces())
  .flat()
  .find((n) => n && n.family === "IPv4" && !n.internal)?.address ?? "127.0.0.1";

const server = createServer(async (req, res) => {
  if (req.url === "/rendezvous.json") {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify(listener.descriptor(hostIp)));
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
const pageUrl = `http://127.0.0.1:${server.address().port}/browser-test/rendezvous_page.html`;
console.log("rendezvous descriptor:", listener.descriptor(hostIp));

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
    const result = await page.evaluate(() => window.__runRendezvous());
    assert.equal(result.first.unary, "echo: hello-first");
    assert.deepEqual(result.first.ticks, [0, 1, 2]);
    assert.equal(result.second.unary, "echo: hello-second");
    assert.deepEqual(result.second.ticks, [0, 1, 2]);
    console.log(`${name}: browser gRPC via rendezvous OK`, result);

    const stress = await page.evaluate(() => window.__runRendezvousStress(8));
    assert.deepEqual(
      stress,
      Array.from({ length: 8 }, (_, i) => `echo: stress-${i}`),
    );
    console.log(`${name}: browser rendezvous stress (8 concurrent dials) OK`);
  } finally {
    await browser.close();
  }
}

const which = process.argv[2] ?? "chromium";
if (which === "chromium" || which === "all") await runBrowser("chromium", chromium);
if (which === "firefox" || which === "all") await runBrowser("firefox", firefox);
if (which === "webkit" || which === "all") await runBrowser("webkit", webkit);

listener.close();
server.close();
console.log("rendezvous browser test passed");
