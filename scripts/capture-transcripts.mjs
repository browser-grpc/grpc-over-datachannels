// Capture per-language example transcripts for the public
// gallery: build each language's stdio Echo harnesses (same
// commands as js/test/interop-matrix.mjs, whose LANGS table
// this script extracts so the two cannot drift), run the
// client against the server over a raw byte pump, and record
// the client's stderr (the canonical call-shape lines) to
// webapp/assets/transcripts/<lang>.txt.
//
// Run via `make transcripts` (a release-public prerequisite).

import { execSync, spawn } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = fileURLToPath(new URL("..", import.meta.url));
const OUT = join(ROOT, "webapp/assets/transcripts");

// Extract the LANGS literal from the interop matrix source.
const src = readFileSync(join(ROOT, "js/test/interop-matrix.mjs"), "utf8");
const start = src.indexOf("const LANGS = {");
if (start < 0) throw new Error("LANGS table not found");
let depth = 0;
let end = -1;
for (let i = src.indexOf("{", start); i < src.length; i++) {
  if (src[i] === "{") depth++;
  else if (src[i] === "}" && --depth === 0) { end = i + 1; break; }
}
// Toolchain variables the LANGS literal interpolates (same
// names/defaults as the matrix itself).
const CXX = process.env.CXX || "g++";
const DART = process.env.DART || "dart";
const KOTLINC = process.env.KOTLINC || "kotlinc";
const SCALAC = process.env.SCALAC || "scalac";
const SWIFTC = process.env.SWIFTC || "swiftc";
const LUA = process.env.LUA || "lua";
const RUBY = process.env.RUBY || "ruby";
const PHP = process.env.PHP || "php";
const SCALA3_HOME = process.env.SCALA3_HOME || "/usr/local/scala3";
const SCALA_LIBS =
  process.env.SCALA_LIBS ||
  `${SCALA3_HOME}/lib/scala3-library_3-3.3.6.jar:${SCALA3_HOME}/lib/scala-library-2.13.16.jar`;
const LANGS = eval("(" + src.slice(src.indexOf("{", start), end) + ")");

const env = {
  ...process.env,
  SCALA3_HOME: process.env.SCALA3_HOME || "/usr/local/scala3",
};

function runPair(lang) {
  return new Promise((resolve, reject) => {
    const spec = LANGS[lang];
    const server = spawn(spec.server[0], spec.server.slice(1), { cwd: ROOT, env });
    const client = spawn(spec.client[0], spec.client.slice(1), { cwd: ROOT, env });
    let stderr = "";
    client.stderr.on("data", (d) => { stderr += d; });
    server.stderr.on("data", () => {});
    client.stdout.pipe(server.stdin);
    server.stdout.pipe(client.stdin);
    const timer = setTimeout(() => reject(new Error(lang + ": pair timed out")), 60000);
    client.on("exit", (code) => {
      clearTimeout(timer);
      server.kill();
      // Mirror the interop matrix: success is the canonical
      // call-shape lines on the client's stderr (a client may
      // still die by SIGPIPE tearing the pump down).
      const lines = stderr.split("\n").filter((l) => l.trim());
      const canonical = ["unary=", "server_stream=", "client_stream=", "bidi="];
      const seen = canonical.filter((p) => lines.some((l) => l.startsWith(p)));
      if (seen.length === canonical.length) resolve(stderr.trim());
      else reject(new Error(lang + ": exit " + code + ", saw " + seen.join(",") + "\n" + stderr));
    });
    server.on("error", reject);
    client.on("error", reject);
  });
}

mkdirSync(OUT, { recursive: true });
for (const lang of Object.keys(LANGS)) {
  const spec = LANGS[lang];
  if (spec.build) {
    console.log("transcripts: building", lang);
    execSync(spec.build, { cwd: ROOT, env, stdio: "inherit" });
  }
  const text = await runPair(lang);
  writeFileSync(join(OUT, lang + ".txt"), text + "\n");
  console.log("transcripts:", lang, "ok");
}
