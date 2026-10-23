// Generic WASM facade browser test: a Chromium/Firefox page
// whose gRPC calls originate in a WASM facade client (the
// page named on the command line) over a native
// RTCDataChannel, against a gRPC server on the Node WebRTC
// stack. All facades run the same four Echo shapes and
// report the same JSON shape, so one runner covers each
// language (C++, Swift, Kotlin, ...).
//
// Usage: node wasm_facade.test.mjs <label> <page> [chromium|firefox|all]
//   <page> is repo-relative under browser-test/, may carry a
//   query string (e.g. wasm_facade_page.html?wasm=/browser-test/echo_cpp.wasm).

import assert from "node:assert/strict";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium, firefox, webkit } from "playwright";

import { Peer } from "../webrtc/js/peer.js";
import { Server, StatusCode, StatusError } from "../js/index.js";
import { EchoResponse } from "../js/examples/echo_pb.js";
import { createEchoService } from "../js/examples/echo_grpc_dc.js";

const label = process.argv[2] ?? "WASM facade";
const pagePath = process.argv[3] ?? "wasm_facade_page.html";
const which = process.argv[4] ?? "all";

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
const pageUrl = `http://127.0.0.1:${server.address().port}/browser-test/${pagePath}`;

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
  const answerer = await Peer.create();
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

    const result = await page.evaluate(() => window.__runWasm());
    assert.equal(result.unary, "echo: hello");
    assert.deepEqual(result.ticks, [0, 1, 2]);
    assert.equal(result.joined, "a+b");
    assert.deepEqual(result.echoed, ["x", "y"]);
    // Facades that execute the deep BDD scenarios in-module
    // report these fields; assert them when present.
    if ("unaryFailureCode" in result) {
      assert.equal(result.unaryFailureCode, 3);
      assert.equal(result.metadataMessage, "echo: hello [meta]");
      assert.equal(result.serverStreamFailureCode, 3);
      assert.equal(result.bidiFailureCode, 3);
      assert.equal(result.unknownMethodCode, 12);
      assert.equal(result.cancelTerminated, true);
      assert.equal(result.deadlineCode, 4);
    }
    console.log(`${name}: ${label} gRPC client over native RTCDataChannel OK`, result);
  } finally {
    await browser.close();
    await answerer.close();
  }
}

if (which === "chromium" || which === "all") await runBrowser("chromium", chromium);
if (which === "firefox" || which === "all") await runBrowser("firefox", firefox);
if (which === "webkit" || (which === "all" && process.env.GRPC_DC_WEBKIT)) await runBrowser("webkit", webkit);

server.close();
console.log(`${label} wasm browser test passed`);
