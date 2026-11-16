// Real-browser test: Rendezvous auth against the Go and Rust
// servers. Same flow as rendezvous_auth.test.mjs (which covers
// the JS server): the page dials with a minted bearer token
// (accepted) and without one (UNAUTHENTICATED), now against
// grpcdc.ServeRendezvousWithAuth and
// grpc_dc::rendezvous::serve_rendezvous_with_auth, enabled in
// both harnesses via RENDEZVOUS_SECRET.

import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium, firefox, webkit } from "playwright";

import { StatusCode, issueRendezvousToken } from "../js/index.js";

const ROOT = fileURLToPath(new URL("..", import.meta.url));
const MIME = { ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript" };
const SECRET = "rendezvous-auth-test-secret";

function firstStdoutLine(proc) {
  return new Promise((resolve, reject) => {
    let buf = "";
    proc.stdout.on("data", (chunk) => {
      buf += chunk;
      const at = buf.indexOf("\n");
      if (at >= 0) resolve(buf.slice(0, at));
    });
    proc.on("exit", (code) => reject(new Error(`server exited early (${code}): ${buf}`)));
    setTimeout(() => reject(new Error(`server printed no descriptor: ${buf}`)), 120000);
  });
}

async function buildGoServer() {
  const bin = join(ROOT, "browser-test", ".rendezvous-go-server");
  execFileSync("go", ["build", "-o", bin, "./cmd/rendezvous_server"], {
    cwd: join(ROOT, "go"),
    stdio: "inherit",
    env: { ...process.env, GOFLAGS: "-buildvcs=false" },
  });
  return bin;
}

async function buildRustServer() {
  execFileSync("cargo", ["build", "--features", "webrtc", "--example", "rendezvous_echo"], {
    cwd: join(ROOT, "rust"),
    stdio: "inherit",
  });
  return join(ROOT, "rust", "target", "debug", "examples", "rendezvous_echo");
}

const token = await issueRendezvousToken(SECRET, {
  sub: "alice",
  iss: "issuer",
  aud: "rendezvous",
  exp: 4102444800,
  scopes: ["read"],
  jti: "browser-stacks-1",
});

async function runStack(stackName, bin) {
  const proc = spawn(bin, [], {
    stdio: ["ignore", "pipe", "inherit"],
    env: { ...process.env, RENDEZVOUS_SECRET: SECRET },
  });
  try {
    const descriptor = JSON.parse(await firstStdoutLine(proc));
    console.log(`${stackName} auth rendezvous descriptor:`, descriptor);

    const server = createServer(async (req, res) => {
      if (req.url.startsWith("/rendezvous.json")) {
        res.writeHead(200, { "content-type": "application/json" });
        res.end(JSON.stringify(descriptor));
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
    try {
      const which = process.argv[2] ?? "chromium";
      if (which === "chromium" || which === "all") await runBrowser("chromium", chromium, pageUrl, stackName);
      if (which === "firefox" || which === "all") await runBrowser("firefox", firefox, pageUrl, stackName);
      if (which === "webkit" || which === "all") await runBrowser("webkit", webkit, pageUrl, stackName);
    } finally {
      server.close();
    }
  } finally {
    proc.kill();
  }
}

async function runBrowser(name, engine, pageUrl, stackName) {
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
    page.on("console", (msg) => console.log(`[${stackName}/${name} console] ${msg.text()}`));
    page.on("pageerror", (err) => console.log(`[${stackName}/${name} pageerror] ${err.message}`));
    await page.goto(pageUrl);
    const result = await page.evaluate(() => window.__runRendezvousAuth());
    assert.deepEqual(result.withToken, { ok: true, message: "echo: hello-auth" });
    assert.equal(result.withoutToken.ok, false);
    assert.equal(result.withoutToken.code, StatusCode.UNAUTHENTICATED);
    console.log(`${name}: browser rendezvous auth (${stackName} server) OK`, result);
  } finally {
    await browser.close();
  }
}

await runStack("go", await buildGoServer());
await runStack("rust", await buildRustServer());
console.log("rendezvous auth stacks browser test passed");
