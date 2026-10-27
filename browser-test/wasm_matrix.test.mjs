// Browser client x server matrix (subset): pairs a native
// WASM client page of one runtime with a native WASM server
// page of another, in the same browser. Both pages are WebRTC
// offerers, so Node answers both offers on the pure-JS WebRTC
// stack and relays DataChannel bytes between the two channels
// untouched — the gRPC endpoints under test are the two
// browser runtimes, not Node. The per-runtime pages and their
// summaries come from the existing native browser tests; the
// canonical Echo semantics ("echo: hello", ticks, joins,
// deadline code 4) are shared by both roles.

import assert from "node:assert/strict";
import { chromium } from "playwright";
import { launchBrowser, newPage, runEngines, startStaticServer } from "./harness.mjs";

import { Peer } from "../webrtc/js/peer.js";

const { server, pageUrl } = await startStaticServer("browser-test", { isolated: true });
const baseUrl = pageUrl;

// Fifth element: whether the client page's summary carries the
// slow-call deadline check (native clients do; facade client
// pages do not run a slow call in their summary).
const PAIRS = [
  ["Kotlin native client", "wasm_kotlin_native_page.html", "Zig native server", "wasm_zig_native_server_page.html", true],
  ["Swift native client", "wasm_swift_native_page.html", "Kotlin native server", "wasm_kotlin_native_server_page.html", true],
  ["C++ native client", "wasm_cpp_native_page.html", "Swift native server", "wasm_swift_native_server_page.html", true],
  ["Zig native client", "wasm_zig_native_page.html", "C++ native server", "wasm_cpp_native_server_page.html", true],
  ["Go facade client", "wasm_page.html", "Kotlin native server", "wasm_kotlin_native_server_page.html", false],
  ["Kotlin facade client", "wasm_kotlin_page.html", "C++ native server", "wasm_cpp_native_server_page.html", false],
  ["Zig facade client", "wasm_zig_page.html", "Swift facade server", "wasm_swift_facade_server_page.html", false],
  ["C++ facade client", "wasm_facade_page.html?wasm=/browser-test/echo_cpp.wasm", "Go facade server", "wasm_go_facade_server_page.html", false],
  ["Swift facade client", "wasm_facade_page.html?wasm=/browser-test/echo_swift.wasm", "Kotlin facade server", "wasm_kotlin_facade_server_page.html", false],
  ["Scala.js facade client", "wasm_scalajs_page.html", "Kotlin native server", "wasm_kotlin_native_server_page.html", false],
  ["Zig native client", "wasm_zig_native_page.html", "Scala.js facade server", "wasm_scalajs_facade_server_page.html", true],
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

async function runPair(name, [clientLabel, clientPage, serverLabel, serverPage, expectDeadline]) {
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
    await clientPg.goto(`${baseUrl}/${clientPage}`);
    await serverPg.goto(`${baseUrl}/${serverPage}`);
    await clientPg.waitForFunction(() => window.__offer, null, { timeout: 30000 });
    await serverPg.waitForFunction(() => window.__offer, null, { timeout: 30000 });

    clientPeer = await Peer.create();
    serverPeer = await Peer.create();
    const clientAnswer = clientPeer.handleOffer(await clientPg.evaluate(() => window.__offer));
    const serverAnswer = serverPeer.handleOffer(await serverPg.evaluate(() => window.__offer));
    await clientPg.evaluate((sdp) => window.__acceptAnswer(sdp), clientAnswer);
    await serverPg.evaluate((sdp) => window.__acceptAnswer(sdp), serverAnswer);

    const clientDc = await channelOf(clientPeer);
    const serverDc = await channelOf(serverPeer);
    relay(clientDc, serverDc);
    relay(serverDc, clientDc);

    await serverPg.evaluate(() => window.__runServer());
    const result = await clientPg.evaluate(() => window.__runWasm());

    assert.equal(result.unary, "echo: hello");
    assert.deepEqual(result.ticks, [0, 1, 2]);
    assert.equal(result.joined, "a+b");
    assert.deepEqual(result.echoed, ["x", "y"]);
    if (expectDeadline) assert.equal(result.deadlineCode, 4);
    // Deep summaries (every Wasm client since the BDD
    // deepening) also assert the failure/metadata/unknown/
    // cancel/deadline codes against this pair's server, so a
    // server that ends failed streams with OK trailers fails
    // here instead of passing silently.
    if (result.unaryFailureCode !== undefined) {
      assert.equal(result.unaryFailureCode, 3);
      assert.equal(result.metadataMessage, "echo: hello [meta]");
      assert.equal(result.serverStreamFailureCode, 3);
      assert.equal(result.bidiFailureCode, 3);
      assert.equal(result.unknownMethodCode, 12);
      assert.equal(result.cancelTerminated, true);
      assert.equal(result.deadlineCode, 4);
    }
    console.log(`${name}: ${clientLabel} -> ${serverLabel} OK`, result);
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
console.log("wasm browser matrix test passed");
server.close();
