#!/usr/bin/env node
// protoc plugin for grpc-over-datachannels — Node edition.
//
// Speaks the protoc plugin protocol on stdin/stdout and emits
// exactly what the private Racket plugins emit, by driving the
// same generated-JS emitters the browser app uses (./gen/
// generators.js; byte-identical output is parity-tested against
// the Racket plugins). No Racket required, no dependencies.
//
// Install under one name per language on PATH, e.g.:
//   ln -s "$PWD/protoc-gen-grpc-dc.mjs" /usr/local/bin/protoc-gen-grpc-dc-rust
//   protoc --plugin=protoc-gen-grpc-dc-rust=protoc-gen-grpc-dc-rust \
//          --grpc-dc-rust_out=out -I . echo.proto
// The language comes from the binary name (protoc-gen-grpc-dc-
// <lang>); override with GRPC_DC_LANG or `--lang <lang>`.
// Languages: see GENERATOR_LANGUAGES in ./gen/generators.js.

import { readFileSync } from "node:fs";
import { basename } from "node:path";
import { generateFiles } from "./gen/generators.js";

// ---------------------------------------------------------------------------
// Minimal protobuf envelope codec (CodeGeneratorRequest /
// CodeGeneratorResponse). FileDescriptorProto entries pass
// through as raw bytes, so no descriptor schema is needed here.
// ---------------------------------------------------------------------------

function readVarint(buf, pos) {
  let result = 0n;
  let shift = 0n;
  for (;;) {
    const b = buf[pos++];
    result |= BigInt(b & 0x7f) << shift;
    if ((b & 0x80) === 0) return [result, pos];
    shift += 7n;
  }
}

function* fields(buf) {
  let pos = 0;
  while (pos < buf.length) {
    const [tag, p1] = readVarint(buf, pos);
    pos = p1;
    const num = Number(tag >> 3n);
    const wire = Number(tag & 7n);
    if (wire === 0) {
      const [, p2] = readVarint(buf, pos);
      pos = p2;
    } else if (wire === 2) {
      const [len, p2] = readVarint(buf, pos);
      const n = Number(len);
      yield [num, buf.subarray(p2, p2 + n)];
      pos = p2 + n;
    } else if (wire === 5) {
      pos += 4;
    } else if (wire === 1) {
      pos += 8;
    } else {
      throw new Error("unsupported wire type " + wire);
    }
  }
}

function varintBytes(value) {
  let v = BigInt(value);
  const out = [];
  do {
    let b = Number(v & 0x7fn);
    v >>= 7n;
    if (v) b |= 0x80;
    out.push(b);
  } while (v);
  return out;
}

const bytesField = (num, payload) => [
  ...varintBytes((BigInt(num) << 3n) | 2n),
  ...varintBytes(payload.length),
  ...payload,
];
const varintField = (num, value) => [
  ...varintBytes((BigInt(num) << 3n) | 0n),
  ...varintBytes(value),
];

function parseRequest(buf) {
  const filesToGenerate = [];
  const protoFiles = [];
  let parameter = "";
  const dec = new TextDecoder();
  for (const [num, payload] of fields(buf)) {
    if (num === 1) filesToGenerate.push(dec.decode(payload));
    else if (num === 2) parameter = dec.decode(payload);
    else if (num === 15) protoFiles.push(payload);
  }
  // Re-wrap the raw FileDescriptorProtos as a FileDescriptorSet.
  const set = [];
  for (const raw of protoFiles) set.push(...bytesField(1, raw));
  return { filesToGenerate, parameter, setBytes: new Uint8Array(set) };
}

function encodeResponse(files) {
  const enc = new TextEncoder();
  const out = [...varintField(2, 1)]; // FEATURE_PROTO3_OPTIONAL
  for (const f of files) {
    const content = typeof f.content === "string" ? enc.encode(f.content) : f.content;
    const entry = [...bytesField(1, enc.encode(f.name)), ...bytesField(15, content)];
    out.push(...bytesField(15, new Uint8Array(entry)));
  }
  return Buffer.from(out);
}

function encodeError(message) {
  const enc = new TextEncoder();
  return Buffer.from(bytesField(1, enc.encode(message)));
}

// ---------------------------------------------------------------------------
// Language selection + main.
// ---------------------------------------------------------------------------

function selectedLang() {
  const args = process.argv.slice(2);
  const ai = args.indexOf("--lang");
  if (ai >= 0 && args[ai + 1]) return args[ai + 1];
  if (process.env.GRPC_DC_LANG) return process.env.GRPC_DC_LANG;
  const base = basename(process.argv[1] || "");
  const prefix = "protoc-gen-grpc-dc-";
  if (base.startsWith(prefix)) return base.slice(prefix.length);
  return null;
}

function main() {
  const lang = selectedLang();
  if (!lang) {
    process.stderr.write(
      "protoc-gen-grpc-dc: no language selected (name the binary " +
        "protoc-gen-grpc-dc-<lang>, or set GRPC_DC_LANG, or pass --lang)\n",
    );
    process.exit(1);
  }
  const request = parseRequest(readFileSync(0));
  try {
    const files = generateFiles(lang, request.setBytes, request.filesToGenerate, request.parameter);
    process.stdout.write(encodeResponse(files));
  } catch (e) {
    process.stdout.write(encodeError(String((e && e.message) || e)));
  }
}

main();
