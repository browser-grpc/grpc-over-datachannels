// Shared boilerplate for the Playwright browser tests: static file
// server for the repo tree, file-signaling waits, per-engine launch
// quirks, and engine selection. Every *.test.mjs used to re-implement
// these; they now live here once. Hand-written test infrastructure
// (not generated).

import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync } from "node:fs";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium, firefox, webkit } from "playwright";

export const ROOT = fileURLToPath(new URL("..", import.meta.url));

export const MIME = {
  ".html": "text/html",
  ".js": "text/javascript",
  ".mjs": "text/javascript",
  ".wasm": "application/wasm",
};

export const ENGINES = { chromium, firefox, webkit };

// Static server rooted at the repo tree. With `isolated`, responses
// also carry the COOP/COEP headers SharedArrayBuffer (the wasm worker
// mailbox) requires. `page` is a repo-relative path such as
// "browser-test/wasm_page.html"; returns { server, pageUrl }.
export async function startStaticServer(page, { isolated = false } = {}) {
  const server = createServer(async (req, res) => {
    try {
      const path = normalize(join(ROOT, decodeURIComponent(new URL(req.url, "http://x").pathname)));
      if (!path.startsWith(ROOT)) throw new Error("outside root");
      const body = await readFile(path);
      const headers = { "content-type": MIME[extname(path)] ?? "application/octet-stream" };
      if (isolated) {
        // SharedArrayBuffer (worker mailbox) needs cross-origin isolation.
        headers["cross-origin-opener-policy"] = "same-origin";
        headers["cross-origin-embedder-policy"] = "require-corp";
      }
      res.writeHead(200, headers);
      res.end(body);
    } catch {
      res.writeHead(404);
      res.end("not found");
    }
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  return { server, pageUrl: `http://127.0.0.1:${server.address().port}/${page}` };
}

// Poll until `path` exists with non-blank content; return the text.
export async function waitForFile(path, timeoutMs = 30000) {
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

// Launch one engine with the shared quirks: Chromium sandbox flags
// (dropped for WebKit/MiniBrowser, which rejects them) and the
// Firefox mDNS de-obfuscation pref (Playwright's Firefox answers no
// mDNS queries for its obfuscated .local candidates and will not
// initiate checks to same-IP pairs, so legs where our stack must
// reach it need raw IP candidates; Chromium answers mDNS itself).
export function launchBrowser(name, { extraArgs = [] } = {}) {
  const launchOptions = { args: ["--no-sandbox", "--disable-dev-shm-usage", ...extraArgs] };
  if (name === "firefox") {
    launchOptions.firefoxUserPrefs = {
      "media.peerconnection.ice.obfuscate_host_addresses": false,
    };
  }
  if (name === "webkit") delete launchOptions.args; // Chromium-only flags
  return ENGINES[name].launch(launchOptions);
}

// New page forwarding console/pageerror to the test log, tagged by
// engine name.
export async function newPage(browser, name) {
  const page = await browser.newPage();
  page.on("console", (msg) => console.log(`[${name} console] ${msg.text()}`));
  page.on("pageerror", (err) => console.log(`[${name} pageerror] ${err.message}`));
  return page;
}

// Run `fn(name, index)` for each selected engine: argv-style `which`
// is a single engine name or "all". With `webkitEnvGate`, the webkit
// leg of "all" only runs when GRPC_DC_WEBKIT is set (the wasm suites).
export async function runEngines(which, fn, { webkitEnvGate = false } = {}) {
  const selected = which ?? "chromium";
  let index = 0;
  for (const name of ["chromium", "firefox", "webkit"]) {
    if (selected !== "all" && selected !== name) continue;
    if (name === "webkit" && webkitEnvGate && selected === "all" && !process.env.GRPC_DC_WEBKIT) continue;
    await fn(name, index++);
  }
}

// Build a Go browser harness (./cmd/<pkg> under go/) into a fresh
// temp dir. Returns { dir, bin, signalBase } where signalBase(i)
// gives a fresh per-engine signaling base (a harness watches
// <base>.offer, so reusing one base across engines would feed a
// previous engine's .answer to the next — a silent cross-engine hang).
export function buildGoHarness(pkg, tmpPrefix) {
  const dir = mkdtempSync(join(tmpdir(), tmpPrefix));
  const bin = join(dir, pkg);
  execFileSync("go", ["build", "-o", bin, `./cmd/${pkg}`], {
    cwd: join(ROOT, "go"),
    stdio: "inherit",
  });
  return { dir, bin, signalBase: (i) => join(dir, `signal-${i}`) };
}
