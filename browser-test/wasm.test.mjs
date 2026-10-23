// WASM browser test: a Chromium/Firefox page whose gRPC calls
// originate in Go/WASM (generated facade calling the JS grpc-dc
// implementation through the wasm bridge), over a native
// RTCDataChannel, against a gRPC server on the Node WebRTC stack.

import assert from "node:assert/strict";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium, firefox } from "playwright";

import { Peer } from "../webrtc/js/peer.js";
import { Server, StatusCode, StatusError } from "../js/index.js";
import { EchoResponse } from "../js/examples/echo_pb.js";
import { createEchoService } from "../js/examples/echo_grpc_dc.js";

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
    res.writeHead(200, { "content-type": MIME[extname(path)] ?? "application/octet-stream" });
    res.end(body);
  } catch {
    res.writeHead(404);
    res.end("not found");
  }
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const pageUrl = `http://127.0.0.1:${server.address().port}/browser-test/wasm_page.html`;

const handlers = {
  async unary(req, ctx) {
    if (req.message === "fail") {
      throw new StatusError(StatusCode.INVALID_ARGUMENT, "asked to fail");
    }
    if (req.delayMs > 0) await new Promise((resolve) => setTimeout(resolve, req.delayMs));
    const suffix = ctx.metadata["x-echo"] ? ` [${ctx.metadata["x-echo"]}]` : "";
    return new EchoResponse({ message: `echo: ${req.message}${suffix}`, index: 0 });
  },
  async *serverStream(req) {
    if (req.message === "fail") {
      throw new StatusError(StatusCode.INVALID_ARGUMENT, "asked to fail");
    }
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
      if (req.message === "fail") {
        throw new StatusError(StatusCode.INVALID_ARGUMENT, "asked to fail");
      }
      yield new EchoResponse({ message: req.message, index: index++ });
    }
  },
};

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

    const result = await page.evaluate(() => window.__runWasm());
    assert.deepEqual(result, {
      unary: "echo: hello",
      ticks: [0, 1, 2],
      joined: "a+b",
      echoed: ["x", "y"],
      unaryFailureCode: 3,
      metadataMessage: "echo: hello [meta]",
      serverStreamFailureCode: 3,
      bidiFailureCode: 3,
      unknownMethodCode: 12,
      cancelTerminated: true,
      deadlineCode: 4,
    });
    console.log(`${name}: Go/WASM gRPC client over native RTCDataChannel OK`, result);
  } finally {
    await browser.close();
    await answerer.close();
  }
}

const which = process.argv[2] ?? "chromium";
if (which === "chromium" || which === "all") await runBrowser("chromium", chromium);
if (which === "firefox" || which === "all") await runBrowser("firefox", firefox);

server.close();
console.log("wasm browser test passed");
