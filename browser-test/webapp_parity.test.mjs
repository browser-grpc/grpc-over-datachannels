// Webapp parity test: the fully client-side generator (protocompile
// WASM + generated JS generators in the page) must produce stubs
// byte-identical to the native Racket protoc plugins, for the
// repo's echo.proto and for a two-file test schema exercising
// imports, all four method shapes, a deprecated method, and two
// services. Drives the real UI: upload files, click Generate,
// capture the downloaded zip, compare gen/<lang>/ entries.

import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { createServer } from "node:http";
import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { chromium, firefox } from "playwright";

const run = promisify(execFile);
const ROOT = fileURLToPath(new URL("..", import.meta.url));
const MIME = {
  ".html": "text/html",
  ".js": "text/javascript",
  ".mjs": "text/javascript",
  ".wasm": "application/wasm",
  ".css": "text/css",
  ".proto": "text/plain",
};

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
const baseUrl = `http://127.0.0.1:${server.address().port}`;

const LANGS = ["js", "go", "python"];
const STUB_EXT = { js: "js", go: "go", python: "py" };

async function nativeReference(includeDir, fileArgs) {
  const refs = {};
  for (const lang of LANGS) {
    const outDir = await mkdtemp(join(tmpdir(), `grpcdc-ref-${lang}-`));
    await run(
      "protoc",
      [
        `--plugin=protoc-gen-grpc-dc-${lang}=${join(ROOT, "bin", `protoc-gen-grpc-dc-${lang}`)}`,
        `--grpc-dc-${lang}_out=${outDir}`,
        "-I", includeDir,
        ...fileArgs,
      ],
      { cwd: ROOT },
    );
    refs[lang] = outDir;
  }
  return refs;
}

function readZip(buf) {
  // Store-only zips from the app's writer: walk the central directory.
  let eocd = -1;
  for (let i = buf.length - 22; i >= 0; i--) {
    if (buf.readUInt32LE(i) === 0x06054b50) { eocd = i; break; }
  }
  assert.notEqual(eocd, -1, "zip end of central directory not found");
  const count = buf.readUInt16LE(eocd + 10);
  let off = buf.readUInt32LE(eocd + 16);
  const entries = new Map();
  for (let n = 0; n < count; n++) {
    assert.equal(buf.readUInt32LE(off), 0x02014b50, "central directory entry");
    const method = buf.readUInt16LE(off + 10);
    const size = buf.readUInt32LE(off + 20);
    const nameLen = buf.readUInt16LE(off + 28);
    const extraLen = buf.readUInt16LE(off + 30);
    const commentLen = buf.readUInt16LE(off + 32);
    const localOff = buf.readUInt32LE(off + 42);
    const name = buf.toString("utf8", off + 46, off + 46 + nameLen);
    assert.equal(method, 0, "stored zip entry: " + name);
    const localNameLen = buf.readUInt16LE(localOff + 26);
    const localExtraLen = buf.readUInt16LE(localOff + 28);
    const dataStart = localOff + 30 + localNameLen + localExtraLen;
    entries.set(name, buf.subarray(dataStart, dataStart + size));
    off += 46 + nameLen + extraLen + commentLen;
  }
  return entries;
}

async function downloadZip(page) {
  const [download] = await Promise.all([
    page.waitForEvent("download", { timeout: 30000 }),
    page.click("#generate"),
  ]);
  const path = await download.path();
  return readZip(await readFile(path));
}

async function runCase(name, engine) {
  const browser = await engine.launch({});
  try {
    const page = await browser.newPage();
    page.on("pageerror", (err) => console.log(`[${name} pageerror] ${err.message}`));
    await page.goto(`${baseUrl}/webapp/index.html`);
    await page.waitForFunction(() => window.__webappReady, null, { timeout: 60000 });
    await page.waitForSelector("#status.ok", { timeout: 60000 });
    assert.match(await page.textContent("#tree"), /echo\.Echo/);

    // Case 1: preloaded echo.proto, all three languages.
    let entries = await downloadZip(page);
    let refs = await nativeReference(join(ROOT, "proto"), ["echo.proto"]);
    for (const lang of LANGS) {
      const expected = await readFile(join(refs[lang], `echo_grpc_dc.${STUB_EXT[lang]}`));
      const actual = entries.get(`gen/${lang}/echo_grpc_dc.${STUB_EXT[lang]}`);
      assert.ok(actual, `zip missing gen/${lang}/echo_grpc_dc.${STUB_EXT[lang]}`);
      assert.ok(actual.equals(expected), `${name}: browser ${lang} stub differs from native plugin`);
      assert.ok(entries.has(`runtime/${lang}/` + { js: "channel.js", go: "channel.go", python: "channel.py" }[lang]), "runtime bundled for " + lang);
    }
    assert.ok(entries.has("proto/echo.proto"), "zip carries the schema");
    assert.deepEqual(JSON.parse(entries.get("manifest.json").toString()).languages, LANGS);

    // Case 2: two-file schema uploaded through the file input.
    await page.setInputFiles("#upload", [join(ROOT, "webapp/testdata/common.proto"), join(ROOT, "webapp/testdata/shop.proto")]);
    await page.waitForFunction(
      () => document.querySelector("#tree").textContent.includes("BillingAPI"),
      null,
      { timeout: 30000 },
    );
    entries = await downloadZip(page);
    refs = await nativeReference(join(ROOT, "webapp/testdata"), ["common.proto", "shop.proto"]);
    for (const lang of LANGS) {
      for (const base of ["common", "shop"]) {
        const expected = await readFile(join(refs[lang], `${base}_grpc_dc.${STUB_EXT[lang]}`));
        const actual = entries.get(`gen/${lang}/${base}_grpc_dc.${STUB_EXT[lang]}`);
        assert.ok(actual, `zip missing gen/${lang}/${base}_grpc_dc.${STUB_EXT[lang]}`);
        assert.ok(actual.equals(expected), `${name}: browser ${lang} ${base} stub differs from native plugin`);
      }
    }

    // Case 3: a broken schema surfaces a compiler error and disables Generate.
    await page.fill("#editor", 'syntax = "proto3";\nservice {\n');
    await page.waitForSelector("#status.err", { timeout: 30000 });
    assert.match(await page.textContent("#status"), /syntax error/);
    assert.ok(await page.isDisabled("#generate"), "Generate disabled on compile error");
    console.log(`${name}: webapp parity OK (echo + shop byte-identical, error surfaced)`);
  } finally {
    await browser.close();
  }
}

const which = process.argv[2] ?? "all";
if (which === "chromium" || which === "all") await runCase("chromium", chromium);
if (which === "firefox" || which === "all") await runCase("firefox", firefox);
console.log("webapp parity test passed");
server.close();
