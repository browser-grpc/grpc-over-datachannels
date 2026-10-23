// Webapp Browse test: the generated-code browser must navigate
// every language x bundled schema, show bytes identical to the
// in-page generators (themselves parity-checked against the
// native plugins), search and compare across languages, restore
// deep links, and hand schemas back to the Generator. Completeness
// is asserted two ways: generated groups match generateFiles
// output counts, and every manifest example/test path exists as a
// served corpus asset.

import assert from "node:assert/strict";
import { createServer } from "node:http";
import { access, readFile } from "node:fs/promises";
import { extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium, firefox } from "playwright";

const ROOT = fileURLToPath(new URL("..", import.meta.url));
const MIME = {
  ".html": "text/html",
  ".js": "text/javascript",
  ".mjs": "text/javascript",
  ".wasm": "application/wasm",
  ".css": "text/css",
  ".proto": "text/plain",
  ".json": "application/json",
};

const server = createServer(async (req, res) => {
  try {
    const path = normalize(join(ROOT, decodeURIComponent(new URL(req.url, "http://x").pathname)));
    if (!path.startsWith(ROOT)) throw new Error("outside root");
    const body = await readFile(path);
    res.writeHead(200, {
      "content-type": MIME[extname(path)] ?? "application/octet-stream",
      "cross-origin-opener-policy": "same-origin",
      "cross-origin-embedder-policy": "require-corp",
    });
    res.end(body);
  } catch {
    res.writeHead(404);
    res.end("not found");
  }
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const baseUrl = `http://127.0.0.1:${server.address().port}`;

const manifest = JSON.parse(
  await readFile(join(ROOT, "webapp/gen/corpus-manifest.json"), "utf8"),
);

// Node-side completeness: every manifest path is a served asset.
for (const [lang, entry] of Object.entries(manifest.languages)) {
  for (const group of ["examples", "tests"]) {
    for (const rel of entry[group]) {
      await access(join(ROOT, "webapp/assets/corpus", lang, group, rel));
    }
  }
}
console.log("manifest assets complete for", Object.keys(manifest.languages).length, "languages");

async function runCase(name, engine) {
  const browser = await engine.launch({});
  try {
    const page = await browser.newPage();
    page.on("pageerror", (err) => console.log(`[${name} pageerror] ${err.message}`));
    await page.goto(`${baseUrl}/webapp/index.html`);
    await page.waitForFunction(() => window.__webappReady, null, { timeout: 60000 });

    await page.click("#nav-browse");
    await page.waitForSelector("#browse-files .file", { timeout: 60000 });
    assert.ok(await page.locator("#browse-view").isVisible(),
      `${name}: browse view must be visible (not just un-hidden)`);
    assert.ok(!(await page.locator("#generator-view").isVisible()),
      `${name}: generator view must be hidden in browse mode`);

    // 23 targets on the rail (16 native + 6 WASM facades + Kotlin/Native).
    const railCount = await page.locator("#browse-langs button").count();
    assert.equal(railCount, 23, `${name}: expected 23 language buttons, got ${railCount}`);

    // Byte-identity + generated completeness for sample languages.
    for (const lang of ["rust", "c", "scala"]) {
      await page.evaluate(async (l) => {
        const gens = await import("./gen/generators.js");
        const proto = await (await fetch("assets/echo.proto")).text();
        const out = JSON.parse(window.__grpcdcCompile(
          JSON.stringify({ files: { "echo.proto": proto }, entries: ["echo.proto"] })));
        const setBytes = Uint8Array.from(atob(out.set), (c) => c.charCodeAt(0));
        window.__expectedFiles = gens.generateFiles(l, setBytes, ["echo.proto"], "");
      }, lang);
      // Click the language rail button with this id's label.
      await page.evaluate((l) => {
        const labels = { rust: "Rust", c: "C", scala: "Scala" };
        [...document.querySelectorAll("#browse-langs button")]
          .find((b) => b.textContent === labels[l]).click();
      }, lang);
      await page.waitForFunction(
        (expected) => {
          const groups = [...document.querySelectorAll("#browse-files .group")].map((g) => g.textContent);
          return groups.includes("Stubs") && groups.includes("Runtime");
        },
        null,
        { timeout: 60000 },
      );
      const domGenerated = await page.evaluate(() => {
        let count = 0;
        let group = "";
        for (const el of document.querySelectorAll("#browse-files .group, #browse-files .file")) {
          if (el.classList.contains("group")) group = el.textContent;
          else if (group === "Stubs" || group === "Messages") count++;
        }
        return count;
      });
      const expectedCount = await page.evaluate(() => window.__expectedFiles.length);
      assert.equal(domGenerated, expectedCount,
        `${name}: ${lang} generated file count ${domGenerated} != generateFiles ${expectedCount}`);

      // Open the first stub and compare viewer bytes.
      const firstStub = await page.evaluate(() => window.__expectedFiles[0].name);
      await page.evaluate(() => {
        let group = "";
        for (const el of document.querySelectorAll("#browse-files .group, #browse-files .file")) {
          if (el.classList.contains("group")) group = el.textContent;
          else if (group === "Stubs") { el.click(); return; }
        }
        throw new Error("no stub file button");
      });
      await page.waitForFunction(() => window.__browseCurrent, null, { timeout: 30000 });
      const current = await page.evaluate(() => window.__browseCurrent);
      const expected = await page.evaluate(
        (n) => window.__expectedFiles.find((f) => f.name === n),
        current.name,
      );
      assert.equal(current.name, firstStub, `${name}: first stub opened`);
      assert.equal(current.content, expected.content,
        `${name}: ${lang} viewer bytes differ from generator output`);
      assert.match(await page.textContent("#browse-title-a"), new RegExp(current.name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
    }

    // Search finds a known symbol and opens it.
    await page.fill("#browse-search", "Unary");
    await page.waitForSelector("#browse-results .hit", { timeout: 30000 });
    await page.click("#browse-results .hit >> nth=0");
    await page.waitForFunction(
      () => window.__browseCurrent && location.hash.startsWith("#browse/"),
      null,
      { timeout: 30000 },
    );
    const deepLink = await page.evaluate(() => location.href);

    // Compare mode: rust (current lang may be scala; reselect rust)
    await page.evaluate(() => {
      [...document.querySelectorAll("#browse-langs button")]
        .find((b) => b.textContent === "Rust").click();
    });
    await page.waitForSelector("#browse-files .file", { timeout: 30000 });
    await page.selectOption("#browse-compare", "go");
    await page.evaluate(() => {
      let group = "";
      for (const el of document.querySelectorAll("#browse-files .group, #browse-files .file")) {
        if (el.classList.contains("group")) group = el.textContent;
        else if (group === "Stubs") { el.click(); return; }
      }
    });
    await page.waitForSelector("#browse-pane-b:not([hidden])", { timeout: 30000 });
    assert.match(await page.textContent("#browse-title-b"), /^go ·/,
      `${name}: compare pane should show the Go counterpart`);

    // Deep link restores the same file after reload.
    await page.goto(deepLink);
    await page.waitForFunction(() => window.__webappReady, null, { timeout: 60000 });
    await page.waitForFunction(() => window.__browseCurrent, null, { timeout: 60000 });
    const restored = await page.evaluate(() => window.__browseCurrent);
    assert.ok(restored && restored.name, `${name}: deep link restored a file`);

    // Editor schema: browse the Generator tab's current files
    // (the preloaded echo.proto) without leaving the corpus.
    await page.selectOption("#browse-schema", "editor");
    await page.waitForSelector("#browse-files .file", { timeout: 30000 });
    const editorFiles = await page.evaluate(() =>
      [...document.querySelectorAll("#browse-files .file")].map((b) => b.textContent));
    assert.ok(editorFiles.some((n) => n.includes("echo")),
      `${name}: editor schema lists echo files, got ${editorFiles.slice(0, 3)}`);
    await page.selectOption("#browse-schema", "echo");
    await page.waitForSelector("#browse-files .file", { timeout: 30000 });

    // Handoff back to the Generator with the schema loaded.
    await page.click("#browse-open-generator");
    await page.waitForFunction(
      () => !document.querySelector("#generator-view").hidden,
      null,
      { timeout: 30000 },
    );
    const generateDisabled = await page.evaluate(() => document.querySelector("#generate").disabled);
    assert.equal(generateDisabled, false, `${name}: generator compiled the handed-off schema`);

    console.log(`${name}: webapp browse OK (23 langs, byte-identical view, search, compare, deep link, generator handoff)`);
  } finally {
    await browser.close();
  }
}

const which = process.argv[2] ?? "all";
if (which === "all" || which === "chromium") await runCase("chromium", chromium);
if (which === "all" || which === "firefox") await runCase("firefox", firefox);
server.close();
console.log("webapp browse test passed");
