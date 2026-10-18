// grpc-dc web app: fully client-side stub generation.
//
// Flow: the protocompile WASM compiler (webapp/compiler, Go ->
// wasm) turns the edited .proto sources into FileDescriptorSet
// bytes; the generated browser generators (webapp/gen/
// generators.js, stamped by racket/webgen.rkt) walk that
// descriptor exactly like the native Racket protoc plugins and
// emit the same files; the selected languages' runtimes are
// bundled from this repository's generated runtime files; a
// dependency-free store-only zip writer packs it all up.

import { generateFiles, describeFiles, buildPluginRequest, parsePluginResponse } from "./gen/generators.js";

const ACTIVE_LANGS = [
  ["js", "JavaScript"],
  ["go", "Go"],
  ["python", "Python"],
  ["rust", "Rust"],
  ["java", "Java"],
  ["csharp", "C#"],
  ["cpp", "C++"],
  ["swift", "Swift"],
  ["kotlin", "Kotlin"],
  ["dart", "Dart"],
  ["zig", "Zig"],
  ["lua", "Lua"],
  ["ruby", "Ruby"],
  ["php", "PHP"],
  ["scala", "Scala"],
  ["wasm-go", "Go (WASM facade)"],
  ["wasm-zig", "Zig (WASM facade)"],
  ["wasm-cpp", "C++ (WASM facade)"],
  ["wasm-swift", "Swift (WASM facade)"],
  ["wasm-kotlin", "Kotlin (WASM facade)"],
  ["wasm-scala", "Scala.js (facade)"],
];
// Facade browser generators not yet emitted.
const PLANNED_LANGS = [];

// Runtime files bundled per language, relative to assets/runtime/.
const RUNTIME_FILES = {
  js: ["codec.js", "endpoint.js", "channel.js", "server.js", "loopback.js", "dynamic.js"],
  go: ["channel.go", "codec.go", "dynamic.go", "endpoint.go", "loopback.go", "server.go", "wire_gen.go", "webrtc_transport.go"],
  python: ["__init__.py", "channel.py", "codec.py", "dynamic.py", "endpoint.py", "loopback.py", "server.py", "wire_gen.py"],
  rust: ["Cargo.toml", "src/channel.rs", "src/codec.rs", "src/dynamic.rs", "src/endpoint.rs", "src/lib.rs", "src/message.rs", "src/server.rs", "src/status.rs", "src/transport.rs", "src/webrtc_transport.rs", "src/wire_gen.rs"],
  java: ["Channel.java", "Codec.java", "Dynamic.java", "Endpoint.java", "Marshaler.java", "MemoryTransport.java", "Server.java", "StatusException.java", "Transport.java", "Unmarshaler.java", "Wire.java"],
  csharp: ["AsyncPump.cs", "Channel.cs", "Codec.cs", "Dynamic.cs", "Endpoint.cs", "Grpcdc.csproj", "MemoryTransport.cs", "Server.cs", "StatusException.cs", "Transport.cs", "Wire.cs"],
  cpp: ["async.hpp", "channel.hpp", "codec.hpp", "dynamic.hpp", "endpoint.hpp", "memory_transport.hpp", "server.hpp", "status.hpp", "transport.hpp", "wire.hpp"],
  swift: ["Channel.swift", "Codec.swift", "Dynamic.swift", "Endpoint.swift", "MemoryTransport.swift", "Server.swift", "Status.swift", "Transport.swift", "Wire.swift"],
  kotlin: ["AsyncPump.kt", "Channel.kt", "Codec.kt", "Dynamic.kt", "Endpoint.kt", "MemoryTransport.kt", "Server.kt", "Status.kt", "Transport.kt", "Wire.kt"],
  dart: ["channel.dart", "codec.dart", "dynamic.dart", "endpoint.dart", "memory_transport.dart", "server.dart", "status.dart", "transport.dart", "wire.dart"],
  zig: ["build.zig", "grpcdc/channel.zig", "grpcdc/codec.zig", "grpcdc/dynamic.zig", "grpcdc/endpoint.zig", "grpcdc/grpcdc.zig", "grpcdc/memory_transport.zig", "grpcdc/server.zig", "grpcdc/status.zig", "grpcdc/transport.zig", "grpcdc/wire.zig"],
  lua: ["grpcdc/channel.lua", "grpcdc/codec.lua", "grpcdc/dynamic.lua", "grpcdc/endpoint.lua", "grpcdc/memory_transport.lua", "grpcdc/server.lua", "grpcdc/status.lua", "grpcdc/transport.lua", "grpcdc/wire.lua"],
  ruby: ["grpcdc.rb", "grpcdc/channel.rb", "grpcdc/codec.rb", "grpcdc/dynamic.rb", "grpcdc/endpoint.rb", "grpcdc/loopback.rb", "grpcdc/server.rb", "grpcdc/wire_gen.rb"],
  php: ["grpcdc.php", "grpcdc/channel.php", "grpcdc/codec.php", "grpcdc/dynamic.php", "grpcdc/endpoint.php", "grpcdc/loopback.php", "grpcdc/server.php", "grpcdc/wire_gen.php"],
  scala: ["Channel.scala", "Codec.scala", "Dynamic.scala", "Endpoint.scala", "Futures.scala", "MemoryTransport.scala", "Server.scala", "Status.scala", "Transport.scala", "WireGen.scala"],
  // Facades wrap the JS implementation: the "runtime" is the JS
  // runtime plus its bridge (the page that hosts the wasm module
  // wires the generated facade to these).
  "wasm-go": ["wasm_bridge.js", "codec.js", "endpoint.js", "channel.js", "server.js", "loopback.js", "dynamic.js"],
  "wasm-zig": ["wasm_bridge.js", "codec.js", "endpoint.js", "channel.js", "server.js", "loopback.js", "dynamic.js"],
  "wasm-cpp": ["wasm_bridge.js", "codec.js", "endpoint.js", "channel.js", "server.js", "loopback.js", "dynamic.js"],
  "wasm-swift": ["wasm_bridge.js", "codec.js", "endpoint.js", "channel.js", "server.js", "loopback.js", "dynamic.js"],
  "wasm-kotlin": ["wasm_bridge.js", "codec.js", "endpoint.js", "channel.js", "server.js", "loopback.js", "dynamic.js"],
  "wasm-scala": ["wasm_bridge.js", "codec.js", "endpoint.js", "channel.js", "server.js", "loopback.js", "dynamic.js"],
};

// Generated message-type file per language (native plugin naming),
// for zip completeness checks. Languages absent here (rust, the
// wasm-* facades) ship stubs that use hand-written or JS-hosted
// message classes, so no message file is expected in the zip.
function upperFirst(b) {
  return b ? b[0].toUpperCase() + b.slice(1) : b;
}
function camelName(b) {
  return b.split("_").map(upperFirst).join("");
}
const MESSAGE_FILES = {
  js: (b) => `${b}_pb.js`,
  go: (b) => `${b}_pb.go`,
  python: (b) => `${b}_pb.py`,
  java: (b) => `${upperFirst(b)}Pb.java`,
  csharp: (b) => `${upperFirst(b)}Pb.cs`,
  cpp: (b) => `${b}_messages.hpp`,
  swift: (b) => `${upperFirst(b)}Messages.swift`,
  kotlin: (b) => `${upperFirst(b)}Messages.kt`,
  dart: (b) => `${b}_messages.dart`,
  zig: (b) => `${b}_messages.zig`,
  lua: (b) => `${b}_messages.lua`,
  ruby: (b) => `${b}_pb.rb`,
  php: (b) => `${b}_pb.php`,
  scala: (b) => `${camelName(b)}Messages.scala`,
};

// Everything a complete zip must contain: the schemas, generated
// stubs AND message types for every selected language, the bundled
// runtimes, README.md and manifest.json. Returns the missing paths
// (empty when the zip is complete).
function zipCompleteness(entries, langs, bases, messageBases) {
  const have = new Set(entries.map((e) => e.name));
  const missing = [];
  for (const base of bases) {
    if (!have.has("proto/" + base + ".proto")) missing.push("proto/" + base + ".proto");
  }
  for (const lang of langs) {
    if (![...have].some((n) => n.startsWith("gen/" + lang + "/"))) {
      missing.push("gen/" + lang + "/ (no generated code)");
    }
    const mf = MESSAGE_FILES[lang];
    if (mf) {
      for (const base of messageBases) {
        const p = "gen/" + lang + "/" + mf(base);
        if (!have.has(p)) missing.push(p);
      }
    }
    for (const r of RUNTIME_FILES[lang] || []) {
      const p = "runtime/" + lang + "/" + r;
      if (!have.has(p)) missing.push(p);
    }
  }
  if (!have.has("README.md")) missing.push("README.md");
  if (!have.has("manifest.json")) missing.push("manifest.json");
  return missing;
}

const files = new Map(); // name -> source text
let active = null;
let compileTimer = 0;
let lastSetBytes = null;
let errorMark = null; // {file, line} parsed from the compiler error

const $ = (id) => document.getElementById(id);
const editor = $("editor");
const statusEl = $("status");
const highlightEl = $("highlight");

// --- proto syntax highlighting (dependency-free overlay) --------

const PROTO_KEYWORDS = new Set([
  "syntax", "package", "import", "option", "service", "rpc", "returns",
  "stream", "message", "enum", "oneof", "map", "repeated", "optional",
  "required", "reserved", "to", "max", "extend", "extensions", "group",
]);

function escHtml(s) {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

function highlightProto(source, errLine) {
  const token = /(\/\/[^\n]*|\/\*[\s\S]*?\*\/)|("(?:[^"\\]|\\.)*")|\b([A-Za-z_][A-Za-z0-9_.]*)\b|\b(\d+(?:\.\d+)?)\b/g;
  let html = "";
  let last = 0;
  let line = 1;
  const crossLine = () => {
    if (line === errLine) html += "</span>";
    html += "\n";
    line++;
    if (line === errLine) html += '<span class="line-err">';
  };
  const emitText = (text, cls) => {
    const parts = text.split("\n");
    parts.forEach((part, i) => {
      if (i > 0) crossLine();
      html += cls ? '<span class="' + cls + '">' + escHtml(part) + "</span>" : escHtml(part);
    });
  };
  if (errLine === 1) html += '<span class="line-err">';
  for (const m of source.matchAll(token)) {
    emitText(source.slice(last, m.index), null);
    const [, comment, str, word, num] = m;
    const cls = comment ? "tok-com" : str ? "tok-str" : word ? (PROTO_KEYWORDS.has(word) ? "tok-kw" : /^[A-Z]/.test(word) ? "tok-type" : null) : num ? "tok-num" : null;
    emitText(m[0], cls);
    last = m.index + m[0].length;
  }
  emitText(source.slice(last), null);
  if (line === errLine) html += "</span>";
  return html + "\n";
}

function renderHighlight() {
  const errLine = errorMark && errorMark.file === active ? errorMark.line : null;
  highlightEl.innerHTML = highlightProto(editor.value, errLine);
  syncScroll();
}

function syncScroll() {
  const pre = highlightEl.parentElement;
  pre.scrollTop = editor.scrollTop;
  pre.scrollLeft = editor.scrollLeft;
}

editor.addEventListener("scroll", syncScroll);
editor.addEventListener("keydown", (event) => {
  if (event.key === "Tab") {
    event.preventDefault();
    editor.setRangeText("  ", editor.selectionStart, editor.selectionEnd, "end");
    editor.dispatchEvent(new Event("input"));
  }
});

function setStatus(text, cls) {
  statusEl.textContent = text;
  statusEl.className = "status " + (cls || "");
}

function renderTabs() {
  const tabs = $("tabs");
  tabs.textContent = "";
  for (const name of files.keys()) {
    const tab = document.createElement("button");
    tab.type = "button";
    tab.className = "tab" + (name === active ? " active" : "");
    tab.textContent = name;
    tab.addEventListener("click", () => {
      saveEditor();
      active = name;
      editor.value = files.get(name);
      renderTabs();
      renderHighlight();
    });
    tabs.appendChild(tab);
  }
}

function saveEditor() {
  if (active !== null && files.has(active)) files.set(active, editor.value);
}

function scheduleCompile() {
  clearTimeout(compileTimer);
  compileTimer = setTimeout(compile, 300);
}

function compile() {
  saveEditor();
  if (!window.__grpcdcCompile || files.size === 0) return;
  const names = [...files.keys()];
  const payload = JSON.stringify({ files: Object.fromEntries(files), entries: names });
  let out;
  try {
    out = JSON.parse(window.__grpcdcCompile(payload));
  } catch (err) {
    setStatus("compiler failed: " + err.message, "err");
    return;
  }
  if (!out.ok) {
    lastSetBytes = null;
    $("generate").disabled = true;
    setStatus(out.error, "err");
    const m = /^(.+?):(\d+):(\d+):/.exec(out.error);
    errorMark = m ? { file: m[1], line: Number(m[2]) } : null;
    renderHighlight();
    $("tree").textContent = "(no services — fix the schema errors)";
    return;
  }
  errorMark = null;
  renderHighlight();
  lastSetBytes = Uint8Array.from(atob(out.set), (c) => c.charCodeAt(0));
  const models = describeFiles(lastSetBytes, names);
  const lines = [];
  for (const f of models) {
    lines.push(f.name + (f.package ? "  (package " + f.package + ")" : ""));
    for (const s of f.services) {
      lines.push("  service " + s.fullName);
      for (const m of s.methods) lines.push("    " + m.name + "  " + m.kind + (m.deprecated ? "  [deprecated]" : ""));
    }
  }
  $("tree").textContent = lines.length ? lines.join("\n") : "(no services in schema)";
  $("generate").disabled = false;
  setStatus("compiled " + names.length + " file(s) OK", "ok");
}

$("upload").addEventListener("change", async (event) => {
  for (const file of event.target.files) {
    files.set(file.name, await file.text());
    if (active === null) active = file.name;
  }
  if (active !== null) editor.value = files.get(active);
  renderTabs();
  renderHighlight();
  scheduleCompile();
  event.target.value = "";
});

$("new-file").addEventListener("click", () => {
  const name = $("new-name").value.trim();
  if (!name || files.has(name)) return;
  files.set(name, 'syntax = "proto3";\n\n');
  active = name;
  editor.value = files.get(name);
  $("new-name").value = "";
  renderTabs();
  renderHighlight();
  scheduleCompile();
});

editor.addEventListener("input", () => {
  renderHighlight();
  scheduleCompile();
});

function renderLangs() {
  const box = $("langs");
  for (const [id, label] of ACTIVE_LANGS) {
    const wrap = document.createElement("label");
    const cb = document.createElement("input");
    cb.type = "checkbox";
    cb.checked = true;
    cb.dataset.lang = id;
    wrap.append(cb, " " + label);
    const param = document.createElement("input");
    param.className = "lang-param";
    param.dataset.param = id;
    param.placeholder = "plugin params (key=value,…)";
    wrap.appendChild(param);
    box.appendChild(wrap);
  }
  for (const label of PLANNED_LANGS) {
    const wrap = document.createElement("label");
    wrap.className = "disabled";
    const cb = document.createElement("input");
    cb.type = "checkbox";
    cb.disabled = true;
    wrap.append(cb, " " + label + " (soon)");
    wrap.title = "Browser generator not yet available for " + label;
    box.appendChild(wrap);
  }
}

function selectedLangs() {
  return [...$("langs").querySelectorAll("input[data-lang]:checked")].map((cb) => cb.dataset.lang);
}

// --- minimal store-only zip writer (no dependencies) -----------

const CRC_TABLE = (() => {
  const table = new Int32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    table[n] = c;
  }
  return table;
})();

function crc32(bytes) {
  let c = 0xffffffff;
  for (const b of bytes) c = CRC_TABLE[(c ^ b) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function makeZip(entries) {
  // entries: [{name, data: Uint8Array}]
  const enc = new TextEncoder();
  const chunks = [];
  const central = [];
  let offset = 0;
  const u16 = (v) => new Uint8Array([v & 0xff, (v >>> 8) & 0xff]);
  const u32 = (v) => new Uint8Array([v & 0xff, (v >>> 8) & 0xff, (v >>> 16) & 0xff, (v >>> 24) & 0xff]);
  const push = (arr) => { chunks.push(arr); offset += arr.length; };
  for (const entry of entries) {
    const nameBytes = enc.encode(entry.name);
    const crc = crc32(entry.data);
    const localOffset = offset;
    push(u32(0x04034b50)); push(u16(20)); push(u16(0x0800)); push(u16(0));
    push(u16(0)); push(u16(0x21)); // 1980-01-01, deterministic
    push(u32(crc)); push(u32(entry.data.length)); push(u32(entry.data.length));
    push(u16(nameBytes.length)); push(u16(0)); push(nameBytes); push(entry.data);
    central.push({ nameBytes, crc, size: entry.data.length, localOffset });
  }
  const centralStart = offset;
  for (const c of central) {
    push(u32(0x02014b50)); push(u16(20)); push(u16(20)); push(u16(0x0800)); push(u16(0));
    push(u16(0)); push(u16(0x21));
    push(u32(c.crc)); push(u32(c.size)); push(u32(c.size));
    push(u16(c.nameBytes.length)); push(u16(0)); push(u16(0)); push(u16(0)); push(u16(0));
    push(u32(0)); push(u32(c.localOffset)); push(c.nameBytes);
  }
  push(u32(0x06054b50)); push(u16(0)); push(u16(0));
  push(u16(central.length)); push(u16(central.length));
  push(u32(offset - centralStart)); push(u32(centralStart)); push(u16(0));
  return new Blob(chunks, { type: "application/zip" });
}

// --- generation -------------------------------------------------

async function fetchRuntime(lang) {
  const out = [];
  for (const name of RUNTIME_FILES[lang]) {
    const resp = await fetch("assets/runtime/" + lang + "/" + name);
    if (!resp.ok) throw new Error("missing runtime asset " + lang + "/" + name);
    out.push({ name: "runtime/" + lang + "/" + name, data: new Uint8Array(await resp.arrayBuffer()) });
  }
  return out;
}

function zipReadme(langs) {
  const lines = [
    "# Generated grpc-dc stubs",
    "",
    "Generated in the browser by the grpc-dc web app (protocompile + the",
    "Racket-metaprogrammed generators; byte-identical to the native",
    "protoc-gen-grpc-dc-* plugins). Layout:",
    "",
    "- proto/    the schemas, as compiled",
    "- gen/      generated client/server stubs per language",
    "- runtime/  the dependency-free grpc-dc runtime per language",
    "",
    "Every language also gets generated, dependency-free message",
    "types next to its stubs (gen/js/<base>_pb.js, gen/python/",
    "<base>_pb.py, gen/go/<base>_pb.go, gen/cpp/<base>_messages.hpp,",
    "and the <Base>Pb / <Base>Messages files of the JVM-family,",
    "Dart, Zig, Lua, Ruby, PHP and Scala generators), so the zip",
    "runs end-to-end as-is. manifest.json lists every file in the",
    "zip and reports anything expected but missing under \"missing\"",
    "",
    "Languages in this zip: " + langs.join(", ") + ".",
    "",
  ];
  return lines.join("\n");
}

function langParams() {
  const params = new Map();
  for (const input of $("langs").querySelectorAll("input[data-param]")) {
    if (input.value.trim()) params.set(input.dataset.param, input.value.trim());
  }
  return params;
}

// --- Racket/Wasm plugin runner ------------------------------------
// The real protoc plugins (assembled bin/protoc-gen-grpc-dc-*)
// execute inside a Racket/Wasm runtime in a Web Worker
// (webapp/racket/runner.rkt). One boot per page; each Generate
// sends one framed job batch. If the runtime cannot start
// (no SharedArrayBuffer, assets missing), generation falls back
// to the built-in JS generators; ?gen=js forces that path.
const RUNNER_LANGS = ["js", "go", "python", "rust", "java", "csharp", "cpp", "swift", "kotlin", "dart", "zig", "lua", "ruby", "php", "scala", "wasm-go", "wasm-zig", "wasm-cpp", "wasm-swift", "wasm-kotlin", "wasm-scala"];
let runnerState = null;

function runnerRingDrain(state) {
  const H = state.heap;
  const tail = Atomics.load(H, state.outBase + 1);
  if (tail === state.outHead) return;
  const chunk = new Uint8Array(tail - state.outHead);
  for (let i = 0; state.outHead !== tail; state.outHead++, i++) {
    chunk[i] = H[state.outBase + 2 + (state.outHead % state.outCap)] & 0xff;
  }
  Atomics.store(H, state.outBase + 0, state.outHead);
  if (!chunk.length) return;
  const prev = state.buf;
  state.buf = new Uint8Array(prev.length + chunk.length);
  state.buf.set(prev);
  state.buf.set(chunk, prev.length);
  runnerParse(state);
}

function runnerParse(state) {
  for (;;) {
    if (state.expectBytes !== null) {
      if (state.buf.length < state.expectBytes) return;
      const body = state.buf.slice(0, state.expectBytes);
      state.buf = state.buf.slice(state.expectBytes);
      const frame = state.expectFrame;
      state.expectBytes = null;
      state.expectFrame = null;
      state.onFrame(frame.lang, frame.err ? new Error(new TextDecoder().decode(body)) : body);
      continue;
    }
    const nl = state.buf.indexOf(10);
    if (nl < 0) return;
    const line = new TextDecoder().decode(state.buf.slice(0, nl));
    state.buf = state.buf.slice(nl + 1);
    if (line === "GRPCDC-RUNNER-READY") {
      state.onReady();
    } else {
      const m = line.match(/^GRPCDC\/1 (\S+) (\d+)$/) || line.match(/^GRPCDC-ERR (\S+) (\d+)$/);
      if (!m) throw new Error("bad runner frame: " + line.slice(0, 80));
      state.expectFrame = { lang: m[1], err: line.startsWith("GRPCDC-ERR") };
      state.expectBytes = Number(m[2]);
    }
  }
}

async function ensureRunner() {
  if (runnerState) return runnerState.ready;
  if (typeof SharedArrayBuffer === "undefined") throw new Error("SharedArrayBuffer unavailable (serve with COOP/COEP headers)");
  const state = {
    heap: null, outBase: 0, outCap: 0, outHead: 0, buf: new Uint8Array(0),
    expectBytes: null, expectFrame: null, batch: null, poll: 0,
    ready: null, onReady: null, onFrame: null,
  };
  runnerState = state;
  state.ready = (async () => {
    const texts = new Map();
    const fetches = [["/tmp/main.rkt", "assets/racket/runner.rkt"]];
    for (const lang of RUNNER_LANGS) fetches.push([`/tmp/plugins/${lang}.rkt`, `assets/plugins/${lang}.rkt`]);
    await Promise.all(fetches.map(async ([dest, url]) => {
      const resp = await fetch(url);
      if (!resp.ok) throw new Error("missing runner asset " + url);
      texts.set(dest, await resp.text());
    }));
    const files = {};
    for (const [dest, text] of texts) files[dest] = text;
    const readyPromise = new Promise((resolve) => { state.onReady = resolve; });
    const worker = new Worker("assets/racket/shell-worker.js");
    state.worker = worker;
    worker.onmessage = (event) => {
      const msg = event.data;
      if (msg.type === "ready") {
        state.heap = new Int32Array(msg.heap);
        state.inBase = msg.inBase;
        state.inCap = msg.inCap;
        state.outBase = msg.outBase;
        state.outCap = msg.outCap;
        state.outHead = Atomics.load(state.heap, state.outBase + 0);
        state.poll = setInterval(() => runnerRingDrain(state), 16);
      } else if (msg.type === "fs-error") {
        throw new Error("runner fs error at " + msg.path + ": " + msg.error);
      } else if (msg.type === "exit") {
        if (state.batch) state.batch.reject(new Error("racket runtime exited (code " + (msg.code | 0) + ")"));
      }
    };
    worker.postMessage({ type: "init", argv: ["-u", "/tmp/main.rkt"], files });
    await readyPromise;
  })();
  return state.ready;
}

async function runnerGenerate(jobs) {
  await ensureRunner();
  const state = runnerState;
  return new Promise((resolve, reject) => {
    const results = new Map();
    let remaining = jobs.length;
    state.batch = { reject };
    state.onFrame = (lang, body) => {
      if (body instanceof Error) { state.batch = null; reject(new Error(lang + ": " + body.message)); return; }
      try {
        results.set(lang, parsePluginResponse(body));
      } catch (e) {
        state.batch = null;
        reject(new Error(lang + ": " + e.message));
        return;
      }
      if (--remaining === 0) { state.batch = null; resolve(results); }
    };
    runnerWriteInput(state, JSON.stringify({ jobs: jobs.map((j) => ({ lang: j.lang, requestB64: j.requestB64 })) }) + "\n");
  });
}

function bytesToB64(bytes) {
  let s = "";
  for (let i = 0; i < bytes.length; i += 8192) {
    s += String.fromCharCode(...bytes.subarray(i, i + 8192));
  }
  return btoa(s);
}

function runnerWriteInput(state, text) {
  // The page side of the stdin ring (same protocol as ide.js).
  const H = state.heap;
  const bytes = new TextEncoder().encode(text);
  let tail = Atomics.load(H, state.inBase + 1);
  for (let i = 0; i < bytes.length; i++) {
    H[state.inBase + 2 + (tail % state.inCap)] = bytes[i];
    tail++;
  }
  Atomics.store(H, state.inBase + 1, tail);
  Atomics.notify(H, state.inBase + 1);
}

$("generate").addEventListener("click", async () => {
  if (!lastSetBytes) return;
  saveEditor();
  const langs = selectedLangs();
  if (!langs.length) return;
  const params = langParams();
  const enc = new TextEncoder();
  const entries = [];
  const generated = [];
  const names = [...files.keys()];
  for (const name of names) entries.push({ name: "proto/" + name, data: enc.encode(files.get(name)) });
  const useRacket = new URLSearchParams(location.search).get("gen") !== "js";
  let generatedVia = "built-in generators";
  if (useRacket) {
    try {
      setStatus("starting Racket runtime (first use loads ~84MB of local assets)...", "");
      const jobs = langs.map((lang) => ({
        lang,
        requestB64: bytesToB64(buildPluginRequest(lastSetBytes, names, params.get(lang) || "")),
      }));
      const t0 = performance.now();
      const results = await runnerGenerate(jobs);
      for (const lang of langs) {
        for (const f of results.get(lang) || []) {
          const entry = { name: "gen/" + lang + "/" + f.name, data: f.content };
          entries.push(entry);
          generated.push(entry);
        }
      }
      generatedVia = "Racket plugins in-browser (" + (performance.now() - t0).toFixed(0) + "ms)";
    } catch (e) {
      setStatus("Racket runtime unavailable (" + e.message + "); falling back to built-in generators", "err");
    }
  }
  if (!generated.length) {
    for (const lang of langs) {
      for (const f of generateFiles(lang, lastSetBytes, names, params.get(lang) || "")) {
        const entry = { name: "gen/" + lang + "/" + f.name, data: enc.encode(f.content) };
        entries.push(entry);
        generated.push(entry);
      }
    }
  } else {
    setStatus("generated via " + generatedVia, "ok");
  }
  for (const lang of langs) {
    entries.push(...(await fetchRuntime(lang)));
  }
  // The JS-family runtimes import ../wire_gen.js, which resolves to
  // runtime/wire_gen.js in the zip layout; bundle it once.
  if (langs.some((l) => (RUNTIME_FILES[l] || []).includes("codec.js"))) {
    const resp = await fetch("assets/runtime/wire_gen.js");
    if (!resp.ok) throw new Error("missing runtime asset wire_gen.js");
    entries.push({ name: "runtime/wire_gen.js", data: new Uint8Array(await resp.arrayBuffer()) });
  }
  window.__generatedVia = generatedVia;
  renderResults(generated);
  previewJsBundle(generated);
  entries.push({ name: "README.md", data: enc.encode(zipReadme(langs)) });
  const bases = names.map((n) => n.split("/").pop().replace(/\.proto$/, ""));
  const messageBases = bases.filter((b, i) => /\b(message|enum)\s/.test(files.get(names[i])));
  const missing = zipCompleteness(
    [...entries, { name: "manifest.json", data: new Uint8Array(0) }],
    langs, bases, messageBases);
  window.__zipMissing = missing;
  entries.push({
    name: "manifest.json",
    data: enc.encode(JSON.stringify({
      app: "grpc-dc-webapp",
      generatedVia,
      languages: langs,
      protos: names,
      files: [...entries.map((e) => e.name), "manifest.json"],
      missing,
    }, null, 2) + "\n"),
  });
  const blob = makeZip(entries);
  const a = document.createElement("a");
  a.href = URL.createObjectURL(blob);
  a.download = "grpcdc-stubs.zip";
  a.click();
  setTimeout(() => URL.revokeObjectURL(a.href), 5000);
  if (missing.length) {
    setStatus("generated grpcdc-stubs.zip (" + entries.length + " files); missing: " + missing.join(", "), "err");
  } else {
    setStatus("generated grpcdc-stubs.zip (" + entries.length + " files)", "ok");
  }
});

// --- in-browser preview of the generated JS bundle -----------------
// Imports the generated gen/js/*_pb.js modules right here in the
// page (relative imports rewritten to Blob URLs) and smoke-tests
// every exported message class: a default instance must survive an
// encode/decode/encode round-trip byte-identically. Proves the
// downloaded bundle loads and runs as-is, before unzipping.
async function previewJsBundle(generated) {
  const box = $("preview");
  if (!box) return;
  const jsEntries = generated.filter((e) => e.name.startsWith("gen/js/") && e.name.endsWith(".js"));
  const pbEntries = jsEntries.filter((e) => e.name.endsWith("_pb.js"));
  if (!pbEntries.length) {
    box.textContent = "(no JavaScript message bundle in this generation)";
    window.__jsPreview = { files: 0, classes: 0, ok: false };
    return;
  }
  box.textContent = "loading generated JS bundle…";
  const dec = new TextDecoder();
  const urls = new Map();
  for (const e of jsEntries) {
    urls.set(e.name.split("/").pop(), URL.createObjectURL(new Blob([e.data], { type: "text/javascript" })));
  }
  const lines = [];
  let classCount = 0;
  try {
    for (const e of pbEntries) {
      let src = dec.decode(e.data);
      src = src.replace(/from\s+"(\.\/[^"]+)"/g, (m, rel) => {
        const target = urls.get(rel.slice(2));
        return target ? `from "${target}"` : m;
      });
      const url = URL.createObjectURL(new Blob([src], { type: "text/javascript" }));
      const mod = await import(url);
      URL.revokeObjectURL(url);
      for (const [name, value] of Object.entries(mod)) {
        if (typeof value === "function" && typeof value.encode === "function" && typeof value.decode === "function") {
          const bytes = value.encode(new value());
          const again = value.encode(value.decode(bytes));
          const same = bytes.length === again.length && bytes.every((b, i) => b === again[i]);
          if (!same) throw new Error(name + ": round-trip mismatch");
          classCount++;
          lines.push(`${e.name.split("/").pop()}: ${name} round-trip OK (${bytes.length} bytes)`);
        }
      }
    }
    box.textContent = "";
    const head = document.createElement("div");
    head.textContent = `preview: ${pbEntries.length} message file(s), ${classCount} message class(es) loaded and round-tripped in this page`;
    box.appendChild(head);
    for (const line of lines) {
      const div = document.createElement("div");
      div.textContent = line;
      box.appendChild(div);
    }
    const pre = document.createElement("pre");
    pre.className = "preview-source";
    pre.textContent = dec.decode(pbEntries[0].data);
    box.appendChild(pre);
    window.__jsPreview = { files: pbEntries.length, classes: classCount, ok: true };
  } catch (err) {
    box.textContent = "preview failed: " + err.message;
    window.__jsPreview = { files: pbEntries.length, classes: classCount, ok: false };
  } finally {
    for (const u of urls.values()) URL.revokeObjectURL(u);
  }
}

function renderResults(generated) {
  const box = $("results");
  box.textContent = "";
  if (!generated.length) return;
  const head = document.createElement("div");
  head.textContent = "generated files (click to download individually):";
  box.appendChild(head);
  for (const entry of generated) {
    const a = document.createElement("a");
    a.href = "#";
    a.textContent = entry.name + " (" + entry.data.length + " bytes)";
    a.addEventListener("click", (event) => {
      event.preventDefault();
      const blob = new Blob([entry.data], { type: "text/plain" });
      const link = document.createElement("a");
      link.href = URL.createObjectURL(blob);
      link.download = entry.name.split("/").pop();
      link.click();
      setTimeout(() => URL.revokeObjectURL(link.href), 5000);
    });
    box.appendChild(a);
  }
}

// --- boot --------------------------------------------------------

async function boot() {
  renderLangs();
  const go = new Go();
  let instance;
  try {
    ({ instance } = await WebAssembly.instantiateStreaming(fetch("assets/protocompile.wasm"), go.importObject));
  } catch {
    // Static servers without the application/wasm MIME type land here.
    const bytes = await (await fetch("assets/protocompile.wasm")).arrayBuffer();
    ({ instance } = await WebAssembly.instantiate(bytes, go.importObject));
  }
  go.run(instance);
  try {
    const sample = await (await fetch("assets/echo.proto")).text();
    files.set("echo.proto", sample);
    active = "echo.proto";
    editor.value = sample;
  } catch {
    // No sample bundled; start empty.
  }
  renderTabs();
  compile();
  window.__webappReady = true;
}

boot();
