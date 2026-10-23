// DTLS-server test: each hand-rolled WebRTC stack (Go, JS, Rust)
// accepts the DTLS handshake from a real browser acting as DTLS
// client — the browser answers the native offer with setup=active.
// This is the inverse of every other browser test, where the native
// stacks are DTLS clients. It covers the fix for coalesced browser
// flights: browsers pack Certificate/ClientKeyExchange/
// CertificateVerify/CCS/Finished into one datagram, and the record
// parsers must feed the epoch-0 records before the epoch-1 tail can
// be decrypted instead of discarding the datagram whole.
//
// Go and JS legs run the full generated gRPC client against the
// browser's JS server (grpc_server_page.html); the Rust leg drives
// the webrtc/rust peer_echo example against an echo page.

import assert from "node:assert/strict";
import { spawn, execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, existsSync, writeFileSync, renameSync } from "node:fs";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium, firefox, webkit } from "playwright";

import { Peer } from "../webrtc/js/peer.js";
import { Channel } from "../js/index.js";
import { EchoRequest } from "../js/examples/echo_pb.js";
import { EchoClient } from "../js/examples/echo_grpc_dc.js";

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
const base = `http://127.0.0.1:${server.address().port}/browser-test`;
const grpcPageUrl = `${base}/grpc_server_page.html`;
const echoPageUrl = `${base}/dtls_echo_page.html`;

const dir = mkdtempSync(join(tmpdir(), "grpc-dtls-server-"));
const goHarness = join(dir, "grpc_webrtc_client");
execFileSync("go", ["build", "-o", goHarness, "./cmd/grpc_webrtc_client"], {
  cwd: join(ROOT, "go"),
  stdio: "inherit",
});
const rustEcho = join(ROOT, "webrtc/rust/target/debug/examples/peer_echo");

async function waitForFile(path, timeoutMs = 30000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (existsSync(path)) {
      const content = readFileSync(path, "utf8");
      if (content.trim()) return content;
    }
    await new Promise((r) => setTimeout(r, 50));
  }
  throw new Error(`timed out waiting for ${path}`);
}

async function newPage(browser, url) {
  const page = await browser.newPage();
  page.on("console", (msg) => console.log(`[console] ${msg.text()}`));
  page.on("pageerror", (err) => console.log(`[pageerror] ${err.message}`));
  await page.goto(url);
  return page;
}

async function answerOffer(page, offer) {
  await page.evaluate((sdp) => window.__acceptOffer(sdp), offer);
  const answer = await page.evaluate(() => window.__answer);
  assert.match(answer, /^a=setup:active$/m, "browser must take the DTLS client role");
  return answer;
}

async function runGoLeg(name, browser) {
  const signalBase = join(dir, `signal-${name}-go`);
  let stderrText = "";
  const proc = spawn(goHarness, [signalBase, "dtls-server"], { stdio: ["ignore", "pipe", "pipe"] });
  proc.stderr.on("data", (chunk) => {
    stderrText += chunk;
    process.stderr.write(`[${name} go harness] ${chunk}`);
  });
  const exited = new Promise((resolve) => proc.on("close", resolve));
  try {
    const page = await newPage(browser, grpcPageUrl);
    const offer = await waitForFile(`${signalBase}.offer`);
    const answer = await answerOffer(page, offer);
    writeFileSync(`${signalBase}.answer.tmp`, answer);
    renameSync(`${signalBase}.answer.tmp`, `${signalBase}.answer`);
    const code = await Promise.race([
      exited,
      new Promise((_, reject) => setTimeout(() => reject(new Error("client harness timed out")), 60000)),
    ]);
    assert.equal(code, 0, `client harness exit ${code}:\n${stderrText}`);
    assert.match(stderrText, /unary=echo: hello/);
    assert.match(stderrText, /server_stream=tick#0,tick#1,tick#2/);
    assert.match(stderrText, /client_stream=a\+b\+c/);
    assert.match(stderrText, /bidi=x,y/);
    const served = await page.evaluate(() => window.__servedChannels);
    assert.equal(served, 1, "browser should have served exactly one channel");
    console.log(`${name}: Go stack as DTLS server, browser DTLS client, gRPC OK`);
  } finally {
    proc.kill();
  }
}

async function runJsLeg(name, browser) {
  const peer = await Peer.create();
  try {
    const page = await newPage(browser, grpcPageUrl);
    const answer = await answerOffer(page, peer.createOffer());
    peer.handleAnswer(answer);
    const endpoint = await peer.connect();
    const client = new EchoClient(new Channel(endpoint.openChannel({ label: "grpc" })));

    const unary = await client.unary(new EchoRequest({ message: "hello" }));
    assert.equal(unary.message, "echo: hello");
    const ticks = [];
    for await (const resp of await client.serverStream(new EchoRequest({ message: "tick", count: 3 }))) {
      ticks.push(`${resp.message}#${resp.index}`);
    }
    assert.deepEqual(ticks, ["tick#0", "tick#1", "tick#2"]);
    const joined = await client.clientStream(["a", "b", "c"].map((message) => new EchoRequest({ message })));
    assert.equal(joined.message, "a+b+c");
    const echoed = [];
    for await (const resp of await client.bidi(["x", "y"].map((message) => new EchoRequest({ message })))) {
      echoed.push(resp.message);
    }
    assert.deepEqual(echoed, ["x", "y"]);
    console.log(`${name}: JS stack as DTLS server, browser DTLS client, gRPC OK`);
  } finally {
    await peer.close();
  }
}

async function runRustLeg(name, browser) {
  const offerPath = join(dir, `rs-${name}.offer`);
  const answerPath = join(dir, `rs-${name}.answer`);
  const proc = spawn(rustEcho, ["offerer", offerPath, answerPath, "all-ips"], { stdio: ["pipe", "pipe", "pipe"] });
  let stdoutText = "";
  let stderrText = "";
  proc.stdout.on("data", (chunk) => { stdoutText += chunk; });
  proc.stderr.on("data", (chunk) => {
    stderrText += chunk;
    process.stderr.write(`[${name} rust harness] ${chunk}`);
  });
  const exited = new Promise((resolve) => proc.on("close", resolve));
  try {
    const page = await newPage(browser, echoPageUrl);
    const offer = await waitForFile(offerPath);
    const answer = await answerOffer(page, offer);
    writeFileSync(`${answerPath}.tmp`, answer);
    renameSync(`${answerPath}.tmp`, answerPath);
    const deadline = Date.now() + 30000;
    while (!stderrText.includes("CONNECTED")) {
      if (Date.now() > deadline) throw new Error(`rust harness did not connect:\n${stderrText}`);
      await new Promise((r) => setTimeout(r, 50));
    }
    proc.stdin.write("hello dtls server\n");
    while (!stdoutText.includes("hello dtls server")) {
      if (Date.now() > deadline) throw new Error(`no echo reply; stdout=${stdoutText} stderr=${stderrText}`);
      await new Promise((r) => setTimeout(r, 50));
    }
    console.log(`${name}: Rust stack as DTLS server, browser DTLS client, channel echo OK`);
  } finally {
    proc.kill();
    await exited.catch(() => {});
  }
}

async function runBrowser(name, engine) {
    // Playwright's Firefox answers no mDNS queries for its obfuscated
  // .local candidates and will not initiate checks to same-IP pairs,
  // so legs where our stack must reach it need raw IP candidates.
  // Chromium needs no equivalent (it answers mDNS queries itself).
  const launchOptions = { args: ["--no-sandbox", "--disable-dev-shm-usage", "--disable-features=WebRtcHideLocalIpsWithMdns"] };
  if (name === "firefox") {
    launchOptions.firefoxUserPrefs = {
      "media.peerconnection.ice.obfuscate_host_addresses": false,
    };
  }
  if (name === "webkit") delete launchOptions.args; // Chromium-only flags; MiniBrowser rejects them
  const browser = await engine.launch(launchOptions);
  try {
    await runGoLeg(name, browser);
    await runJsLeg(name, browser);
    await runRustLeg(name, browser);
  } finally {
    await browser.close();
  }
}

const which = process.argv[2] ?? "chromium";
if (which === "chromium" || which === "all") await runBrowser("chromium", chromium);
if (which === "firefox" || which === "all") await runBrowser("firefox", firefox);
if (which === "webkit" || which === "all") await runBrowser("webkit", webkit);

server.close();
console.log("dtls server test passed");
