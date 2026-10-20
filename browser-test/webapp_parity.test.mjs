// Webapp parity test: the fully client-side generator must
// produce stubs byte-identical to the native Racket protoc
// plugins, for the repo's echo.proto and for a two-file test
// schema exercising imports, all four method shapes, a deprecated
// method, and two services. The primary path runs the actual
// plugins inside the Racket/Wasm runtime (asserted via
// window.__generatedVia); a final case forces the built-in JS
// generators with ?gen=js and asserts identical output. Drives
// the real UI: upload files, click Generate, capture the
// downloaded zip, compare gen/<lang>/ entries.

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
    // Cross-origin isolation: the in-browser Racket/Wasm plugin
    // runner needs SharedArrayBuffer.
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

function pascal(base) {
  // The Racket templates' pascal only capitalizes the first
  // character (their string-split separator is a literal string,
  // so it never splits); mirror that exactly.
  return base ? base[0].toUpperCase() + base.slice(1) : base;
}

function camel(base) {
  // Scala's template splits on "_" for real (separator "_").
  return base
    .split("_")
    .map((part) => (part ? part[0].toUpperCase() + part.slice(1) : part))
    .join("");
}

// plugin: protoc plugin suffix (bin/protoc-gen-grpc-dc-<plugin>);
// stub: generated file name for a proto base name; runtime: one
// sentinel path inside the zip's runtime/<lang>/ tree.
const LANG_CONFIG = {
  js: { plugin: "js", stub: (b) => `${b}_grpc_dc.js`, runtime: "channel.js" },
  go: { plugin: "go", stub: (b) => `${b}_grpc_dc.go`, runtime: "channel.go" },
  python: { plugin: "python", stub: (b) => `${b}_grpc_dc.py`, runtime: "channel.py" },
  rust: { plugin: "rust", stub: (b) => `${b}_grpc_dc.rs`, runtime: "src/lib.rs" },
  java: { plugin: "java", stub: (b) => `${pascal(b)}GrpcDc.java`, runtime: "Channel.java" },
  csharp: { plugin: "csharp", stub: (b) => `${pascal(b)}GrpcDc.cs`, runtime: "Channel.cs" },
  cpp: { plugin: "cpp", stub: (b) => `${b}_grpc_dc.hpp`, runtime: "channel.hpp" },
  swift: { plugin: "swift", stub: (b) => `${pascal(b)}GrpcDc.swift`, runtime: "Channel.swift" },
  kotlin: { plugin: "kotlin", stub: (b) => `${pascal(b)}GrpcDc.kt`, runtime: "Channel.kt" },
  dart: { plugin: "dart", stub: (b) => `${b}_grpc_dc.dart`, runtime: "channel.dart" },
  zig: { plugin: "zig", stub: (b) => `${b}_grpc_dc.zig`, runtime: "grpcdc/grpcdc.zig" },
  c: { plugin: "c", stub: (b) => `${b}_grpc_dc.h`, runtime: "grpcdc/grpcdc.h" },
  lua: { plugin: "lua", stub: (b) => `${b}_grpc_dc.lua`, runtime: "grpcdc/channel.lua" },
  ruby: { plugin: "ruby", stub: (b) => `${b}_grpc_dc.rb`, runtime: "grpcdc.rb" },
  php: { plugin: "php", stub: (b) => `${b}_grpc_dc.php`, runtime: "grpcdc.php" },
  scala: { plugin: "scala", stub: (b) => `${camel(b)}GrpcDc.scala`, runtime: "Channel.scala" },
  "wasm-go": { plugin: "wasm-go", stub: (b) => `${b}_wasm_dc.go`, runtime: "wasm_bridge.js" },
  "wasm-zig": { plugin: "wasm-zig", stub: (b) => `${b}_wasm_dc.zig`, runtime: "wasm_bridge.js" },
  "wasm-cpp": { plugin: "wasm-cpp", stub: (b) => `${b}_wasm_dc.hpp`, runtime: "wasm_bridge.js" },
  "wasm-swift": { plugin: "wasm-swift", stub: (b) => `${pascal(b)}WasmGrpcDc.swift`, runtime: "wasm_bridge.js" },
  "wasm-kotlin": { plugin: "wasm-kotlin", stub: (b) => `${pascal(b)}WasmGrpcDc.kt`, runtime: "wasm_bridge.js" },
  "wasm-scala": { plugin: "wasm-scala", stub: (b) => `${camel(b)}ScalaJsGrpcDc.scala`, runtime: "wasm_bridge.js" },
};
const LANGS = (process.env.GRPC_DC_PARITY_LANGS ?? Object.keys(LANG_CONFIG).join(",")).split(",");

async function nativeReference(includeDir, fileArgs, paramsByLang = {}) {
  const refs = {};
  for (const lang of LANGS) {
    const plugin = LANG_CONFIG[lang].plugin;
    const outDir = await mkdtemp(join(tmpdir(), `grpcdc-ref-${lang}-`));
    const param = paramsByLang[lang];
    await run(
      "protoc",
      [
        `--plugin=protoc-gen-grpc-dc-${plugin}=${join(ROOT, "bin", `protoc-gen-grpc-dc-${plugin}`)}`,
        `--grpc-dc-${plugin}_out=${param ? param + ":" : ""}${outDir}`,
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
    // The first Generate boots the Racket/Wasm runtime and
    // compiles the plugins inside it; allow for slow engines.
    page.waitForEvent("download", { timeout: 240000 }),
    page.click("#generate"),
  ]);
  const path = await download.path();
  return readZip(await readFile(path));
}

async function assertRacketVia(page, name) {
  const via = await page.evaluate(() => window.__generatedVia);
  assert.ok(
    typeof via === "string" && via.startsWith("Racket plugins in-browser"),
    `${name}: expected generation via the Racket/Wasm plugins, got: ${via}`,
  );
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

    // Case 1: preloaded echo.proto, all languages, produced by
    // the actual Racket protoc plugins running in a Wasm runtime.
    let entries = await downloadZip(page);
    await assertRacketVia(page, name);
    let refs = await nativeReference(join(ROOT, "proto"), ["echo.proto"]);
    for (const lang of LANGS) {
      const stub = LANG_CONFIG[lang].stub("echo");
      const expected = await readFile(join(refs[lang], stub));
      const actual = entries.get(`gen/${lang}/${stub}`);
      assert.ok(actual, `zip missing gen/${lang}/${stub}`);
      assert.ok(actual.equals(expected), `${name}: browser ${lang} stub differs from native plugin`);
      assert.ok(entries.has(`runtime/${lang}/` + LANG_CONFIG[lang].runtime), "runtime bundled for " + lang);
    }
    if (LANGS.includes("python")) {
      const expectedPb = await readFile(join(refs.python, "echo_pb.py"));
      const actualPb = entries.get("gen/python/echo_pb.py");
      assert.ok(actualPb, "zip missing gen/python/echo_pb.py");
      assert.ok(actualPb.equals(expectedPb), `${name}: browser python messages differ from native plugin`);
    }
    // Zip completeness: generated message types for every language
    // that emits them, a manifest covering every entry with nothing
    // missing, and the README.
    const upperFirst = (b) => (b ? b[0].toUpperCase() + b.slice(1) : b);
    const MESSAGE_FILES = {
      js: (b) => `${b}_pb.js`,
      go: (b) => `${b}_pb.go`,
      python: (b) => `${b}_pb.py`,
      rust: (b) => `${b}_pb.rs`,
      java: (b) => `${upperFirst(b)}Pb.java`,
      csharp: (b) => `${upperFirst(b)}Pb.cs`,
      cpp: (b) => `${b}_messages.hpp`,
      swift: (b) => `${upperFirst(b)}Messages.swift`,
      kotlin: (b) => `${upperFirst(b)}Messages.kt`,
      dart: (b) => `${b}_messages.dart`,
      zig: (b) => `${b}_messages.zig`,
  c: (b) => `${b}_messages.h`,
      lua: (b) => `${b}_messages.lua`,
      ruby: (b) => `${b}_pb.rb`,
      php: (b) => `${b}_pb.php`,
      scala: (b) => `${camel(b)}Messages.scala`,
    };
    for (const lang of LANGS) {
      const mf = MESSAGE_FILES[lang];
      if (!mf) continue;
      const mfName = mf("echo");
      const expectedMsg = await readFile(join(refs[lang], mfName));
      const actualMsg = entries.get(`gen/${lang}/${mfName}`);
      assert.ok(actualMsg, `zip missing gen/${lang}/${mfName}`);
      assert.ok(actualMsg.equals(expectedMsg), `${name}: browser ${lang} messages differ from native plugin`);
    }
    assert.ok(entries.has("README.md"), "zip carries README.md");
    assert.match(entries.get("README.md").toString(), /manifest\.json/, "README documents the manifest");
    const manifest = JSON.parse(entries.get("manifest.json").toString());
    assert.deepEqual(manifest.missing, [], "manifest reports nothing missing");
    assert.deepEqual(new Set(manifest.files), new Set(entries.keys()), "manifest files cover every zip entry");
    assert.ok(entries.has("proto/echo.proto"), "zip carries the schema");
    for (const lang of LANGS) {
      assert.ok(JSON.parse(entries.get("manifest.json").toString()).languages.includes(lang), "manifest lists " + lang);
    }

    // Case 2: two-file schema uploaded through the file input.
    await page.setInputFiles("#upload", [join(ROOT, "webapp/testdata/common.proto"), join(ROOT, "webapp/testdata/shop.proto"), join(ROOT, "webapp/testdata/my_api.proto")]);
    await page.waitForFunction(
      () => document.querySelector("#tree").textContent.includes("BillingAPI"),
      null,
      { timeout: 30000 },
    );
    entries = await downloadZip(page);
    await assertRacketVia(page, name);
    refs = await nativeReference(join(ROOT, "webapp/testdata"), ["common.proto", "shop.proto", "my_api.proto"]);
    if (LANGS.includes("python")) {
      for (const base of ["common", "shop", "my_api"]) {
        const expectedPb = await readFile(join(refs.python, `${base}_pb.py`));
        const actualPb = entries.get(`gen/python/${base}_pb.py`);
        assert.ok(actualPb, `zip missing gen/python/${base}_pb.py`);
        assert.ok(actualPb.equals(expectedPb), `${name}: browser python ${base} messages differ from native plugin`);
      }
    }
    for (const lang of LANGS) {
      for (const base of ["common", "shop", "my_api"]) {
        const stub = LANG_CONFIG[lang].stub(base);
        const expected = await readFile(join(refs[lang], stub));
        const actual = entries.get(`gen/${lang}/${stub}`);
        assert.ok(actual, `zip missing gen/${lang}/${stub}`);
        assert.ok(actual.equals(expected), `${name}: browser ${lang} ${base} stub differs from native plugin`);
      }
    }

    // Case 3: plugin parameters flow into generation; per-file
    // downloads match the zip entries; highlighting is rendered.
    await page.locator(".tab", { hasText: "echo.proto" }).first().click();
    await page.fill('input[data-param="js"]', "pb_import=./custom_pb.js");
    await page.fill('input[data-param="go"]', "go_package=shopapi");
    await page.selectOption('select[data-trace="python"]', "hooks");
    entries = await downloadZip(page);
    await assertRacketVia(page, name);
    refs = await nativeReference(join(ROOT, "proto"), ["echo.proto"], {
      js: "pb_import=./custom_pb.js",
      go: "go_package=shopapi",
      python: "trace=hooks",
    });
    assert.match(
      entries.get("gen/python/echo_grpc_dc.py").toString(),
      /set_tracer = grpcdc\.set_tracer/,
      "trace=hooks select wires the Python tracer re-export",
    );
    for (const lang of ["js", "go", "python"]) {
      if (!LANG_CONFIG[lang]) continue;
      const stub = LANG_CONFIG[lang].stub("echo");
      const expected = await readFile(join(refs[lang], stub));
      assert.ok(entries.get(`gen/${lang}/${stub}`).equals(expected), `${name}: ${lang} stub with plugin params differs`);
    }
    const [single] = await Promise.all([
      page.waitForEvent("download", { timeout: 30000 }),
      page.locator("#results a", { hasText: "gen/js/echo_grpc_dc.js" }).first().click(),
    ]);
    const singleBytes = await readFile(await single.path());
    assert.ok(singleBytes.equals(entries.get("gen/js/echo_grpc_dc.js")), "per-file download matches zip entry");
    assert.ok((await page.locator("#highlight .tok-kw").count()) > 0, "syntax highlighting rendered");

    // Case 4: a broken schema surfaces a compiler error, marks the
    // error line, and disables Generate.
    await page.fill("#editor", 'syntax = "proto3";\nservice {\n');
    await page.waitForSelector("#status.err", { timeout: 30000 });
    assert.match(await page.textContent("#status"), /syntax error/);
    assert.ok(await page.isDisabled("#generate"), "Generate disabled on compile error");
    await page.waitForSelector("#highlight .line-err", { timeout: 30000 });

    // Case 5: ?gen=js forces the built-in JS generators; output
    // must still be byte-identical (this is also the fallback the
    // app uses when the Racket runtime cannot start).
    await page.goto(`${baseUrl}/webapp/index.html?gen=js`);
    await page.waitForFunction(() => window.__webappReady, null, { timeout: 60000 });
    await page.waitForSelector("#status.ok", { timeout: 60000 });
    entries = await downloadZip(page);
    assert.equal(await page.evaluate(() => window.__generatedVia), "built-in generators");
    refs = await nativeReference(join(ROOT, "proto"), ["echo.proto"]);
    for (const lang of LANGS) {
      const stub = LANG_CONFIG[lang].stub("echo");
      const expected = await readFile(join(refs[lang], stub));
      const actual = entries.get(`gen/${lang}/${stub}`);
      assert.ok(actual && actual.equals(expected), `${name}: fallback ${lang} stub differs from native plugin`);
    }
    // The fallback message generators now cover every language
    // (byte-identical to the native plugins): stubs and message
    // types alike, so the fallback manifest reports nothing
    // missing.
    for (const lang of LANGS) {
      const mf = MESSAGE_FILES[lang];
      if (!mf) continue;
      const mfName = mf("echo");
      const expectedMsg = await readFile(join(refs[lang], mfName));
      const actualMsg = entries.get(`gen/${lang}/${mfName}`);
      assert.ok(actualMsg, `fallback zip missing gen/${lang}/${mfName}`);
      assert.ok(actualMsg.equals(expectedMsg), `${name}: fallback ${lang} messages differ from native plugin`);
    }
    if (LANGS.includes("java")) {
      const expectedJavaReq = await readFile(join(refs.java, "EchoRequest.java"));
      const actualJavaReq = entries.get("gen/java/EchoRequest.java");
      assert.ok(actualJavaReq && actualJavaReq.equals(expectedJavaReq),
        `${name}: fallback java message class differs from native plugin`);
    }
    const fbManifest = JSON.parse(entries.get("manifest.json").toString());
    assert.match(fbManifest.fallbackNote ?? "", /stubs and generated message types for every selected language/, "fallback manifest explains the coverage");
    assert.deepEqual(fbManifest.missing, [], "fallback manifest reports nothing missing: " + fbManifest.missing.join(", "));
    console.log(`${name}: webapp parity OK (echo + shop byte-identical via Racket/Wasm plugins, params, per-file download, error surfaced, JS fallback identical)`);
  } finally {
    await browser.close();
  }
}

const which = process.argv[2] ?? "all";
if (which === "chromium" || which === "all") await runCase("chromium", chromium);
if (which === "firefox" || which === "all") await runCase("firefox", firefox);
console.log("webapp parity test passed");
server.close();
