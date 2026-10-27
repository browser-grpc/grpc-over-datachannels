// Browser trickle ICE test: a real browser offers with every
// candidate stripped from the SDP; its candidates are then
// trickled from icecandidate events into the hand-rolled JS
// stack's addRemoteCandidate while connect() is already running,
// and the JS stack's candidates are trickled back through the
// browser's addIceCandidate. The echo channel can only open if
// trickle works in both directions against a production ICE
// agent (Chromium and Firefox).

import assert from "node:assert/strict";
import { join } from "node:path";
import { launchBrowser, newPage, runEngines, startStaticServer } from "./harness.mjs";

import { Peer } from "../webrtc/js/peer.js";

const { server, pageUrl } = await startStaticServer("browser-test/trickle_page.html");

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Remove candidates (and end-of-candidates) so the peers must
// rely on trickle alone.
const stripCandidates = (sdp) =>
  sdp
    .split(/\r?\n/)
    .filter((line) => !line.startsWith("a=candidate:") && line !== "a=end-of-candidates")
    .join("\r\n");

async function runBrowser(name) {
  // Default local IPs (loopback + interface addresses): Firefox
  // will not pair with a loopback-only remote candidate inside a
  // container, so advertise the interface address like the other
  // browser tests do.
  const peer = await Peer.create({});
    // Playwright's Firefox answers no mDNS queries for its obfuscated
  // .local candidates and will not initiate checks to same-IP pairs,
  // so legs where our stack must reach it need raw IP candidates.
  // Chromium needs no equivalent (it answers mDNS queries itself).
  const browser = await launchBrowser(name);
  try {
    const page = await newPage(browser, name);
    await page.goto(pageUrl);

    const offer = await page.evaluate(() => window.__start());
    const answer = peer.handleOffer(stripCandidates(offer));
    await page.evaluate((sdp) => window.__acceptAnswer(sdp), stripCandidates(answer));

    // Trickle the JS stack's candidates into the browser.
    for (const line of peer.localCandidateLines()) {
      await page.evaluate((candidateLine) => window.__addCandidate(candidateLine), line);
    }
    await page.evaluate(() => window.__addCandidate("a=end-of-candidates"));

    // Start connect() with zero browser candidates, then trickle
    // the browser's candidates in as its ICE agent produces them.
    let endpoint = null;
    let connectError = null;
    const connectPromise = peer.connect();
    connectPromise.then(
      (ep) => {
        endpoint = ep;
      },
      (err) => {
        connectError = err;
      },
    );
    let fed = 0;
    let added = 0;
    const deadline = Date.now() + 25000;
    while (!endpoint && !connectError && Date.now() < deadline) {
      const candidates = await page.evaluate(() => window.__candidates);
      while (fed < candidates.length) {
        if (peer.addRemoteCandidate(candidates[fed])) added += 1;
        fed += 1;
      }
      await sleep(50);
    }
    if (connectError) throw connectError;
    assert.ok(endpoint, `${name}: JS peer connect timed out`);
    assert.ok(added >= 1, `${name}: no browser candidate was trickled in`);

    endpoint.onchannel = (channel) => {
      channel.onmessage = (event) => {
        const data = Buffer.isBuffer(event.data) ? event.data : Buffer.from(event.data);
        channel.send(data);
      };
    };
    await page.evaluate(() => window.__channelOpen);
    await page.evaluate(() => window.__send("via-trickle"));
    let echoed = null;
    const echoDeadline = Date.now() + 20000;
    while (Date.now() < echoDeadline) {
      echoed = await page.evaluate(() => window.__echoed);
      if (echoed) break;
      await sleep(50);
    }
    assert.equal(echoed, "via-trickle");
    console.log(`${name}: browser <-> JS stack over trickled candidates only, echo OK`);
  } finally {
    await browser.close();
    await peer.close();
  }
}

try {
await runEngines(process.argv[2], runBrowser);
} finally {
  server.close();
}
console.log("browser trickle test passed");
