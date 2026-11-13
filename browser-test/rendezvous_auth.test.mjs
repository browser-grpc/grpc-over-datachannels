// Real-browser test: rendezvous auth. The Node server serves
// Echo through serveRendezvous with options.auth (HMAC bearer
// tokens, see js/src/rendezvous.js); the page dials with the
// token (accepted, claims on ctx.claims server-side) and
// without it (UNAUTHENTICATED). Modeled on
// rendezvous_turn.test.mjs.

import assert from "node:assert/strict";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { extname, join, normalize } from "node:path";
import { networkInterfaces } from "node:os";
import { fileURLToPath } from "node:url";
import { chromium, firefox, webkit } from "playwright";

import { Server, StatusCode, issueRendezvousToken } from "../js/index.js";
import { EchoResponse } from "../js/examples/echo_pb.js";
import { createEchoService } from "../js/examples/echo_grpc_dc.js";
import { serveRendezvous } from "../js/src/rendezvous_server.js";

const ROOT = fileURLToPath(new URL("..", import.meta.url));
const MIME = { ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript" };
const SECRET = "rendezvous-auth-test-secret";

let seenSub = null;
const handlers = {
  async unary(req, ctx) {
    seenSub = ctx.claims?.sub ?? null;
    return new EchoResponse({ message: `echo: ${req.message}`, index: 0 });
  },
  async *serverStream(req) {
    for (let i = 0; i < Math.max(0, req.count); i++) {
      yield new EchoResponse({ message: req.message, index: i });
    }
  },
  async clientStream(requests) {
    const parts = [];
    for await (const req of requests) parts.push(req.message);
    return new EchoResponse({ message: parts.join("+"), index: parts.length });
  },
  async *bidi(requests) {
    let index = 0;
    for await (const req of requests) {
      yield new EchoResponse({ message: req.message, index: index++ });
    }
  },
};

const token = await issueRendezvousToken(SECRET, {
  sub: "alice",
  iss: "issuer",
  aud: "rendezvous",
  exp: 4102444800,
  scopes: ["read"],
  jti: "browser-1",
});

const grpcServer = new Server();
grpcServer.addService(createEchoService(handlers));
const listener = await serveRendezvous(grpcServer, {
  address: "0.0.0.0",
  port: 0,
  auth: {
    secret: SECRET,
    issuer: "issuer",
    audience: "rendezvous",
    scopes: { "/echo.Echo/Unary": ["read"] },
  },
});
console.log(`rendezvous auth on port ${listener.descriptor("x").port}`);

// Firefox will not pair a non-loopback local candidate with a
// loopback remote candidate, so publish the outward address
// (same convention as rendezvous.test.mjs).
const hostIp =
  Object.values(networkInterfaces())
    .flat()
    .find((n) => n && n.family === "IPv4" && !n.internal)?.address ?? "127.0.0.1";

const server = createServer(async (req, res) => {
  if (req.url.startsWith("/rendezvous.json")) {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify(listener.descriptor(hostIp)));
    return;
  }
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
const pageUrl =
  `http://127.0.0.1:${server.address().port}/browser-test/rendezvous_auth_page.html` +
  `?token=${encodeURIComponent(token)}`;

async function runBrowser(name, engine) {
  const launchOptions = { args: ["--no-sandbox", "--disable-dev-shm-usage"] };
  if (name === "firefox") {
    launchOptions.firefoxUserPrefs = {
      "media.peerconnection.ice.obfuscate_host_addresses": false,
    };
  }
  if (name === "webkit") delete launchOptions.args;
  const browser = await engine.launch(launchOptions);
  try {
    const page = await browser.newPage();
    page.on("console", (msg) => console.log(`[${name} console] ${msg.text()}`));
    page.on("pageerror", (err) => console.log(`[${name} pageerror] ${err.message}`));
    await page.goto(pageUrl);
    const result = await page.evaluate(() => window.__runRendezvousAuth());
    assert.deepEqual(result.withToken, { ok: true, message: "echo: hello-auth" });
    assert.equal(result.withoutToken.ok, false);
    assert.equal(result.withoutToken.code, StatusCode.UNAUTHENTICATED);
    assert.equal(seenSub, "alice");
    console.log(`${name}: browser rendezvous auth OK`, result);
  } finally {
    await browser.close();
  }
}

const which = process.argv[2] ?? "chromium";
if (which === "chromium" || which === "all") await runBrowser("chromium", chromium);
if (which === "firefox" || which === "all") await runBrowser("firefox", firefox);
if (which === "webkit" || which === "all") await runBrowser("webkit", webkit);

listener.close();
server.close();
console.log("rendezvous auth browser test passed");
