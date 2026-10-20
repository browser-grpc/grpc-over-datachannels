// Browser WebRTC-Direct over TURN (symmetric-NAT shape): a real
// Chromium dials with iceTransportPolicy "relay" -- it has no
// host or srflx candidate at all -- to the hand-rolled JS stack,
// which allocates from the same fake TURN server and advertises
// an unreachable host address. The nominated pair must be
// relay<->relay, and the datachannel echo must cross it. This is
// the browser form of the native direct_dial_turn path.

import assert from "node:assert/strict";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";

import { Peer } from "../webrtc/js/peer.js";
import { fakeTurnServer, USER, PASS } from "../webrtc/js/test/fake_turn.js";

const ROOT = fileURLToPath(new URL("..", import.meta.url));
const MIME = { ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript" };

const server = createServer(async (req, res) => {
  try {
    const path = normalize(join(ROOT, decodeURIComponent(new URL(req.url, "http://x").pathname)));
    if (!path.startsWith(ROOT)) throw new Error("outside root");
    const body = await readFile(path);
    res.writeHead(200, { "content-type": MIME[extname(path)] ?? "application/octet-stream" });
    res.end(body);
  } catch {
    res.writeHead(404);
    res.end("not found");
  }
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));

const turn = await fakeTurnServer();
const peer = await Peer.create({
  localIps: ["10.11.12.13"],
  turnServers: [{ address: turn.server, username: USER, password: PASS }],
});

const browser = await chromium.launch({ args: ["--no-sandbox", "--disable-dev-shm-usage"] });
try {
  const page = await browser.newPage();
  page.on("console", (msg) => console.log(`[chromium console] ${msg.text()}`));
  page.on("pageerror", (err) => console.log(`[chromium pageerror] ${err.message}`));
  await page.goto(
    `http://127.0.0.1:${server.address().port}/browser-test/direct_turn_page.html?turn=${encodeURIComponent(turn.server)}`,
  );

  await page.evaluate(() => window.__start());
  const offer = await page.evaluate(() => window.__offer);
  assert.match(offer, /typ relay/, `browser offer has no relay candidate:\n${offer}`);
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
  console.log(`browser direct-over-TURN OK (nominated pair: ${pair.local} <-> ${pair.remote})`);
} finally {
  await browser.close();
  await peer.close();
  turn.close();
  server.close();
}
