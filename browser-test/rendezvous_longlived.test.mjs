// Real-browser test: a Rendezvous session outlives the
// server's consent-expiry window. The JS listener is configured
// with a 10 s consent expiry (default 30 s); the page dials,
// calls, waits 16 s, and calls again on the same channel.
// The dialer's ICE password is never learned by the server,
// so its own consent checks can never be answered — the
// session survives only because an integrity-valid Binding
// request from the nominated pair itself refreshes
// server-side consent freshness (RFC 7675).

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
const listener = await serveRendezvous(grpcServer, {
  address: "0.0.0.0",
  port: 0,
  consentIntervalMs: 1000,
  consentExpiryMs: 10000,
});

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
    const result = await page.evaluate(() => window.__runRendezvousLongLived(16000));
    assert.equal(result.before, "echo: before");
    assert.equal(result.after, "echo: after");
    console.log(`${name}: rendezvous session alive past consent window OK`, result);
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
console.log("rendezvous long-lived browser test passed");
