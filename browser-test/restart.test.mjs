// Browser-initiated ICE restart: a real Chromium/Firefox
// RTCPeerConnection restarts ICE (createOffer({iceRestart}))
// mid-session against the reimplemented Node WebRTC stack's
// handleRestartOffer. The same grpc-dc client/channel must
// keep working, the ufrag must rotate, and the Node peer must
// observe renomination.

import assert from "node:assert/strict";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium, firefox, webkit } from "playwright";

import { Peer } from "../webrtc/js/peer.js";
import { parse } from "../webrtc/js/sdp.js";
import { Server } from "../js/index.js";
import { EchoResponse } from "../js/examples/echo_pb.js";
import { createEchoService } from "../js/examples/echo_grpc_dc.js";

const ROOT = fileURLToPath(new URL("..", import.meta.url));
const MIME = { ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript" };

const server = createServer(async (req, res) => {
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
const pageUrl = `http://127.0.0.1:${server.address().port}/browser-test/restart_page.html`;

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

async function runBrowser(name, engine) {
  const answerer = await Peer.create();
  let renominatedResolve;
  const renominated = new Promise((resolve) => { renominatedResolve = resolve; });
  answerer.onRenominated = () => renominatedResolve();
    // Playwright's Firefox answers no mDNS queries for its obfuscated
  // .local candidates and will not initiate checks to same-IP pairs,
  // so legs where our stack must reach it need raw IP candidates.
  // Chromium needs no equivalent (it answers mDNS queries itself).
  const launchOptions = { args: ["--no-sandbox", "--disable-dev-shm-usage"] };
  if (name === "firefox") {
    launchOptions.firefoxUserPrefs = {
      "media.peerconnection.ice.obfuscate_host_addresses": false,
    };
  }
  if (name === "webkit") delete launchOptions.args; // Chromium-only flags; MiniBrowser rejects them
  const browser = await engine.launch(launchOptions);
  try {
    const grpcServer = new Server();
    grpcServer.addService(createEchoService(handlers));

    const page = await browser.newPage();
    page.on("console", (msg) => console.log(`[${name} console] ${msg.text()}`));
    page.on("pageerror", (err) => console.log(`[${name} pageerror] ${err.message}`));
    await page.goto(pageUrl);
    await page.waitForFunction(() => window.__offer, null, { timeout: 30000 });

    const offer = await page.evaluate(() => window.__offer);
    const answer = answerer.handleOffer(offer);
    await page.evaluate((sdp) => window.__acceptAnswer(sdp), answer);

    const endpoint = await answerer.connect();
    endpoint.onchannel = (channel) => grpcServer.serve(channel);

    const before = await page.evaluate(() => window.__unary("before"));
    assert.equal(before, "echo: before");

    const restartOffer = await page.evaluate(() => window.__restartOffer());
    assert.notEqual(parse(restartOffer).ufrag, parse(offer).ufrag, "ufrag must rotate");
    const restartAnswer = answerer.handleRestartOffer(restartOffer);
    assert.notEqual(parse(restartAnswer).ufrag, parse(answer).ufrag, "answer ufrag must rotate");
    await page.evaluate((sdp) => window.__acceptAnswer(sdp), restartAnswer);

    await Promise.race([
      renominated,
      new Promise((_, reject) => setTimeout(() => reject(new Error("renomination timed out")), 20000)),
    ]);
    await page.waitForFunction(
      () => ["connected", "completed"].includes(window.__iceState()),
      null,
      { timeout: 20000 },
    );

    const after = await page.evaluate(() => window.__unary("after"));
    assert.equal(after, "echo: after");
    console.log(`${name}: browser ICE restart against Node stack OK`);
  } finally {
    await browser.close();
    await answerer.close();
  }
}

const which = process.argv[2] ?? "chromium";
if (which === "chromium" || which === "all") await runBrowser("chromium", chromium);
if (which === "firefox" || which === "all") await runBrowser("firefox", firefox);
if (which === "webkit" || which === "all") await runBrowser("webkit", webkit);

server.close();
console.log("browser restart test passed");
