// Dart/Wasm browser test: a Chromium/Firefox page whose gRPC
// calls originate in the Dart grpc_dc runtime compiled to
// WasmGC with `dart compile wasm` (real Dart codec/endpoint/
// stub — not a facade over the JS implementation, unlike
// wasm/go), over a native RTCDataChannel, against a gRPC
// server on the Node WebRTC stack. Mirrors dart.test.mjs (the
// `dart compile js` leg); the artifact is built by
// `make test-dart-wasm-browser`. Browsers without WasmGC +
// js-string builtins are probe-and-skipped via __wasmError.

import assert from "node:assert/strict";
import { join } from "node:path";
import { launchBrowser, newPage, runEngines, startStaticServer } from "./harness.mjs";

import { Peer } from "../webrtc/js/peer.js";
import { Server, StatusCode, StatusError } from "../js/index.js";
import { EchoResponse } from "../js/examples/echo_pb.js";
import { createEchoService } from "../js/examples/echo_grpc_dc.js";

const { server, pageUrl } = await startStaticServer("browser-test/dart_wasm_page.html");

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

async function runBrowser(name) {
  const answerer = await Peer.create();
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
    await page.waitForFunction(() => window.__offer || window.__wasmError, null, { timeout: 30000 });
    const wasmError = await page.evaluate(() => window.__wasmError ?? null);
    if (wasmError) {
      console.log(`${name}: skipping Dart/Wasm (no WasmGC/js-string support): ${wasmError}`);
      return;
    }

    const offer = await page.evaluate(() => window.__offer);
    const answer = answerer.handleOffer(offer);
    await page.evaluate((sdp) => window.__acceptAnswer(sdp), answer);

    const endpoint = await answerer.connect();
    endpoint.onchannel = (channel) => grpcServer.serve(channel);

    const result = await page.evaluate(() => window.__runDart());
    assert.deepEqual(result, {
      unary: "echo: hello",
      ticks: ["tick#0", "tick#1", "tick#2"],
      joined: "a+b+c",
      echoed: ["x", "y"],
      unaryFailureCode: 3,
      metadataMessage: "echo: hello [meta]",
      serverStreamFailureCode: 3,
      bidiFailureCode: 3,
      unknownMethodCode: 12,
      cancelTerminated: true,
      deadlineCode: 4,
    });
    console.log(`${name}: Dart (dart compile wasm) gRPC client over native RTCDataChannel OK`, result);
  } finally {
    await browser.close();
    await answerer.close();
  }
}

await runEngines(process.argv[2], runBrowser, { webkitEnvGate: true });

server.close();
console.log("dart wasm browser test passed");
