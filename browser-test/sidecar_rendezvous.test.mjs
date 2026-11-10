// Browser -> Python Echo server through the Rust sidecar's
// rendezvous mode: direct_sidecar `rendezvous` runs a fixed
// RendezvousListener and bridges each browser session to the
// Python server's framed TCP endpoint. The page dials with
// rendezvousChannel using only the sidecar's printed
// descriptor — no signaling exchange at all.

import assert from "node:assert/strict";
import { execSync, spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium, firefox, webkit } from "playwright";

const ROOT = fileURLToPath(new URL("..", import.meta.url));
const SIDECAR = join(ROOT, "webrtc/rust/target/debug/examples/direct_sidecar");
const MIME = { ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript" };
const LANG_PORT = 18102;

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
  ["rendezvous", "--udp", "0.0.0.0:0", "--tcp", `127.0.0.1:${LANG_PORT}`],
  { cwd: ROOT, stdio: ["ignore", "pipe", "inherit"] },
);
const rendezvousLine = await waitForLine(sidecar, "RENDEZVOUS");
const descriptor = JSON.parse(rendezvousLine.slice("RENDEZVOUS ".length));
console.log("sidecar rendezvous descriptor:", descriptor);

const server = createServer(async (req, res) => {
  if (req.url === "/rendezvous.json") {
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
const pageUrl = `http://127.0.0.1:${server.address().port}/browser-test/rendezvous_page.html`;

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
    page.on("pageerror", (err) => console.log(`[${name} pageerror] ${err.message}`));
    await page.goto(pageUrl);
    const result = await page.evaluate(() => window.__runRendezvous());
    assert.equal(result.first.unary, "echo: hello-first");
    assert.deepEqual(result.first.ticks, [0, 1, 2]);
    assert.equal(result.second.unary, "echo: hello-second");
    console.log(`${name}: browser gRPC via sidecar rendezvous OK`, result);
  } finally {
    await browser.close();
  }
}

try {
  const which = process.argv[2] ?? "chromium";
  if (which === "chromium" || which === "all") await runBrowser("chromium", chromium);
  if (which === "firefox" || which === "all") await runBrowser("firefox", firefox);
  if (which === "webkit" || which === "all") await runBrowser("webkit", webkit);
  console.log("sidecar rendezvous browser test passed");
} finally {
  sidecar.kill();
  pythonServer.kill();
  server.close();
}
