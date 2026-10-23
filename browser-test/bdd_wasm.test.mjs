// Wasm BDD test: every generated/native Wasm Echo client page
// named in the generated manifest (browser-test/
// bdd_wasm_manifest.generated.mjs, stamped by racket/bdd-gen.rkt)
// runs against a gRPC server on the Node WebRTC stack, and its
// summary is asserted against expectations derived from the
// generated BDD scenario table (bdd_scenarios.generated.mjs) --
// unary echo, server-stream count, client-stream join, bidi
// order, and the deadline code for clients whose summary carries
// it. The full 16-scenario table runs in the JS browser client
// (bdd.test.mjs); Wasm client programs are fixed Echo programs,
// so this runner pins the scenarios they execute to the same
// generated table instead of restating literals per test file.

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
import { BDD_SCENARIOS } from "./bdd_scenarios.generated.mjs";
import { WASM_BDD_CLIENTS } from "./bdd_wasm_manifest.generated.mjs";

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
const baseUrl = `http://127.0.0.1:${server.address().port}/browser-test`;

// Canonical Echo semantics (racket/bdd-spec.rkt): "fail" is
// rejected in every method, delayMs delays unary, x-echo
// metadata is reflected in the unary reply.
const handlers = {
  async unary(req, ctx) {
    if (req.message === "fail") {
      throw new StatusError(StatusCode.INVALID_ARGUMENT, "asked to fail");
    }
    if (req.delayMs > 0) {
      await new Promise((r) => setTimeout(r, req.delayMs));
    }
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

const byName = Object.fromEntries(BDD_SCENARIOS.map((s) => [s.name, s]));

function expectedSummary(client) {
  const stream = byName["server-stream-count"];
  const ticks = client.tickStyle === "label"
    ? Array.from({ length: stream.expectNum }, (_, i) => `${stream.messages[0]}#${i}`)
    : Array.from({ length: stream.expectNum }, (_, i) => i);
  const expected = {
    unary: byName["unary-echo"].expectMessage,
    ticks,
    joined: client.joinedMessages.join("+"),
    echoed: byName["bidi-order"].messages,
  };
  if (client.deadline) {
    expected.deadlineCode = byName["deadline-exceeded"].expectStatus;
  }
  return expected;
}

async function runClient(name, engine, client) {
  const answerer = await Peer.create();
  const launchOptions = {
    args: ["--no-sandbox", "--disable-dev-shm-usage", "--enable-features=SharedArrayBuffer"],
  };
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
    page.on("console", (msg) => console.log(`[${name} ${client.label} console] ${msg.text()}`));
    page.on("pageerror", (err) => console.log(`[${name} ${client.label} pageerror] ${err.message}`));
    await page.goto(`${baseUrl}/${client.page}`);
    await page.waitForFunction(() => window.__offer || window.__wasmError, null, { timeout: 30000 });
    const wasmError = await page.evaluate(() => window.__wasmError ?? null);
    if (wasmError && client.allowWasmError) {
      console.log(`${name}: skipping ${client.label} (no WasmGC/js-string support): ${wasmError}`);
      return;
    }

    const offer = await page.evaluate(() => window.__offer);
    const answer = answerer.handleOffer(offer);
    await page.evaluate((sdp) => window.__acceptAnswer(sdp), answer);

    const endpoint = await answerer.connect();
    endpoint.onchannel = (channel) => grpcServer.serve(channel);

    const result = await page.evaluate((runName) => window[runName](), client.run);
    const expected = expectedSummary(client);
    assert.equal(result.unary, expected.unary, `${client.label}: unary`);
    assert.deepEqual(result.ticks, expected.ticks, `${client.label}: ticks`);
    assert.equal(result.joined, expected.joined, `${client.label}: joined`);
    assert.deepEqual(result.echoed, expected.echoed, `${client.label}: echoed`);
    if (client.deadline) {
      assert.equal(result.deadlineCode, expected.deadlineCode, `${client.label}: deadlineCode`);
    }
    if (client.deep) {
      // Scenarios executed inside the Wasm module itself
      // (failure, metadata, unknown method, cancellation).
      assert.equal(result.unaryFailureCode, byName["unary-failure"].expectStatus,
        `${client.label}: unaryFailureCode`);
      assert.equal(result.metadataMessage, byName["metadata-marker"].expectMessage,
        `${client.label}: metadataMessage`);
      assert.equal(result.serverStreamFailureCode, byName["server-stream-failure"].expectStatus,
        `${client.label}: serverStreamFailureCode`);
      assert.equal(result.bidiFailureCode, byName["bidi-failure"].expectStatus,
        `${client.label}: bidiFailureCode`);
      assert.equal(result.unknownMethodCode, byName["unknown-method"].expectStatus,
        `${client.label}: unknownMethodCode`);
      assert.equal(result.cancelTerminated, true, `${client.label}: cancelTerminated`);
      assert.equal(result.deadlineCode, byName["deadline-exceeded"].expectStatus,
        `${client.label}: deadlineCode (deep)`);
    }
    console.log(`${name}: ${client.label} BDD summary OK`, result);
  } finally {
    await browser.close();
    await answerer.close();
  }
}

const which = process.argv[2] ?? "chromium";
for (const client of WASM_BDD_CLIENTS) {
  if (which === "chromium" || which === "all") await runClient("chromium", chromium, client);
  if (which === "firefox" || which === "all") await runClient("firefox", firefox, client);
}

server.close();
console.log("wasm BDD test passed");
