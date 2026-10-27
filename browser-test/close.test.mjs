// Browser channel-close test: the JS stack closes one channel
// (the browser must observe onclose via SCTP stream reset), then
// the browser closes another (the JS stack must observe it).
// This exercises RFC 6525 RE-CONFIG against production browser
// SCTP in both directions (Chromium and Firefox).

import assert from "node:assert/strict";
import { launchBrowser, newPage, runEngines, startStaticServer } from "./harness.mjs";

import { Peer } from "../webrtc/js/peer.js";

const { server, pageUrl } = await startStaticServer("browser-test/close_page.html");

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function waitFor(fn, timeoutMs = 20000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const value = await fn();
    if (value) return value;
    await sleep(50);
  }
  return null;
}

async function runBrowser(name) {
  const peer = await Peer.create({});
    // Playwright's Firefox answers no mDNS queries for its obfuscated
  // .local candidates and will not initiate checks to same-IP pairs,
  // so legs where our stack must reach it need raw IP candidates.
  // Chromium needs no equivalent (it answers mDNS queries itself).
  const browser = await launchBrowser(name);
  try {
    const page = await newPage(browser, name);
    await page.goto(pageUrl);

    const offer = peer.createOffer();
    const answer = await page.evaluate((sdp) => window.__acceptOffer(sdp), offer);
    peer.handleAnswer(answer);
    const endpoint = await peer.connect();

    // Channel one: closed by the JS side.
    const ch1 = endpoint.openChannel({ label: "one" });
    let localClosed = false;
    ch1.onclose = () => {
      localClosed = true;
    };
    // Make sure the browser has the channel before closing it.
    assert.ok(
      await waitFor(async () => (await page.evaluate(() => window.__channelState("one"))) === "open"),
      `${name}: browser never opened channel one`,
    );
    ch1.close();
    assert.ok(await waitFor(() => localClosed), `${name}: JS side close never completed`);
    const browserClosed = await waitFor(() => page.evaluate(() => window.__closed));
    assert.deepEqual(browserClosed, ["one"], `${name}: browser did not observe close of one`);
    assert.equal(ch1.readyState, "closed");

    // Channel two: closed by the browser.
    const ch2 = endpoint.openChannel({ label: "two" });
    let jsSawClose = false;
    ch2.onclose = () => {
      jsSawClose = true;
    };
    assert.ok(
      await waitFor(async () => (await page.evaluate(() => window.__channelState("two"))) === "open"),
      `${name}: browser never opened channel two`,
    );
    await page.evaluate(() => window.__closeChannel("two"));
    assert.ok(await waitFor(() => jsSawClose), `${name}: JS side never observed browser close`);
    assert.equal(ch2.readyState, "closed");
    console.log(`${name}: channel close via stream reset OK in both directions`);
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
console.log("browser close test passed");
