// BDD schema scenarios: golden protoc bytes, generated classes.
// The case table (bdd_schemas.generated.js) is generated from
// the schema scenarios: protoc's own --encode output over
// webapp/testdata/{kitchen,features}.proto. Each case decodes
// with the generated classes and re-encodes byte-identically.

import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { promisify } from "node:util";
import test from "node:test";

import { BDD_SCHEMAS } from "./bdd_schemas.generated.js";

const run = promisify(execFile);
const ROOT = fileURLToPath(new URL("../..", import.meta.url));
const TESTDATA = join(ROOT, "webapp", "testdata");

test("BDD schema scenarios (protoc golden bytes)", async () => {
  const out = await mkdtemp(join(tmpdir(), "grpcdc-js-schemas-"));
  const plugin = join(ROOT, "bin", "protoc-gen-grpc-dc-js");
  await run("protoc", [
    `--plugin=protoc-gen-grpc-dc-js=${plugin}`,
    `--grpc-dc-js_out=${out}`,
    "-I", TESTDATA, "common.proto", "kitchen.proto", "features.proto",
  ], { cwd: TESTDATA });

  const kitchenPb = await import(pathToFileURL(join(out, "kitchen_pb.js")));
  const featuresPb = await import(pathToFileURL(join(out, "features_pb.js")));
  const classes = { kitchen: kitchenPb.Kitchen, outer: featuresPb.Outer };

  for (const c of BDD_SCHEMAS) {
    const cls = classes[c.message];
    assert.ok(cls, `${c.name}: no class for ${c.message}`);
    const decoded = cls.decode(Buffer.from(c.input, "hex"));
    assert.equal(Buffer.from(cls.encode(decoded)).toString("hex"), c.expect, c.name);
  }
});
