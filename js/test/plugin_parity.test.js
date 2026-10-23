// The Node protoc plugin shim (webapp/protoc-gen-grpc-dc.mjs,
// driving the generated-JS emitters) must emit byte-identical
// output to the Racket plugins (bin/protoc-gen-grpc-dc-*) for
// every generator language, through a real protoc invocation.
// This keeps the private Racket code unpublished without a
// second emitter implementation: the shim is the public plugin.

import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, symlinkSync, readdirSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const SHIM = join(ROOT, "webapp", "protoc-gen-grpc-dc.mjs");
const LANGS = [
  "js", "c", "go", "python", "rust", "java", "csharp", "cpp",
  "swift", "kotlin", "dart", "zig", "lua", "ruby", "php",
  "scala", "wasm-go", "wasm-zig", "wasm-cpp", "wasm-swift",
  "wasm-kotlin", "wasm-scala",
];
const PROTOS = [
  "webapp/testdata/kitchen.proto",
  "webapp/testdata/features.proto",
  "webapp/testdata/common.proto",
  "webapp/testdata/shop.proto",
  "proto/echo.proto",
];

function tree(dir, prefix = "") {
  const out = new Map();
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const rel = prefix ? `${prefix}/${entry.name}` : entry.name;
    if (entry.isDirectory()) {
      for (const [k, v] of tree(join(dir, entry.name), rel)) out.set(k, v);
    } else {
      out.set(rel, readFileSync(join(dir, entry.name)));
    }
  }
  return out;
}

test("node plugin shim matches racket plugins byte-for-byte", () => {
  const work = mkdtempSync(join(tmpdir(), "grpc-dc-plugin-parity-"));
  try {
    const binDir = join(work, "bin");
    mkdirSync(binDir);
    for (const lang of LANGS) {
      const link = join(binDir, `protoc-gen-grpc-dc-${lang}`);
      symlinkSync(SHIM, link);
      const racketOut = join(work, "racket", lang);
      const nodeOut = join(work, "node", lang);
      mkdirSync(racketOut, { recursive: true });
      mkdirSync(nodeOut, { recursive: true });
      // The Racket plugin is invoked under its real name by
      // protoc; the shim ignores the name protoc used and takes
      // the language from its own argv[1] symlink name, so run
      // protoc once per plugin kind with matching -out params.
      execFileSync(
        "protoc",
        [
          `--plugin=protoc-gen-grpc-dc-${lang}=${join(ROOT, "bin", `protoc-gen-grpc-dc-${lang}`)}`,
          `--grpc-dc-${lang}_out=${racketOut}`,
          "-I", "webapp/testdata", "-I", "proto", ...PROTOS,
        ],
        { cwd: ROOT, stdio: ["ignore", "pipe", "pipe"] },
      );
      execFileSync(
        "protoc",
        [
          `--plugin=protoc-gen-grpc-dc-${lang}=${link}`,
          `--grpc-dc-${lang}_out=${nodeOut}`,
          "-I", "webapp/testdata", "-I", "proto", ...PROTOS,
        ],
        { cwd: ROOT, stdio: ["ignore", "pipe", "pipe"] },
      );
      const a = tree(racketOut);
      const b = tree(nodeOut);
      assert.deepEqual([...b.keys()].sort(), [...a.keys()].sort(), `${lang}: file sets differ`);
      for (const [name, bytes] of a) {
        assert.ok(bytes.equals(b.get(name)), `${lang}: ${name} differs`);
      }
    }
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
});
