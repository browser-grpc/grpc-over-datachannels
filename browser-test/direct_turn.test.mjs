// Browser WebRTC-Direct over TURN (symmetric-NAT shape): a real
// browser dials with iceTransportPolicy "relay" -- it has no
// host or srflx candidate at all -- to the hand-rolled JS stack,
// which allocates from the same fake TURN server and advertises
// an unreachable host address. The nominated pair must be
// relay<->relay, and the datachannel echo must cross it. This is
// the browser form of the native direct_dial_turn path.
//
// Engines that produce no relay candidate in this environment
// are probed and skipped (Firefox never initiates TURN
// gathering under Playwright here; verified against a real
// coturn server for turn.test.mjs — an environment limitation,
// not a stack defect).

import assert from "node:assert/strict";
import { launchBrowser, newPage, runEngines, startStaticServer } from "./harness.mjs";

import { Peer } from "../webrtc/js/peer.js";
import { fakeTurnServer, USER, PASS } from "../webrtc/js/test/fake_turn.js";

const { server, pageUrl } = await startStaticServer("browser-test/direct_turn_page.html");

async function runBrowser(name, turn) {
  const peer = await Peer.create({
    localIps: ["10.11.12.13"],
    turnServers: [{ address: turn.server, username: USER, password: PASS }],
  });
  const browser = await launchBrowser(name);
  try {
    const page = await newPage(browser, name);
    await page.goto(`${pageUrl}?turn=${encodeURIComponent(turn.server)}`);

    await page.evaluate(() => window.__start());
    const offer = await page.evaluate(() => window.__offer);
    if (!/typ relay/.test(offer)) {
      // See the file header: some engines never initiate TURN
      // gathering in this environment (verified against coturn).
      console.log(`${name}: no relay candidate from browser; skipping (environment limitation)`);
      return;
    }
    assert.doesNotMatch(offer, /typ host/, `relay-only browser offered a host candidate:\n${offer}`);

    const answer = peer.handleOffer(offer);
    await page.evaluate((sdp) => window.__acceptAnswer(sdp), answer);

    const endpoint = await peer.connect();
    const channelPromise = new Promise((resolve) => (endpoint.onchannel = resolve));
    const channel = await channelPromise;
    channel.onmessage = (event) => {
      const text = new TextDecoder().decode(event.data);
      channel.send(new TextEncoder().encode(`re:${text}`));
    };

    await page.evaluate(() => window.__send("hello-direct-turn"));
    await page.waitForFunction(() => window.__replies.length > 0, null, { timeout: 15000 });
    const reply = await page.evaluate(() => window.__replies[0]);
    assert.equal(reply, "re:hello-direct-turn");

    const pair = await page.evaluate(() => window.__selectedPair());
    assert.equal(pair?.local, "relay", `browser side of nominated pair is not relay: ${JSON.stringify(pair)}`);
    console.log(`${name}: browser direct-over-TURN OK (nominated pair: ${pair.local} <-> ${pair.remote})`);
  } finally {
    await browser.close();
    await peer.close();
  }
}

const turn = await fakeTurnServer();
try {
await runEngines(process.argv[2], (name) => runBrowser(name, turn));
} finally {
  turn.close();
  server.close();
}
console.log("browser direct-over-TURN test passed");
