#!/usr/bin/env node
// QUICKSTART step 2 runner: browser gRPC client -> native
// (reimplemented Node WebRTC stack) Echo server, end to end.
//
// This is the runnable form of "browser -> native server":
//   1. starts the native stack peer (answerer) + grpc-dc Server,
//   2. serves the repo over HTTP and opens grpc_page.html in a
//      real browser (Chromium by default; firefox/webkit args
//      accepted),
//   3. exchanges SDP through the page globals (the same minimal
//      signaling a copy-paste app would do over any channel),
//   4. asserts the unary and streaming replies.
//
// Run: node browser-test/native_step2.mjs [chromium|firefox|webkit]
// The production shape replaces steps 2-3's file/page signaling
// with your own (WebSocket, fetch, QR code — SDP is just text).

import assert from "node:assert/strict";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium, firefox, webkit } from "playwright";

import { Peer } from "../webrtc/js/peer.js";
import { Server } from "../js/index.js";
import { EchoResponse } from "../js/examples/echo_pb.js";
import { createEchoService } from "../js/examples/echo_grpc_dc.js";

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

const engines = { chromium, firefox, webkit };
const name = process.argv[2] ?? "chromium";
const engine = engines[name];
if (!engine) {
  console.error(`usage: node browser-test/native_step2.mjs [${Object.keys(engines).join("|")}]`);
  process.exit(2);
}

const httpServer = createServer(async (req, res) => {
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
await new Promise((resolve) => httpServer.listen(0, "127.0.0.1", resolve));

const answerer = await Peer.create();
const grpcServer = new Server();
grpcServer.addService(createEchoService(handlers));

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
  page.on("pageerror", (err) => console.log(`[${name} pageerror] ${err.message}`));
  await page.goto(
    `http://127.0.0.1:${httpServer.address().port}/browser-test/grpc_page.html`);
  await page.waitForFunction(() => window.__offer, null, { timeout: 30000 });

  // Signaling: SDP offer/answer as plain text (see header).
  const offer = await page.evaluate(() => window.__offer);
  const answer = answerer.handleOffer(offer);
  await page.evaluate((sdp) => window.__acceptAnswer(sdp), answer);

  const endpoint = await answerer.connect();
  endpoint.onchannel = (channel) => grpcServer.serve(channel);

  const result = await page.evaluate(() => window.__runGrpc());
  assert.equal(result.unary, "echo: hello");
  assert.deepEqual(result.ticks, [0, 1, 2]);
  assert.deepEqual(result.echoed, ["x", "y"]);
  console.log(`step2 (${name}): browser gRPC client -> native stack server OK`, result);
} finally {
  await browser.close();
  await answerer.close();
  httpServer.close();
}
