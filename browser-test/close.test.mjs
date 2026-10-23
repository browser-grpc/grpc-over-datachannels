// Browser channel-close test: the JS stack closes one channel
// (the browser must observe onclose via SCTP stream reset), then
// the browser closes another (the JS stack must observe it).
// This exercises RFC 6525 RE-CONFIG against production browser
// SCTP in both directions (Chromium and Firefox).

import assert from "node:assert/strict";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium, firefox } from "playwright";

import { Peer } from "../webrtc/js/peer.js";

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

async function runBrowser(name, engine) {
  const peer = await Peer.create({});
    // Playwright's Firefox answers no mDNS queries for its obfuscated
  // .local candidates and will not initiate checks to same-IP pairs,
  // so legs where our stack must reach it need raw IP candidates.
  // Chromium needs no equivalent (it answers mDNS queries itself).
  const launchOptions = { args: ["--no-sandbox", "--disable-dev-shm-usage"] };
  if (name === "firefox") {
    launchOptions.firefoxUserPrefs = {
      "media.peerconnection.ice.obfuscate_host_addresses": false,
    };
  }
  const browser = await engine.launch(launchOptions);
  try {
    const pageUrl = `http://127.0.0.1:${server.address().port}/browser-test/close_page.html`;
    const page = await browser.newPage();
    page.on("console", (msg) => console.log(`[${name} console] ${msg.text()}`));
    page.on("pageerror", (err) => console.log(`[${name} pageerror] ${err.message}`));
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
  const which = process.argv[2] ?? "chromium";
  if (which === "chromium" || which === "all") await runBrowser("chromium", chromium);
  if (which === "firefox" || which === "all") await runBrowser("firefox", firefox);
} finally {
  server.close();
}
console.log("browser close test passed");
