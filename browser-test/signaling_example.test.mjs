// The runnable example in examples/signaling, driven as a
// user would: start its server, open the page in a real
// browser, and check the page reports its Echo results.

import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { chromium, firefox, webkit } from "playwright";

const ROOT = fileURLToPath(new URL("..", import.meta.url));
const PORT = 18099;

const server = spawn("node", ["examples/signaling/server.mjs"], {
  cwd: ROOT,
  env: { ...process.env, PORT: String(PORT) },
  stdio: ["ignore", "pipe", "inherit"],
});
await new Promise((resolve, reject) => {
  server.stdout.on("data", (d) => {
    if (String(d).includes("open http://")) resolve();
  });
  server.once("exit", () => reject(new Error("example server exited early")));
  setTimeout(() => reject(new Error("example server start timed out")), 15000);
});

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
    await page.goto(`http://127.0.0.1:${PORT}/`);
    await page.waitForFunction(
      () => document.getElementById("result")?.textContent.includes("signaling example OK"),
      null,
      { timeout: 30000 },
    );
    const text = await page.textContent("#result");
    assert.ok(text.includes("unary -> echo: hello"), text);
    assert.ok(text.includes("serverStream -> indexes 0, 1, 2"), text);
    console.log(`${name}: signaling example page OK`);
  } finally {
    await browser.close();
  }
}

try {
  const which = process.argv[2] ?? "chromium";
  if (which === "chromium" || which === "all") await runBrowser("chromium", chromium);
  if (which === "firefox" || which === "all") await runBrowser("firefox", firefox);
  if (which === "webkit" || which === "all") await runBrowser("webkit", webkit);
  console.log("signaling example test passed");
} finally {
  server.kill();
}
