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

const { server, pageUrl } = await startStaticServer("browser-test/wasm_kotlin_stream_server_page.html", { isolated: true });

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

    async function* abc() { yield req("a"); yield req("b"); yield req("c"); }
    const joined = await client.clientStream(abc());
    assert.equal(joined.message, "a+b+c");

    // Ping-pong proof of incrementality: the first response
    // must arrive while the request generator is still parked
    // before its second yield. A collect-up-front server would
    // deadlock here (the test timeout would fire instead).
    let release;
    const gate = new Promise((resolve) => { release = resolve; });
    async function* xy() {
      yield req("x");
      await gate;
      yield req("y");
    }
    const responses = (await client.bidi(xy()))[Symbol.asyncIterator]();
    const first = await responses.next();
    assert.equal(first.done, false);
    assert.equal(first.value.message, "x");
    release();
    const second = await responses.next();
    assert.equal(second.value.message, "y");
    const end = await responses.next();
    assert.equal(end.done, true);

    // Canonical failure semantics: a "fail" request ends the
    // incremental calls with INVALID_ARGUMENT (3).
    async function* failReqs() { yield req("a"); yield req("fail"); }
    const clientStreamCode = await client.clientStream(failReqs()).then(
      () => 0,
      (err) => err.code,
    );
    assert.equal(clientStreamCode, 3);
    const bidiCode = await (async () => {
      try {
        for await (const _ of await client.bidi(failReqs())) { /* drain */ }
        return 0;
      } catch (err) {
        return err.code;
      }
    })();
    assert.equal(bidiCode, 3);

    console.log(`${name}: Kotlin/WASM incremental facade gRPC server over native RTCDataChannel OK`, {
      joined: joined.message,
      pingPong: [first.value.message, second.value.message],
    });
  } finally {
    await browser.close();
    await answerer.close();
  }
}

await runEngines(process.argv[2], runBrowser, { webkitEnvGate: true });

server.close();
console.log("kotlin wasm stream server browser test passed");
