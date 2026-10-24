// Browser-examples matrix: the newcomer-facing index page
// (examples/browser) in Chromium, Firefox, and WebKit. For
// each of the nine Wasm languages, click its index entry and
// require the real Echo result through the page's own flow:
// iframe client page -> WebSocket signaling -> Node WebRTC
// stack peer -> generated Echo service. This is the same page
// the Docker browser-examples profile serves; here it runs
// against the in-tree server so `make test` covers all three
// engines, not just Chromium.

import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createServer } from "node:net";
import { fileURLToPath } from "node:url";
import { chromium, firefox, webkit } from "playwright";

const ROOT = fileURLToPath(new URL("..", import.meta.url));
const LANGS = ["Go", "Zig", "C++", "Swift", "Kotlin", "Lua", "Dart", "Rust", "Scala.js"];

const probe = createServer();
await new Promise((resolve) => probe.listen(0, "127.0.0.1", resolve));
const port = probe.address().port;
await new Promise((resolve) => probe.close(resolve));

const server = spawn("node", ["examples/browser/server.mjs"], {
  cwd: ROOT,
  env: { ...process.env, PORT: String(port) },
  stdio: ["ignore", "pipe", "pipe"],
});
let serverLog = "";
server.stdout.on("data", (d) => (serverLog += d));
server.stderr.on("data", (d) => (serverLog += d));
await new Promise((resolve, reject) => {
  const timer = setTimeout(() => reject(new Error(`example server did not start:\n${serverLog}`)), 30000);
  server.stdout.on("data", () => {
    if (serverLog.includes("browser examples:")) {
      clearTimeout(timer);
      resolve();
    }
  });
});

async function runBrowser(name, engine) {
  const launchOptions = { args: ["--no-sandbox", "--disable-dev-shm-usage"] };
  if (name === "firefox") {
    launchOptions.firefoxUserPrefs = {
      "media.peerconnection.ice.obfuscate_host_addresses": false,
    };
  }
  if (name === "webkit") delete launchOptions.args; // Chromium-only flags; MiniBrowser rejects them
  const browser = await engine.launch(launchOptions);
  const failures = [];
  try {
    const page = await browser.newPage();
    page.on("pageerror", (err) => console.log(`[${name} pageerror] ${err.message}`));
    await page.goto(`http://127.0.0.1:${port}/`);
    for (const lang of LANGS) {
      try {
        await page.getByRole("link", { name: lang, exact: true }).click();
        await page.waitForFunction(
          (expected) => {
            const text = document.getElementById("out").textContent;
            return text.startsWith(`${expected}:`) && text.includes("echo: hello");
          },
          lang,
          { timeout: 120000 },
        );
        console.log(`${name}: ${lang} OK`);
      } catch (err) {
        failures.push(lang);
        const out = await page.evaluate(() => document.getElementById("out").textContent);
        console.log(`${name}: ${lang} FAILED (${String(err.message).split("\n")[0]}); out=${out}`);
      }
    }
  } finally {
    await browser.close();
  }
  assert.deepEqual(failures, [], `${name}: browser examples failed for ${failures.join(", ")}`);
  console.log(`BROWSER EXAMPLES (${name}): ${LANGS.length}/${LANGS.length} passed`);
}

const which = process.argv[2] ?? "chromium";
try {
  if (which === "chromium" || which === "all") await runBrowser("chromium", chromium);
  if (which === "firefox" || which === "all") await runBrowser("firefox", firefox);
  if (which === "webkit" || which === "all") await runBrowser("webkit", webkit);
} finally {
  server.kill();
}
console.log("browser examples test passed");
