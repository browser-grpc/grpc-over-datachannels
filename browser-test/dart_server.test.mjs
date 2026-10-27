// WASM browser test: a Chromium/Firefox page whose gRPC calls
// originate in Zig/WASM running the real generated runtime
// (grpcdc endpoint in inline pump mode, in a Web Worker over
// a SharedArrayBuffer mailbox), over a native RTCDataChannel,
// against a gRPC server on the Node WebRTC stack.

import assert from "node:assert/strict";
import { launchBrowser, newPage, runEngines, startStaticServer } from "./harness.mjs";

import { Peer } from "../webrtc/js/peer.js";
import { Server } from "../js/index.js";
import { EchoRequest } from "../js/examples/echo_pb.js";
import { EchoClient } from "../js/examples/echo_grpc_dc.js";
import { Channel } from "../js/index.js";

const { server, pageUrl } = await startStaticServer("browser-test/dart_server_page.html", { isolated: true });

async function runBrowser(name) {
  const answerer = await Peer.create() // all interface IPs: browsers may refuse loopback<->non-loopback pairs;
    // Playwright's Firefox answers no mDNS queries for its obfuscated
  // .local candidates and will not initiate checks to same-IP pairs,
  // so legs where our stack must reach it need raw IP candidates.
  // Chromium needs no equivalent (it answers mDNS queries itself).
  const browser = await launchBrowser(name);
  try {
    const page = await newPage(browser, name);
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

    const client = new EchoClient(new Channel(dc));
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

    const result = { unary: unary.message, ticks, joined: joined.message, echoed, deadlineCode };
    console.log(`${name}: Dart native gRPC server over native RTCDataChannel OK`, result);
  } finally {
    await browser.close();
    await answerer.close();
  }
}

await runEngines(process.argv[2], runBrowser, { webkitEnvGate: true });

server.close();
console.log("dart wasm server browser test passed");
