// Browser -> Python Echo server through the Rust sidecar's
// signaling mode: direct_sidecar `signal` answers the POST
// (one shared PeerMux), bridges each browser session to the
// Python server's framed TCP endpoint. The page sees a normal
// same-origin /grpc-dc/signal (this harness proxies it to the
// sidecar, the host-integration shape; CORS/auth stay host-side).

import assert from "node:assert/strict";
import { execSync, spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { createServer, request } from "node:http";
import { readFile } from "node:fs/promises";
import { extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium, firefox, webkit } from "playwright";

const ROOT = fileURLToPath(new URL("..", import.meta.url));
const SIDECAR = join(ROOT, "webrtc/rust/target/debug/examples/direct_sidecar");
const MIME = { ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript" };
const LANG_PORT = 18101;

if (!existsSync(SIDECAR)) {
  execSync("cargo build --example direct_sidecar", {
    cwd: join(ROOT, "webrtc/rust"),
    stdio: "inherit",
    timeout: 900000,
  });
}

function waitForLine(proc, needle, timeoutMs = 60000) {
  return new Promise((resolve, reject) => {
    let buf = "";
    const timer = setTimeout(() => reject(new Error(`no ${needle} line`)), timeoutMs);
    proc.stdout.on("data", (d) => {
      buf += String(d);
      const line = buf.split("\n").find((l) => l.includes(needle));
      if (line) {
        clearTimeout(timer);
        resolve(line.trim());
      }
    });
    proc.once("exit", () => reject(new Error("process exited early")));
  });
}

const pythonServer = spawn("python3", ["browser-test/sidecar_echo_server.py", String(LANG_PORT)], {
  cwd: ROOT,
  stdio: ["ignore", "pipe", "inherit"],
});
await waitForLine(pythonServer, "READY");

const sidecar = spawn(
  SIDECAR,
  ["signal", "--http", "127.0.0.1:0", "--udp", "0.0.0.0:0", "--tcp", `127.0.0.1:${LANG_PORT}`],
  { cwd: ROOT, stdio: ["ignore", "pipe", "inherit"] },
);
const signalLine = await waitForLine(sidecar, "SIGNAL");
const sidecarHttp = signalLine.match(/http:\/\/(\S+?)\/grpc-dc\/signal/)[1];

function proxySignaling(req, res) {
  const chunks = [];
  req.on("data", (c) => chunks.push(c));
  req.on("end", () => {
    const body = Buffer.concat(chunks);
    const upstream = request(
      { host: "127.0.0.1", port: Number(sidecarHttp.split(":")[1]), path: req.url, method: "POST",
        headers: { "content-type": "application/json", "content-length": body.length } },
      (up) => {
        const out = [];
        up.on("data", (c) => out.push(c));
        up.on("end", () => {
          res.writeHead(up.statusCode, { "content-type": "application/json" });
          res.end(Buffer.concat(out));
        });
      },
    );
    upstream.on("error", () => { res.writeHead(502); res.end(); });
    upstream.end(body);
  });
}

const server = createServer(async (req, res) => {
  if (req.url.startsWith("/grpc-dc/signal")) return proxySignaling(req, res);
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
const pageUrl = `http://127.0.0.1:${server.address().port}/browser-test/signaling_page.html`;

async function runBrowser(name, engine) {
  const launchOptions = { args: ["--no-sandbox", "--disable-dev-shm-usage"] };
  if (name === "firefox") {
    launchOptions.firefoxUserPrefs = { "media.peerconnection.ice.obfuscate_host_addresses": false };
  }
  if (name === "webkit") delete launchOptions.args;
  const browser = await engine.launch(launchOptions);
  try {
    const page = await browser.newPage();
    page.on("pageerror", (err) => console.log(`[${name} pageerror] ${err.message}`));
    await page.goto(pageUrl);
    const result = await page.evaluate(() => window.__runSignaling());
    assert.equal(result.unary, "echo: hello");
    assert.deepEqual(result.ticks, [0, 1, 2]);
    console.log(`${name}: browser gRPC to Python server via sidecar signaling OK`, result);
  } finally {
    await browser.close();
  }
}

try {
  const which = process.argv[2] ?? "chromium";
  if (which === "chromium" || which === "all") await runBrowser("chromium", chromium);
  if (which === "firefox" || which === "all") await runBrowser("firefox", firefox);
  if (which === "webkit" || which === "all") await runBrowser("webkit", webkit);
  console.log("sidecar signaling browser test passed");
} finally {
  server.close();
  sidecar.kill();
  pythonServer.kill();
}
