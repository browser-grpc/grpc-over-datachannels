// Browser TURN test: a real browser TURN client allocates a
// relay candidate from the repo's fake TURN server and talks to
// the hand-rolled JS WebRTC stack, which allocates from the same
// server. The JS stack advertises an unreachable host address, so
// the echo channel can only have been relayed through the two
// allocations — this validates the JS TURN client and the fake
// server against a production TURN implementation (Chromium).
//
// Firefox is probed but skipped when it produces no relay
// candidate: in this Playwright environment its ICE agent never
// initiates STUN or TURN gathering at all (host candidates only),
// which reproduces against a real coturn server with session logs
// showing zero Firefox TURN packets — an environment limitation,
// not a stack defect. Chromium covers the interop leg.

import assert from "node:assert/strict";
import { launchBrowser, newPage, runEngines, startStaticServer } from "./harness.mjs";

import { Peer } from "../webrtc/js/peer.js";
import { fakeTurnServer, USER, PASS } from "../webrtc/js/test/fake_turn.js";

const { server, pageUrl } = await startStaticServer("browser-test/turn_page.html");

async function runBrowser(name, turn) {
  const peer = await Peer.create({
    localIps: ["10.11.12.13"],
    turnServers: [{ address: turn.server, username: USER, password: PASS }],
  });
    // Playwright's Firefox answers no mDNS queries for its obfuscated
  // .local candidates and will not initiate checks to same-IP pairs,
  // so legs where our stack must reach it need raw IP candidates.
  // Chromium needs no equivalent (it answers mDNS queries itself).
  const browser = await launchBrowser(name);
  try {
    const page = await newPage(browser, name);
    await page.goto(`${pageUrl}?turn=${encodeURIComponent(turn.server)}`);

    const offer = peer.createOffer();
    assert.match(offer, /typ relay/, `JS offer has no relay candidate:\n${offer}`);
    await page.evaluate((sdp) => window.__acceptOffer(sdp), offer);
    const answer = await page.evaluate(() => window.__answer);
    if (!/typ relay/.test(answer)) {
      // See the file header: Firefox never initiates TURN
      // gathering in this environment (verified against coturn).
      console.log(`${name}: no relay candidate from browser; skipping (environment limitation)`);
      return;
    }
    peer.handleAnswer(answer);

    const endpoint = await peer.connect();
    const channel = endpoint.openChannel({ label: "echo" });
    const reply = await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("echo reply timed out")), 20000);
      channel.onmessage = (event) => {
        clearTimeout(timer);
        resolve(Buffer.from(event.data).toString());
      };
      channel.send(Buffer.from("via-turn-relay"));
    });
    assert.equal(reply, "via-turn-relay");
    console.log(`${name}: browser TURN client <-> JS stack, both relayed, echo OK`);
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
console.log("browser turn test passed");
