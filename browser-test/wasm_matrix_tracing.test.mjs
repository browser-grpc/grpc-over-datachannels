// Wasm matrix tracing: span parenting across the native/facade
// boundary. Pairs a client page of one runtime class with a
// server page of another (facade x facade, native x facade,
// facade x native) over the same Node byte relay as
// wasm_matrix.test.mjs, with a span recorder active on BOTH
// sides:
//   - facade pages record JS-runtime spans (?trace=1) — the JS
//     runtime owns the wire for facade calls;
//   - the Rust native pages use in-module recording entries
//     (echo_client_tracing / echo_server_tracing).
// Asserts every server span is parented to a client span in
// the same trace: traceparent propagation works no matter
// which side of the call is native Wasm and which is a facade
// over the JS bridge.

import assert from "node:assert/strict";
import { launchBrowser, runEngines, startStaticServer } from "./harness.mjs";

import { Peer } from "../webrtc/js/peer.js";

const { server, pageUrl } = await startStaticServer("browser-test", { isolated: true });
const baseUrl = pageUrl;

// clientSpans/serverSpans: where the driver reads spans from —
// "result" (in the run result), "window" (window.__spans), or
// "getter" (window.__tracingSpans()).
const PAIRS = [
  {
    clientLabel: "Zig facade client",
    clientPage: "wasm_zig_page.html?trace=1",
    serverLabel: "Swift facade server",
    serverPage: "wasm_swift_facade_server_page.html?trace=1",
    runClient: "__runWasm",
    runServer: "__runServer",
    clientSpans: "window",
    serverSpans: "window",
  },
  {
    clientLabel: "Rust native client",
    clientPage: "wasm_rust_page.html",
    serverLabel: "Swift facade server",
    serverPage: "wasm_swift_facade_server_page.html?trace=1",
    runClient: "__runWasmTracing",
    runServer: "__runServer",
    clientSpans: "result",
    serverSpans: "window",
    exactSingle: true,
  },
  {
    clientLabel: "Zig facade client",
    clientPage: "wasm_zig_page.html?trace=1",
    serverLabel: "Rust native server",
    serverPage: "wasm_rust_server_page.html",
    runClient: "__runWasm",
    runServer: "__runServerTracing",
    clientSpans: "window",
    serverSpans: "getter",
  },
  {
    clientLabel: "Zig native client",
    clientPage: "wasm_zig_native_page.html",
    serverLabel: "Rust native server",
    serverPage: "wasm_rust_server_page.html",
    runClient: "__runWasmTracing",
    runServer: "__runServerTracing",
    clientSpans: "result",
    serverSpans: "getter",
    exactSingle: true,
  },
  {
    clientLabel: "Rust native client",
    clientPage: "wasm_rust_page.html",
    serverLabel: "Zig native server",
    serverPage: "wasm_zig_native_server_page.html",
    runClient: "__runWasmTracing",
    runServer: "__runServerTracing",
    clientSpans: "result",
    serverSpans: "window",
    exactSingle: true,
  },
  {
    clientLabel: "Kotlin native client",
    clientPage: "wasm_kotlin_native_page.html",
    serverLabel: "Rust native server",
    serverPage: "wasm_rust_server_page.html",
    runClient: "__runWasmTracing",
    runServer: "__runServerTracing",
    clientSpans: "result",
    serverSpans: "getter",
    exactSingle: true,
  },
  {
    clientLabel: "Rust native client",
    clientPage: "wasm_rust_page.html",
    serverLabel: "Kotlin native server",
    serverPage: "wasm_kotlin_native_server_page.html",
    runClient: "__runWasmTracing",
    runServer: "__runServerTracing",
    clientSpans: "result",
    serverSpans: "window",
    exactSingle: true,
  },
  {
    clientLabel: "Swift native client",
    clientPage: "wasm_swift_native_page.html",
    serverLabel: "Rust native server",
    serverPage: "wasm_rust_server_page.html",
    runClient: "__runWasmTracing",
    runServer: "__runServerTracing",
    clientSpans: "result",
    serverSpans: "getter",
    exactSingle: true,
  },
  {
    clientLabel: "Rust native client",
    clientPage: "wasm_rust_page.html",
    serverLabel: "Swift native server",
    serverPage: "wasm_swift_native_server_page.html",
    runClient: "__runWasmTracing",
    runServer: "__runServerTracing",
    clientSpans: "result",
    serverSpans: "window",
    exactSingle: true,
  },
  {
    clientLabel: "C++ native client",
    clientPage: "wasm_cpp_native_page.html",
    serverLabel: "Rust native server",
    serverPage: "wasm_rust_server_page.html",
    runClient: "__runWasmTracing",
    runServer: "__runServerTracing",
    clientSpans: "result",
    serverSpans: "getter",
    exactSingle: true,
  },
  {
    clientLabel: "Rust native client",
    clientPage: "wasm_rust_page.html",
    serverLabel: "C++ native server",
    serverPage: "wasm_cpp_native_server_page.html",
    runClient: "__runWasmTracing",
    runServer: "__runServerTracing",
    clientSpans: "result",
    serverSpans: "window",
    exactSingle: true,
  },
  {
    clientLabel: "Lua native client",
    clientPage: "wasm_lua_page.html",
    serverLabel: "Rust native server",
    serverPage: "wasm_rust_server_page.html",
    runClient: "__runWasmTracing",
    runServer: "__runServerTracing",
    clientSpans: "result",
    serverSpans: "getter",
    exactSingle: true,
  },
  {
    clientLabel: "Rust native client",
    clientPage: "wasm_rust_page.html",
    serverLabel: "Lua native server",
    serverPage: "wasm_lua_server_page.html",
    runClient: "__runWasmTracing",
    runServer: "__runServerTracing",
    clientSpans: "result",
    serverSpans: "window",
    exactSingle: true,
  },
  {
    clientLabel: "Go facade client",
    clientPage: "wasm_page.html?trace=1",
    serverLabel: "Rust native server",
    serverPage: "wasm_rust_server_page.html",
    runClient: "__runWasm",
    runServer: "__runServerTracing",
    clientSpans: "window",
    serverSpans: "getter",
  },
  {
    clientLabel: "Kotlin facade client",
    clientPage: "wasm_kotlin_page.html?trace=1",
    serverLabel: "Rust native server",
    serverPage: "wasm_rust_server_page.html",
    runClient: "__runWasm",
    runServer: "__runServerTracing",
    clientSpans: "window",
    serverSpans: "getter",
  },
  {
    clientLabel: "C++ facade client",
    clientPage: "wasm_facade_page.html?wasm=/browser-test/echo_cpp.wasm&trace=1",
    serverLabel: "Rust native server",
    serverPage: "wasm_rust_server_page.html",
    runClient: "__runWasm",
    runServer: "__runServerTracing",
    clientSpans: "window",
    serverSpans: "getter",
  },
  {
    clientLabel: "Swift facade client",
    clientPage: "wasm_facade_page.html?wasm=/browser-test/echo_swift.wasm&trace=1",
    serverLabel: "Rust native server",
    serverPage: "wasm_rust_server_page.html",
    runClient: "__runWasm",
    runServer: "__runServerTracing",
    clientSpans: "window",
    serverSpans: "getter",
  },
  {
    clientLabel: "Scala.js facade client",
    clientPage: "wasm_scalajs_page.html?trace=1",
    serverLabel: "Rust native server",
    serverPage: "wasm_rust_server_page.html",
    runClient: "__runWasm",
    runServer: "__runServerTracing",
    clientSpans: "window",
    serverSpans: "getter",
  },
  {
    clientLabel: "Dart native client",
    clientPage: "dart_wasm_page.html",
    serverLabel: "Rust native server",
    serverPage: "wasm_rust_server_page.html",
    runClient: "__runWasmTracing",
    runServer: "__runServerTracing",
    clientSpans: "result",
    serverSpans: "getter",
    exactSingle: true,
  },
  {
    clientLabel: "Rust native client",
    clientPage: "wasm_rust_page.html",
    serverLabel: "Dart native server",
    serverPage: "dart_wasm_server_page.html",
    runClient: "__runWasmTracing",
    runServer: "__runServerTracing",
    clientSpans: "result",
    serverSpans: "window",
    exactSingle: true,
  },
  {
    clientLabel: "Zig facade client",
    clientPage: "wasm_zig_page.html?trace=1",
    serverLabel: "C++ facade server",
    serverPage: "wasm_cpp_facade_server_page.html?trace=1",
    runClient: "__runWasm",
    runServer: "__runServer",
    clientSpans: "window",
    serverSpans: "window",
  },
  {
    clientLabel: "C++ facade client",
    clientPage: "wasm_facade_page.html?wasm=/browser-test/echo_cpp.wasm&trace=1",
    serverLabel: "Zig facade server",
    serverPage: "wasm_zig_facade_server_page.html?trace=1",
    runClient: "__runWasm",
    runServer: "__runServer",
    clientSpans: "window",
    serverSpans: "window",
  },
];

function relay(from, to) {
  from.addEventListener("message", async (event) => {
    let data = event.data;
    if (typeof Blob !== "undefined" && data instanceof Blob) {
      data = await data.arrayBuffer();
    }
    if (data instanceof ArrayBuffer) data = new Uint8Array(data);
    if (to.readyState === "open") to.send(data);
  });
}

async function channelOf(peer) {
  const endpoint = await peer.connect();
  const dc = await new Promise((resolve) => { endpoint.onchannel = resolve; });
  if (dc.readyState !== "open") {
    await new Promise((resolve) => dc.addEventListener("open", resolve, { once: true }));
  }
  return dc;
}

// Rust spans arrive as [kind, traceId, spanId, parentSpanId, ""];
// JS spans as objects. Normalize both to objects.
function normalize(starts) {
  return (starts || []).map((s) => Array.isArray(s)
    ? { kind: s[0], traceId: s[1], spanId: s[2], parentSpanId: s[3] }
    : s);
}

async function readSpans(page, source, result) {
  if (source === "result") return result;
  if (source === "getter") return page.evaluate(() => window.__tracingSpans());
  return page.evaluate(() => window.__spans);
}

async function runPair(name, pair) {
  const browser = await launchBrowser(name, { extraArgs: ["--enable-features=SharedArrayBuffer"] });
  let clientPeer;
  let serverPeer;
  try {
    const clientPg = await browser.newPage();
    const serverPg = await browser.newPage();
    for (const [label, pg] of [["client", clientPg], ["server", serverPg]]) {
      pg.on("console", (msg) => console.log(`[${name} ${label} console] ${msg.text()}`));
      pg.on("pageerror", (err) => console.log(`[${name} ${label} pageerror] ${err.message}`));
    }
    await clientPg.goto(`${baseUrl}/${pair.clientPage}`);
    await serverPg.goto(`${baseUrl}/${pair.serverPage}`);
    await clientPg.waitForFunction(() => window.__offer, null, { timeout: 30000 });
    await serverPg.waitForFunction(() => window.__offer, null, { timeout: 30000 });

    clientPeer = await Peer.create({ chunkMessages: true });
    serverPeer = await Peer.create({ chunkMessages: true });
    const clientAnswer = clientPeer.handleOffer(await clientPg.evaluate(() => window.__offer));
    const serverAnswer = serverPeer.handleOffer(await serverPg.evaluate(() => window.__offer));
    await clientPg.evaluate((sdp) => window.__acceptAnswer(sdp), clientAnswer);
    await serverPg.evaluate((sdp) => window.__acceptAnswer(sdp), serverAnswer);

    const clientDc = await channelOf(clientPeer);
    const serverDc = await channelOf(serverPeer);
    relay(clientDc, serverDc);
    relay(serverDc, clientDc);

    await serverPg.evaluate((fn) => window[fn](), pair.runServer);
    // Per-pair deadline: a wedged pair must fail with its name
    // attached, not eat the whole suite's timeout (a hung
    // evaluate otherwise stalls every later pair).
    const result = await Promise.race([
      clientPg.evaluate((fn) => window[fn](), pair.runClient),
      new Promise((_, reject) =>
        setTimeout(
          () => reject(new Error(`pair timed out after 180s: ${pair.clientLabel} -> ${pair.serverLabel}`)),
          180000,
        ),
      ),
    ]);
    assert.equal(pair.exactSingle ? result.message : result.unary, "echo: hello");

    // Server span ends can land a tick after the client sees the
    // final response; give the server page a short settle window.
    await serverPg.waitForTimeout(250);

    const clientData = await readSpans(clientPg, pair.clientSpans, result);
    const serverData = await readSpans(serverPg, pair.serverSpans, result);
    const clientStarts = normalize(clientData.starts).filter((s) => s.kind === "client");
    // The Rust native client also pushes an untraced large
    // unary on the same endpoint (largeBytes below); its server
    // span belongs to another trace, so parenting assertions
    // only cover server spans in a client trace.
    const clientTraceIds = new Set(clientStarts.map((s) => s.traceId));
    const serverStarts = normalize(serverData.starts)
      .filter((s) => s.kind === "server")
      .filter((s) => clientTraceIds.has(s.traceId));
    assert.ok(clientStarts.length >= 1, `client spans: ${clientStarts.length}`);
    assert.ok(serverStarts.length >= 1, `server spans: ${serverStarts.length}`);
    if (pair.exactSingle) {
      assert.equal(clientStarts.length, 1);
      assert.equal(serverStarts.length, 1);
    }
    const bySpanId = new Map(clientStarts.map((s) => [s.spanId, s]));
    for (const srv of serverStarts) {
      const parent = bySpanId.get(srv.parentSpanId);
      assert.ok(parent, `server span ${srv.spanId} parent ${srv.parentSpanId} is a client span`);
      assert.equal(srv.traceId, parent.traceId, "server span shares client trace id");
    }
    assert.ok((serverData.ends || []).length >= 1, "server span ends recorded");
    console.log(
      `${name}: ${pair.clientLabel} -> ${pair.serverLabel} tracing OK ` +
      `(client spans ${clientStarts.length}, server spans ${serverStarts.length})`,
    );
    // Large-message leg: clients that report largeBytes pushed
    // a 512 KiB unary on the same endpoint (twice the browser's
    // 256 KiB single-message cap, via the DC chunk shim; the
    // multi-MB stall class must stay dead in browsers too).
    if (result.largeBytes !== undefined) {
      assert.equal(result.largeBytes, 512 * 1024 + 6, "512 KiB echo byte count");
      console.log(`${name}: ${pair.clientLabel} -> ${pair.serverLabel} large (512KiB) OK`);
    }
  } finally {
    await browser.close();
    if (clientPeer) await clientPeer.close();
    if (serverPeer) await serverPeer.close();
  }
}

const which = process.argv[2] ?? "chromium";
for (const pair of PAIRS) {
  await runEngines(which, (name) => runPair(name, pair), { webkitEnvGate: true });
}
console.log("wasm matrix tracing test passed");
server.close();
