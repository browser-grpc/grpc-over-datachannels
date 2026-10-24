// WASM browser test: a Chromium/Firefox page whose gRPC calls
// originate in Zig/WASM running the real generated runtime
// (grpcdc endpoint in inline pump mode, in a Web Worker over
// a SharedArrayBuffer mailbox), over a native RTCDataChannel,
// against a gRPC server on the Node WebRTC stack.

import assert from "node:assert/strict";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium, firefox, webkit } from "playwright";

import { Peer } from "../webrtc/js/peer.js";
import { Server } from "../js/index.js";
import { EchoRequest } from "../js/examples/echo_pb.js";
import { EchoClient } from "../js/examples/echo_grpc_dc.js";
import { Channel } from "../js/index.js";
import { assertEchoDeepBehavior } from "./echo_deep_checks.mjs";

const ROOT = fileURLToPath(new URL("..", import.meta.url));
const MIME = {
  ".html": "text/html",
  ".js": "text/javascript",
  ".mjs": "text/javascript",
  ".wasm": "application/wasm",
};

const server = createServer(async (req, res) => {
  try {
    const path = normalize(join(ROOT, decodeURIComponent(new URL(req.url, "http://x").pathname)));
    if (!path.startsWith(ROOT)) throw new Error("outside root");
    const body = await readFile(path);
    res.writeHead(200, {
      "content-type": MIME[extname(path)] ?? "application/octet-stream",
      // SharedArrayBuffer (worker mailbox) needs cross-origin isolation.
      "cross-origin-opener-policy": "same-origin",
      "cross-origin-embedder-policy": "require-corp",
    });
    res.end(body);
  } catch {
    res.writeHead(404);
    res.end("not found");
  }
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const pageUrl = `http://127.0.0.1:${server.address().port}/browser-test/wasm_zig_facade_server_page.html`;

async function runBrowser(name, engine) {
  const answerer = await Peer.create() // all interface IPs: browsers may refuse loopback<->non-loopback pairs;
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
    const page = await browser.newPage();
    page.on("console", (msg) => console.log(`[${name} console] ${msg.text()}`));
    page.on("pageerror", (err) => console.log(`[${name} pageerror] ${err.message}`));
    await page.goto(pageUrl);
    await page.waitForFunction(() => window.__offer, null, { timeout: 30000 });

    const offer = await page.evaluate(() => window.__offer);
    const answer = answerer.handleOffer(offer);
    await page.evaluate((sdp) => window.__acceptAnswer(sdp), answer);

    const endpoint = await answerer.connect();
    const dc = await new Promise((resolve) => { endpoint.onchannel = resolve; });
    if (dc.readyState !== "open") {
      await new Promise((resolve) => dc.addEventListener("open", resolve, { once: true }));
    }
    await page.evaluate(() => window.__runServer());

    const channel = new Channel(dc);
    const client = new EchoClient(channel);
    const req = (message, count = 0, delayMs = 0) => new EchoRequest({ message, count, delayMs });

    const unary = await client.unary(req("hello"));
    assert.equal(unary.message, "echo: hello");

    const ticks = [];
    for await (const resp of await client.serverStream(req("tick", 3))) ticks.push(resp.index);
    assert.deepEqual(ticks, [0, 1, 2]);

    async function* ab() { yield req("a"); yield req("b"); }
    const joined = await client.clientStream(ab());
    assert.equal(joined.message, "a+b");

    async function* xy() { yield req("x"); yield req("y"); }
    const echoed = [];
    for await (const resp of await client.bidi(xy())) echoed.push(resp.message);
    assert.deepEqual(echoed, ["x", "y"]);

    let deadlineCode = 0;
    try {
      await client.unary(req("slow", 0, 400), { timeout: 50 });
    } catch (e) {
      deadlineCode = e.code;
    }
    assert.equal(deadlineCode, 4);

    await assertEchoDeepBehavior(client, channel);

    const result = { unary: unary.message, ticks, joined: joined.message, echoed, deadlineCode };
    console.log(`${name}: Zig/WASM facade gRPC server over native RTCDataChannel OK`, result);
  } finally {
    await browser.close();
    await answerer.close();
  }
}

const which = process.argv[2] ?? "chromium";
if (which === "chromium" || which === "all") await runBrowser("chromium", chromium);
if (which === "firefox" || which === "all") await runBrowser("firefox", firefox);
if (which === "webkit" || (which === "all" && process.env.GRPC_DC_WEBKIT)) await runBrowser("webkit", webkit);

server.close();
console.log("zig wasm facade server browser test passed");
