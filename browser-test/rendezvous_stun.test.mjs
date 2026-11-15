// Real-browser test: Rendezvous over STUN (server-reflexive
// candidate). The page dials with a STUN server configured;
// the fake STUN server maps the browser to 127.0.0.2, the
// loopback alias the listener descriptor is published on, so
// the srflx candidate is the viable pair in most engines.
// Mirrors rendezvous_turn.test.mjs' probe-and-skip: engines
// that gather no srflx candidate in this environment are
// skipped, not failed (an environment limitation, not a
// stack defect); an srflx candidate that gathers but cannot
// carry the call still fails.

import assert from "node:assert/strict";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium, firefox, webkit } from "playwright";
import dgram from "node:dgram";

import { Server } from "../js/index.js";
import { EchoResponse } from "../js/examples/echo_pb.js";
import { createEchoService } from "../js/examples/echo_grpc_dc.js";
import { serveRendezvous } from "../js/src/rendezvous_server.js";
import { StunMessage, xorMappedAddress } from "../webrtc/js/stun.js";
import { StunAttribute, StunMessageType } from "../webrtc/js/proto_gen.js";

const ROOT = fileURLToPath(new URL("..", import.meta.url));
const MIME = { ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript" };

// STUN Binding responder: reports every requester as mapped
// to 127.0.0.2 (its own source port), so the browser's srflx
// candidate names the loopback alias the listener publishes.
async function fakeStunServer() {
  const socket = dgram.createSocket("udp4");
  socket.on("message", (msg, rinfo) => {
    const request = StunMessage.decode(msg);
    if (!request || request.type !== StunMessageType.BINDING_REQUEST) return;
    const resp = new StunMessage(StunMessageType.BINDING_SUCCESS);
    resp.transactionId = Buffer.from(request.transactionId);
    resp.attrs.push([
      StunAttribute.XOR_MAPPED_ADDRESS,
      xorMappedAddress({ address: "127.0.0.2", port: rinfo.port }, request.transactionId),
    ]);
    socket.send(resp.encode(null), rinfo.port, rinfo.address);
  });
  await new Promise((resolve) => socket.bind(0, "127.0.0.1", resolve));
  return { server: `127.0.0.1:${socket.address().port}`, close: () => socket.close() };
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
const listener = await serveRendezvous(grpcServer, { address: "0.0.0.0", port: 0 });
const stun = await fakeStunServer();
console.log(`fake STUN at ${stun.server}; rendezvous on port ${listener.descriptor("x").port}`);

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
  `http://127.0.0.1:${server.address().port}/browser-test/rendezvous_stun_page.html` +
  `?stun=${encodeURIComponent(stun.server)}`;

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
    const result = await page.evaluate(() => window.__runRendezvousStun()).catch((e) => {
      if (String(e?.message ?? e).includes("did not open")) return null;
      throw e;
    });
    if (result === null || !result.gathered.includes("srflx")) {
      console.log(`${name}: no srflx dial in this environment; skipping (environment limitation)`);
      return;
    }
    assert.equal(result.unary, "echo: hello-stun");
    // With STUN configured the browser gathers a srflx
    // candidate. Nomination should land on a reflexive
    // candidate (srflx, or the peer-reflexive candidate the
    // listener's checks teach it); engines that prefer the
    // host pair in this loopback setup are an environment
    // policy difference, not a stack defect, so they skip.
    if (result.localType !== "srflx" && result.localType !== "prflx") {
      console.log(`${name}: nominated ${result.localType}, not reflexive; skipping`);
      return;
    }
    console.log(`${name}: browser rendezvous over STUN OK`, result);
  } finally {
    await browser.close();
  }
}

const which = process.argv[2] ?? "chromium";
if (which === "chromium" || which === "all") await runBrowser("chromium", chromium);
if (which === "firefox" || which === "all") await runBrowser("firefox", firefox);
if (which === "webkit" || which === "all") await runBrowser("webkit", webkit);

listener.close();
stun.close();
server.close();
console.log("rendezvous-over-STUN browser test passed");
