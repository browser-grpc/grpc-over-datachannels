// Real-browser test: HTTP signaling and Rendezvous sharing
// ONE UDP socket. A PeerMux hosts the signaling sessions
// (signalingHandler with options.mux) and a RendezvousListener
// attaches to the same mux as its unhandled-packet fallback.
// The page first calls via httpSignalingChannel (POST), then
// via rendezvousChannel (descriptor) — both land on the mux
// port, asserted identical — proving one process needs a
// single UDP port for both browser shapes.

import assert from "node:assert/strict";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { networkInterfaces } from "node:os";
import { extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium, firefox, webkit } from "playwright";

import { Server } from "../js/index.js";
import { EchoResponse } from "../js/examples/echo_pb.js";
import { createEchoService } from "../js/examples/echo_grpc_dc.js";
import { signalingHandler } from "../js/src/signaling_server.js";
import { serveRendezvous } from "../js/src/rendezvous_server.js";
import { PeerMux } from "../webrtc/js/mux.js";

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

const mux = await PeerMux.bind({ address: "0.0.0.0", port: 0 });
const signal = signalingHandler(grpcServer, { mux });
const listener = await serveRendezvous(grpcServer, { mux });
const muxPort = mux.address().port;
const descriptor = listener.descriptor(
  Object.values(networkInterfaces())
    .flat()
    .find((n) => n && n.family === "IPv4" && !n.internal)?.address ?? "127.0.0.1",
);
assert.equal(descriptor.port, muxPort, "rendezvous descriptor must carry the mux port");
console.log(`shared UDP port ${muxPort} for signaling + rendezvous`);

const server = createServer(async (req, res) => {
  if (await signal(req, res)) return;
  if (req.url === "/rendezvous.json") {
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
const base = `http://127.0.0.1:${server.address().port}/browser-test`;

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
    await page.goto(`${base}/signaling_page.html`);
    const viaSignaling = await page.evaluate(() => window.__runSignaling());
    assert.equal(viaSignaling.unary, "echo: hello");
    console.log(`${name}: signaling over shared mux socket OK`, viaSignaling);

    await page.goto(`${base}/rendezvous_page.html`);
    const viaRendezvous = await page.evaluate(() => window.__runRendezvous());
    assert.equal(viaRendezvous.first.unary, "echo: hello-first");
    assert.equal(viaRendezvous.second.unary, "echo: hello-second");
    console.log(`${name}: rendezvous over shared mux socket OK`, viaRendezvous);
  } finally {
    await browser.close();
  }
}

const which = process.argv[2] ?? "chromium";
if (which === "chromium" || which === "all") await runBrowser("chromium", chromium);
if (which === "firefox" || which === "all") await runBrowser("firefox", firefox);
if (which === "webkit" || which === "all") await runBrowser("webkit", webkit);

listener.close();
await signal.closePeers();
mux.close();
server.close();
console.log("rendezvous+mux shared-socket browser test passed");
