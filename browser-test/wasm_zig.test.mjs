// WASM browser test: a Chromium/Firefox page whose gRPC calls
// originate in Zig/WASM (generated facade calling the JS grpc-dc
// implementation through the wasm bridge), over a native
// RTCDataChannel, against a gRPC server on the Node WebRTC stack.

import assert from "node:assert/strict";
import { join } from "node:path";
import { launchBrowser, newPage, runEngines, startStaticServer } from "./harness.mjs";

import { Peer } from "../webrtc/js/peer.js";
import { Server, StatusError } from "../js/index.js";
import { EchoResponse } from "../js/examples/echo_pb.js";
import { createEchoService } from "../js/examples/echo_grpc_dc.js";

const { server, pageUrl } = await startStaticServer("browser-test/wasm_zig_page.html");

// Canonical Echo semantics (the BDD specification): "fail" is
// rejected with INVALID_ARGUMENT in every method, delayMs
// delays unary, x-echo metadata is reflected as " [meta]".
const handlers = {
  async unary(req, ctx) {
    if (req.message === "fail") throw new StatusError(3, "fail requested");
    if (req.delayMs > 0) {
      await new Promise((resolve) => setTimeout(resolve, req.delayMs));
    }
    const md = ctx?.metadata;
    const echoMd = typeof md?.get === "function" ? md.get("x-echo") : md?.["x-echo"];
    const suffix = echoMd ? " [meta]" : "";
    return new EchoResponse({ message: `echo: ${req.message}${suffix}`, index: 0 });
  },
  async *serverStream(req) {
    if (req.message === "fail") throw new StatusError(3, "fail requested");
    for (let i = 0; i < Math.max(0, req.count); i++) {
      yield new EchoResponse({ message: req.message, index: i });
    }
  },
  async clientStream(requests) {
    const parts = [];
    for await (const req of requests) {
      if (req.message === "fail") throw new StatusError(3, "fail requested");
      parts.push(req.message);
    }
    return new EchoResponse({ message: parts.join("+"), index: parts.length });
  },
  async *bidi(requests) {
    let index = 0;
    for await (const req of requests) {
      if (req.message === "fail") throw new StatusError(3, "fail requested");
      yield new EchoResponse({ message: req.message, index: index++ });
    }
  },
};

async function runBrowser(name) {
  const answerer = await Peer.create() // all interface IPs: browsers may refuse loopback<->non-loopback pairs;
    // Playwright's Firefox answers no mDNS queries for its obfuscated
  // .local candidates and will not initiate checks to same-IP pairs,
  // so legs where our stack must reach it need raw IP candidates.
  // Chromium needs no equivalent (it answers mDNS queries itself).
  const browser = await launchBrowser(name);
  try {
    const grpcServer = new Server();
    grpcServer.addService(createEchoService(handlers));

    const page = await newPage(browser, name);
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
    console.log(`${name}: Zig/WASM gRPC client over native RTCDataChannel OK`, result);
  } finally {
    await browser.close();
    await answerer.close();
  }
}

await runEngines(process.argv[2], runBrowser, { webkitEnvGate: true });

server.close();
console.log("zig wasm browser test passed");
