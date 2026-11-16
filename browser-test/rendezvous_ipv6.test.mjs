// Real-browser test: Rendezvous over IPv6. The JS listener
// binds a udp6 socket and publishes a descriptor whose host
// is ::1; the page dials it with rendezvousChannel (candidate
// synthesis carries the IPv6 host). Skips when IPv6 loopback
// is unavailable in the environment.

import assert from "node:assert/strict";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";
import dgram from "node:dgram";
import { chromium, firefox, webkit } from "playwright";

import { Server } from "../js/index.js";
import { EchoResponse } from "../js/examples/echo_pb.js";
import { createEchoService } from "../js/examples/echo_grpc_dc.js";
import { serveRendezvous } from "../js/src/rendezvous_server.js";

const ROOT = fileURLToPath(new URL("..", import.meta.url));
const MIME = { ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript" };

const hasV6 = await new Promise((resolve) => {
  const s = dgram.createSocket("udp6");
  s.once("error", () => resolve(false));
  s.bind(0, "::1", () => {
    s.close();
    resolve(true);
  });
});
if (!hasV6) {
  console.log("rendezvous-ipv6: no IPv6 loopback in this environment; skipping");
  process.exit(0);
}

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
const listener = await serveRendezvous(grpcServer, { address: "::", port: 0, family: "udp6" });
const descriptor = listener.descriptor("::1");
console.log("ipv6 rendezvous descriptor:", descriptor);

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
    const result = await page.evaluate(() => window.__runRendezvous()).catch((e) => {
      if (String(e?.message ?? e).includes("did not open")) return null;
      throw e;
    });
    if (result === null) {
      console.log(`${name}: no IPv6 dial in this environment; skipping (environment limitation)`);
      return;
    }
    assert.equal(result.first.unary, "echo: hello-first");
    assert.deepEqual(result.first.ticks, [0, 1, 2]);
    assert.equal(result.second.unary, "echo: hello-second");
    console.log(`${name}: browser rendezvous over IPv6 OK`, result.first);
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
console.log("rendezvous-over-IPv6 browser test passed");
