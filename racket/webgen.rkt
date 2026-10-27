#lang racket

;;; webgen.rkt — emits webapp/gen/generators.js, the browser
;;; generators for the fully client-side web app.
;;;
;;; The native protoc plugins cannot run in a browser (they are
;;; Racket programs fed CodeGeneratorRequest bytes by protoc), so
;;; metagen also stamps the same generation logic into a
;;; self-contained ES module: given FileDescriptorSet bytes from
;;; the in-page protocompile WASM compiler, it emits exactly the
;;; files protoc-gen-grpc-dc-{js,go,python} would. The descriptor
;;; walk mirrors desc.rkt and the emitters mirror
;;; template-{js,go,python}.rkt; byte parity with the native
;;; plugins is enforced by the webapp parity test. The method
;;; rename-alias table is serialized from spec.rkt below, so the
;;; browser generators can never disagree with the plugins about
;;; aliases. The Rust enum emission shape (rust-enum-shape in
;;; spec.rkt) is serialized the same way as RP_ENUM_SHAPE, so
;;; the browser Rust emitter shares that static text with
;;; template-rust.rkt instead of mirroring it.

(require "spec.rkt" "segments.rkt" json)

(provide emit-web-generators)

(define (alias-table-json)
  (jsexpr->string
   (map (lambda (a)
          (map (lambda (x) (if (symbol? x) (symbol->string x) x)) a))
        method-alias-table)))

;; The Rust enum emission shape, serialized from the shared
;; table in spec.rkt (rust-enum-shape) so the browser Rust
;; emitter can never drift from the native template.
(define (rust-enum-shape-json)
  (jsexpr->string
   (for/hash ([entry (in-list rust-enum-shape)])
     (values (car entry) (cdr entry)))))

;; The Go module path, serialized from spec.rkt so the browser
;; Go emitter imports the same module the native template does.
(define (go-module-path-json)
  (jsexpr->string go-module-path))

;; The protobuf scalar wire tables, serialized from spec.rkt
;; (varint-scalar-types, fixed-scalar-tables) so every browser
;; emitter reads the same numbers the native templates derive
;; from. JS shape per language: {type-number: [size, name]}.
(define (fixed-tables-json)
  (jsexpr->string
   (for/hash ([row (in-list fixed-scalar-tables)])
     (values (car row)
             (for/hash ([e (in-list (cdr row))])
               (values (string->symbol (number->string (first e)))
                       (list (second e) (third e))))))))

(define (varint-types-json)
  (jsexpr->string varint-scalar-types))

;; The scalar type tables, serialized from spec.rkt
;; (scalar-type-tables): per language {default, types} where
;; types maps a field-type number to the leaf payload (a type
;; name, or an array such as [primitive, boxed, default]).
;; Emitter segment programs, serialized from segments.rkt:
;; the same data the native templates interpret, so converted
;; emitter functions exist exactly once (option 1 rollout).
(define (datum->jsexpr v)
  (cond [(symbol? v) (symbol->string v)]
        [(pair? v) (map datum->jsexpr v)]
        [else v]))

(define (segment-programs-json)
  (jsexpr->string
   (for/hash ([(k v) (in-hash segment-programs)])
     (values k (datum->jsexpr v)))))

(define (scalar-tables-json)
  (string-join
   (for/list ([row (in-list scalar-type-tables)])
     (format "\"~a\":{\"default\":~a,\"types\":~a}"
             (car row)
             (let ([d (cadr row)]) (if (eq? d #f) "null" (jsexpr->string d)))
             (jsexpr->string
              (for/hash ([e (in-list (cddr row))])
                (values (string->symbol (number->string (car e)))
                        (cdr e))))))
   ","
   #:before-first "{" #:after-last "}"))

(define js-part-1 #<<JS
// Browser generators for the grpc-dc web app: given the
// FileDescriptorSet bytes produced by the in-page protocompile
// WASM compiler (webapp/compiler), emit the same stub files the
// native protoc-gen-grpc-dc-{js,go,python} plugins emit. The
// descriptor walk mirrors the native descriptor model and the emitters mirror the native ones
// the native plugins is enforced by the webapp parity test
// (browser-test/webapp_parity.test.mjs). Do not hand-edit here:
// change the native templates and regenerate.

const METHOD_ALIASES = 
JS
)

(define js-part-2 #<<JS
;

// ---------------------------------------------------------------------------
// Minimal protobuf reader for descriptor.proto (field-number keyed).
// ---------------------------------------------------------------------------

function pbParse(bytes) {
  const fields = new Map();
  let i = 0;
  const readVarint = () => {
    let v = 0n;
    let shift = 0n;
    for (;;) {
      const b = bytes[i++];
      v |= BigInt(b & 0x7f) << shift;
      if (!(b & 0x80)) break;
      shift += 7n;
    }
    return v;
  };
  while (i < bytes.length) {
    const tag = readVarint();
    const num = Number(tag >> 3n);
    const wire = Number(tag & 7n);
    let entry;
    if (wire === 0) entry = { wire, varint: readVarint() };
    else if (wire === 2) {
      const len = Number(readVarint());
      entry = { wire, bytes: bytes.subarray(i, i + len) };
      i += len;
    } else if (wire === 1) { entry = { wire, bytes: bytes.subarray(i, i + 8) }; i += 8; }
    else if (wire === 5) { entry = { wire, bytes: bytes.subarray(i, i + 4) }; i += 4; }
    else throw new Error('unsupported wire type ' + wire);
    if (!fields.has(num)) fields.set(num, []);
    fields.get(num).push(entry);
  }
  return fields;
}

function getAllBytes(fields, num) {
  return (fields.get(num) || []).filter((e) => e.wire === 2).map((e) => e.bytes);
}

function firstBytes(fields, num) {
  const all = getAllBytes(fields, num);
  return all.length ? all[0] : null;
}

const utf8 = new TextDecoder();

function getString(fields, num, dflt) {
  const raw = firstBytes(fields, num);
  return raw === null ? (dflt || '') : utf8.decode(raw);
}

function getBool(fields, num) {
  const all = fields.get(num) || [];
  return all.some((e) => e.wire === 0 && e.varint !== 0n);
}

function getInt(fields, num, dflt) {
  const all = fields.get(num) || [];
  for (const e of all) if (e.wire === 0) return Number(e.varint);
  return dflt || 0;
}

function getStrings(fields, num) {
  return getAllBytes(fields, num).map((b) => utf8.decode(b));
}

// ---------------------------------------------------------------------------
// Descriptor model (mirrors the native descriptor model).
// ---------------------------------------------------------------------------

function simpleTypeName(full) {
  const parts = full.replace(/^\.+|\.+$/g, '').split('.');
  return parts[parts.length - 1];
}

function methodPath(pkg, service, method) {
  return pkg ? '/' + pkg + '.' + service + '/' + method : '/' + service + '/' + method;
}

function streamingKind(client, server) {
  return client && server ? 'bidi' : client ? 'client-streaming' : server ? 'server-streaming' : 'unary';
}

function optionsDeprecated(fields, optionsField) {
  const raw = firstBytes(fields, optionsField);
  return raw !== null && getBool(pbParse(raw), 33);
}

function parseMethod(fields, pkg, serviceName) {
  const name = getString(fields, 1);
  const client = getBool(fields, 5);
  const server = getBool(fields, 6);
  return {
    name,
    path: methodPath(pkg, serviceName, name),
    input: simpleTypeName(getString(fields, 2)),
    output: simpleTypeName(getString(fields, 3)),
    inputFull: getString(fields, 2).replace(/^\./, ''),
    outputFull: getString(fields, 3).replace(/^\./, ''),
    kind: streamingKind(client, server),
    clientStreaming: client,
    serverStreaming: server,
    deprecated: optionsDeprecated(fields, 4),
    implName: name,
  };
}

function parseService(fields, pkg) {
  const name = getString(fields, 1);
  return {
    name,
    fullName: pkg ? pkg + '.' + name : name,
    methods: getAllBytes(fields, 2).map((m) => parseMethod(pbParse(m), pkg, name)),
  };
}

// FieldDescriptorProto type codes (descriptor.proto Type).
const FT = { DOUBLE: 1, FLOAT: 2, INT64: 3, UINT64: 4, INT32: 5, FIXED64: 6, FIXED32: 7, BOOL: 8, STRING: 9, GROUP: 10, MESSAGE: 11, BYTES: 12, UINT32: 13, ENUM: 14, SFIXED32: 15, SFIXED64: 16, SINT32: 17, SINT64: 18 };

function parseEnumDesc(fields) {
  return {
    name: getString(fields, 1),
    values: getAllBytes(fields, 2).map((v) => {
      const vf = pbParse(v);
      return { name: getString(vf, 1), number: getInt(vf, 2) };
    }),
  };
}

function parseFieldDesc(fields) {
  const dfltRaw = firstBytes(fields, 7);
  return {
    name: getString(fields, 1),
    extendee: getString(fields, 2, '').replace(/^\./, ''),
    number: getInt(fields, 3),
    label: getInt(fields, 4, 1), // 1 optional, 2 required, 3 repeated
    type: getInt(fields, 5),
    typeName: getString(fields, 6, '').replace(/^\./, ''),
    default: dfltRaw === null ? null : utf8.decode(dfltRaw),
    oneofIndex: fields.has(9) ? getInt(fields, 9) : null,
    jsonName: getString(fields, 10, ''),
  };
}

function parseMessageDesc(fields, prefix) {
  const name = getString(fields, 1);
  const full = prefix ? prefix + '.' + name : name;
  const opts = firstBytes(fields, 7);
  return {
    name,
    fullName: full,
    fields: getAllBytes(fields, 2).map((f) => parseFieldDesc(pbParse(f))),
    nested: getAllBytes(fields, 3).map((n) => parseMessageDesc(pbParse(n), full)),
    enums: getAllBytes(fields, 4).map((e) => parseEnumDesc(pbParse(e))),
    extensions: getAllBytes(fields, 6).map((f) => parseFieldDesc(pbParse(f))),
    mapEntry: opts !== null && getBool(pbParse(opts), 7),
  };
}

function parseFileDesc(fields) {
  const pkg = getString(fields, 2, '');
  const syntaxRaw = getString(fields, 12, '');
  return {
    name: getString(fields, 1),
    package: pkg,
    // protoc only writes syntax for proto3/editions; absent = proto2.
    syntax: syntaxRaw === '' ? 'proto2' : syntaxRaw,
    dependencies: getStrings(fields, 3),
    services: getAllBytes(fields, 6).map((s) => parseService(pbParse(s), pkg)),
    messages: getAllBytes(fields, 4).map((m) => parseMessageDesc(pbParse(m), pkg)),
    enums: getAllBytes(fields, 5).map((e) => parseEnumDesc(pbParse(e))),
    extensions: getAllBytes(fields, 7).map((f) => parseFieldDesc(pbParse(f))),
  };
}

// Extension fields merge into their extendee message's field list
// (mirrors the native model merge-extensions).
function mergeExtensions(files) {
  const exts = [];
  const collect = (msgs) => {
    for (const m of msgs) {
      exts.push(...m.extensions);
      collect(m.nested);
    }
  };
  for (const f of files) {
    exts.push(...f.extensions);
    collect(f.messages);
  }
  const addTo = (msg, ext) => {
    if (msg.fullName === ext.extendee) {
      msg.fields = [...msg.fields, ext];
    } else {
      for (const n of msg.nested) addTo(n, ext);
    }
  };
  for (const ext of exts) {
    for (const f of files) for (const m of f.messages) addTo(m, ext);
  }
  return files;
}

function buildModel(setBytes, entries) {
  const byName = new Map();
  for (const raw of getAllBytes(pbParse(setBytes), 1)) {
    const f = parseFileDesc(pbParse(raw));
    byName.set(f.name, f);
  }
  // Global type registry across the whole set, so JS message
  // generation can resolve field types across imports.
  mergeExtensions([...byName.values()]);
  const registry = new Map();
  const registerMsg = (file, pkg, msg) => {
    registry.set(msg.fullName, { kind: msg.mapEntry ? 'map' : 'message', msg, file, pkg, full: msg.fullName });
    for (const n of msg.nested) registerMsg(file, pkg, n);
    for (const e of msg.enums) registry.set(msg.fullName + '.' + e.name, { kind: 'enum', enum: e, file, pkg, full: msg.fullName + '.' + e.name });
  };
  for (const f of byName.values()) {
    for (const m of f.messages) registerMsg(f.name, f.package, m);
    for (const e of f.enums) registry.set((f.package ? f.package + '.' : '') + e.name, { kind: 'enum', enum: e, file: f.name, pkg: f.package, full: (f.package ? f.package + '.' : '') + e.name });
  }
  return entries.map((e) => {
    const f = byName.get(e);
    if (!f) throw new Error('file not in descriptor set: ' + e);
    f.types = registry;
    f.generateFiles = entries;
    return f;
  });
}

// Fields sharing f's oneof group within its message (f excluded),
// by identity in the file model's message tree. Empty for non-oneof
// fields and single-member (proto3 optional) oneofs.
function oneofSiblings(model, f) {
  if (f.oneofIndex === null || f.oneofIndex === undefined) return [];
  let found = null;
  const search = (msgs) => {
    for (const m of msgs) {
      if (m.fields.includes(f)) { found = m; return; }
      search(m.nested);
      if (found) return;
    }
  };
  search(model.messages || []);
  if (!found) return [];
  const sibs = found.fields.filter((x) => x !== f && x.oneofIndex === f.oneofIndex);
  return sibs.length ? sibs : [];
}

// Siblings of f that come after it in field order (encode winners).
function oneofLaterSiblings(model, f) {
  const sibs = oneofSiblings(model, f);
  if (!sibs.length) return [];
  let fields = null;
  const search = (msgs) => {
    for (const m of msgs) {
      if (m.fields.includes(f)) { fields = m.fields; return; }
      search(m.nested);
      if (fields) return;
    }
  };
  search(model.messages || []);
  if (!fields) return [];
  const idx = fields.indexOf(f);
  return sibs.filter((x) => fields.indexOf(x) > idx);
}

// The descriptor's explicit (proto2) default for a singular scalar
// or enum field, as a string; null otherwise.
function fieldExplicitDefault(f) {
  if (f.default === null || f.default === undefined) return null;
  if (f.label === 3) return null;
  if (f.type === FT.GROUP || f.type === FT.MESSAGE || f.type === FT.BYTES) return null;
  return f.default;
}

// Numeric value of a field's explicit enum default, or null.
function enumDefaultNumber(model, f) {
  const entry = model.types ? model.types.get(f.typeName) : null;
  if (!entry || entry.kind !== 'enum') return null;
  const v = entry.enum.values.find((x) => x.name === f.default);
  return v ? v.number : null;
}

function aliasesFor(fullName) {
  return METHOD_ALIASES.filter((a) => a[0] === fullName);
}

function aliasClientMethods(svc) {
  const out = [];
  for (const a of aliasesFor(svc.fullName)) {
    const target = svc.methods.find((m) => m.name === a[2]);
    if (target) out.push({ ...target, name: a[1] });
  }
  return out;
}

function aliasServerMethods(svc) {
  const out = [];
  for (const a of aliasesFor(svc.fullName)) {
    const target = svc.methods.find((m) => m.name === a[2]);
    if (target) out.push({ ...target, name: a[1], path: '/' + svc.fullName + '/' + a[1], implName: target.name });
  }
  return out;
}

const q = (s) => JSON.stringify(s);

function lowerFirst(s) {
  return s ? s[0].toLowerCase() + s.slice(1) : s;
}

function baseName(name) {
  const b = name.split('/').pop();
  const i = b.lastIndexOf('.');
  return i > 0 ? b.slice(0, i) : b;
}

function parseParams(parameter) {
  const params = {};
  if (!parameter) return params;
  for (const part of parameter.split(/[,:]/)) {
    const i = part.indexOf('=');
    if (i >= 0) params[part.slice(0, i)] = part.slice(i + 1);
  }
  return params;
}

JS
)

(define js-part-3 #<<JS
// ---------------------------------------------------------------------------
// JS emitter (mirrors the native js template).
// ---------------------------------------------------------------------------

function jsDeprecated(m, indent) {
  return runSegments(SEGMENT_PROGRAMS.jsDeprecated, m, '', null, [indent]);
}
function jsClientMethod(m) {
  return runSegments(SEGMENT_PROGRAMS.jsClientMethod, m, '');
}
function jsMethodTableEntry(m) {
  return runSegments(SEGMENT_PROGRAMS.jsMethodTableEntry, m, '');
}
function jsService(svc) {
  return runSegments(SEGMENT_PROGRAMS.jsService, svc, svc.name);
}
function emitJsFile(model, params) {
  const base = baseName(model.name);
  const pbImport = params.pb_import || './' + base + '_pb.js';
  const types = [];
  for (const s of model.services) {
    for (const m of s.methods) {
      for (const t of [m.input, m.output]) if (!types.includes(t)) types.push(t);
    }
  }
  const stub = {
    name: base + '_grpc_dc.js',
    content: '// @generated by protoc-gen-grpc-dc-js. DO NOT EDIT.\n'
      + '// source: ' + model.name + '\n'
      + (types.length ? 'import { ' + types.join(', ') + ' } from ' + q(pbImport) + ';\n\n' : '')
      + model.services.map(jsService).join(''),
  };
  const pb = emitJsPbFile(model);
  return pb ? [stub, pb] : stub;
}

// ---------------------------------------------------------------------------
// JS message classes (<base>_pb.js). The native plugins do not
// generate message classes (users bring protobuf tooling output);
// in the fully client-side web app there is no protoc to shell out
// to, so the browser generator emits dependency-free classes with
// the static encode/decode surface js/src/channel.js consumes —
// the same shape as the hand-written js/examples/echo_pb.js.
// Wire format is genuine protobuf (proto3 semantics; oneof fields
// are generated as plain fields).
// ---------------------------------------------------------------------------

const PB_PREAMBLE = `function varintBytes(value) {
  let n = BigInt.asUintN(64, BigInt(value));
  const out = [];
  while (n > 0x7fn) {
    out.push(Number((n & 0x7fn) | 0x80n));
    n >>= 7n;
  }
  out.push(Number(n));
  return out;
}

function zz64(v) {
  const b = BigInt(v);
  return (b << 1n) ^ (b >> 63n);
}

function unzz64(v) {
  return (v >> 1n) ^ (-(v & 1n));
}

class Reader {
  constructor(bytes) {
    this.bytes = bytes;
    this.pos = 0;
  }
  get done() {
    return this.pos >= this.bytes.length;
  }
  varint() {
    let result = 0n;
    let shift = 0n;
    for (;;) {
      if (this.pos >= this.bytes.length) throw new Error("truncated varint");
      const byte = this.bytes[this.pos++];
      result |= BigInt(byte & 0x7f) << shift;
      if ((byte & 0x80) === 0) return result;
      shift += 7n;
      if (shift >= 64n) throw new Error("varint too long");
    }
  }
  take(n) {
    const value = this.bytes.slice(this.pos, this.pos + n);
    if (value.length !== n) throw new Error("truncated field");
    this.pos += n;
    return value;
  }
  field() {
    if (this.done) return null;
    const start = this.pos;
    const tag = this.varint();
    const field = Number(tag >> 3n);
    const wire = Number(tag & 7n);
    switch (wire) {
      case 0:
        return [field, wire, this.varint(), this.bytes.slice(start, this.pos)];
      case 2: {
        const len = Number(this.varint());
        const v = this.take(len);
        return [field, wire, v, this.bytes.slice(start, this.pos)];
      }
      case 1: {
        const v = this.take(8);
        return [field, wire, v, this.bytes.slice(start, this.pos)];
      }
      case 5: {
        const v = this.take(4);
        return [field, wire, v, this.bytes.slice(start, this.pos)];
      }
      default:
        throw new Error("bad wire type " + wire);
    }
  }
}

function concatBytes(a, b) {
  const out = new Uint8Array(a.length + b.length);
  out.set(a);
  out.set(b, a.length);
  return out;
}

function putRaw(out, bytes) {
  for (let i = 0; i < bytes.length; i++) out.push(bytes[i]);
}

function putTag(out, num, wire) {
  out.push(...varintBytes((BigInt(num) << 3n) | BigInt(wire)));
}

function putVarintField(out, num, value) {
  if (value === 0n) return;
  putTag(out, num, 0);
  out.push(...varintBytes(value));
}

function putBytesField(out, num, payload) {
  putTag(out, num, 2);
  putRaw(out, varintBytes(payload.length));
  putRaw(out, payload);
}

function putStringField(out, num, value) {
  if (!value) return;
  putBytesField(out, num, new TextEncoder().encode(value));
}

function putFixedField(out, num, payload) {
  putTag(out, num, payload.length === 8 ? 1 : 5);
  out.push(...payload);
}

function fixedBytes(value, size, write) {
  const bytes = new Uint8Array(size);
  write(new DataView(bytes.buffer), value);
  return bytes;
}

function readFixed(bytes, read) {
  return read(new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength));
}

`;

function pbFlatName(pkg, fullName) {
  const rel = pkg && fullName.startsWith(pkg + '.') ? fullName.slice(pkg.length + 1) : fullName;
  return rel.split('.').join('_');
}

function pbJsName(f) {
  if (f.jsonName) return f.jsonName;
  return f.name.replace(/_([a-zA-Z0-9])/g, (_, c) => c.toUpperCase());
}

const PB_VARINT = new Set(VARINT_TYPES);
const PB_FIXED = FIXED_TABLES.js;
const PB_BIGINT = new Set([FT.INT64, FT.UINT64, FT.SINT64, FT.FIXED64, FT.SFIXED64]);

function pbVarintExpr(f, v) {
  return runSegments(SEGMENT_PROGRAMS.jsPbVarintExpr, f, '', null, [v]);
}
function pbVarintDecode(f, v) {
  return runSegments(SEGMENT_PROGRAMS.jsPbVarintDecode, f, '', null, [v]);
}
function pbExplicitLiteral(model, f) {
  const lit = runSegments(SEGMENT_PROGRAMS.jsPbExplicitLiteral, f, '', model);
  return lit === '' ? null : lit;
}
function pbDefault(f, model) {
  return runSegments(SEGMENT_PROGRAMS.jsPbDefault, f, '', model);
}
function pbResolve(model, typeName) {
  const entry = model.types.get(typeName);
  if (!entry) throw new Error('unresolved type ' + typeName + ' (not in descriptor set)');
  return entry;
}

// Statements encoding one singular field value expr into `out`.
function pbEncodeSingular(model, f, v, indent) {
  return runSegments(SEGMENT_PROGRAMS.jsPbEncodeSingular, f, '', model, [v, indent]);
}
function pbOneofClearing(model, f) {
  return runSegments(SEGMENT_PROGRAMS.jsPbOneofClearing, f, '', model);
}
function pbEncodeField(model, f) {
  return runSegments(SEGMENT_PROGRAMS.jsPbEncodeField, f, '', model);
}
function pbDecodeSingular(model, f, target, src) {
  return runSegments(SEGMENT_PROGRAMS.jsPbDecodeSingular, f, '', model, [target, src || 'value']);
}
function pbDecodeCase(model, f) {
  return runSegments(SEGMENT_PROGRAMS.jsPbDecodeCase, f, '', model);
}
function pbMapHelpers(model, entry) {
  return runSegments(SEGMENT_PROGRAMS.jsPbMapHelpers, entry, '', model);
}
function pbEnumConst(entry) {
  return runSegments(SEGMENT_PROGRAMS.jsPbEnumConst, entry, '', null);
}
function pbMessageClass(model, msg) {
  return runSegments(SEGMENT_PROGRAMS.jsPbMessage, msg, '', model);
}
function emitJsPbFile(model) {
  const hasMessages = model.messages.length > 0;
  // Types the stubs import from this file's pb module: re-export
  // any that live in imported files so the zip runs as-is.
  const serviceTypes = new Set();
  for (const s of model.services) for (const m of s.methods) { serviceTypes.add(m.inputFull); serviceTypes.add(m.outputFull); }
  const imports = new Map(); // dep file -> Set of names
  const reexports = new Map();
  const addImport = (entry, alsoExport) => {
    if (entry.file === model.name) return;
    const name = entry.kind === 'enum'
      ? pbFlatName(entry.pkg, entry.full)
      : pbFlatName(entry.pkg, entry.msg.fullName);
    if (!imports.has(entry.file)) imports.set(entry.file, new Set());
    imports.get(entry.file).add(name);
    if (alsoExport) {
      if (!reexports.has(entry.file)) reexports.set(entry.file, new Set());
      reexports.get(entry.file).add(name);
    }
  };
  const scanFields = (msg) => {
    for (const f of msg.fields) {
      if (f.type === FT.MESSAGE || f.type === FT.ENUM) addImport(pbResolve(model, f.typeName), false);
      if (f.type === FT.MESSAGE) {
        const e = pbResolve(model, f.typeName);
        if (e.kind === 'map') for (const ef of e.msg.fields) if (ef.type === FT.MESSAGE || ef.type === FT.ENUM) addImport(pbResolve(model, ef.typeName), false);
      }
    }
    for (const n of msg.nested) scanFields(n);
  };
  for (const m of model.messages) scanFields(m);
  for (const t of serviceTypes) {
    const entry = model.types.get(t);
    if (entry && entry.kind !== 'enum') addImport(entry, true);
  }
  if (!hasMessages && reexports.size === 0) return null;
  let out = '// @generated by protoc-gen-grpc-dc-js. DO NOT EDIT.\n'
    + '// source: ' + model.name + '\n\n';
  for (const [file, names] of imports) {
    out += 'import { ' + [...names].sort().join(', ') + ' } from "./' + baseName(file) + '_pb.js";\n';
  }
  if (imports.size) out += '\n';
  out += PB_PREAMBLE;
  const exported = new Set();
  const enumEntries = [];
  const collectEnums = (msg) => {
    for (const e of msg.enums) enumEntries.push(model.types.get(msg.fullName + '.' + e.name));
    for (const n of msg.nested) collectEnums(n);
  };
  for (const m of model.messages) collectEnums(m);
  for (const e of model.enums) enumEntries.push(model.types.get((model.package ? model.package + '.' : '') + e.name));
  for (const e of enumEntries) {
    if (!e) continue;
    const name = pbFlatName(e.pkg, e.msg ? e.msg.fullName + '.' + e.enum.name : (e.pkg ? e.pkg + '.' : '') + e.enum.name);
    if (exported.has(name)) continue;
    exported.add(name);
    out += pbEnumConst(e);
  }
  // Map-entry helpers (entry types themselves are not exported).
  const seenMaps = new Set();
  const mapHelpers = (msg) => {
    for (const f of msg.fields) {
      if (f.type === FT.MESSAGE) {
        const e = pbResolve(model, f.typeName);
        if (e.kind === 'map' && !seenMaps.has(e.msg.fullName)) { seenMaps.add(e.msg.fullName); out += pbMapHelpers(model, e); }
      }
    }
    for (const n of msg.nested) mapHelpers(n);
  };
  for (const m of model.messages) mapHelpers(m);
  const emitMsg = (msg) => {
    if (msg.mapEntry) return;
    out += pbMessageClass(model, msg);
    exported.add(pbFlatName(model.package, msg.fullName));
    for (const n of msg.nested) emitMsg(n);
  };
  for (const m of model.messages) emitMsg(m);
  // Simple-name aliases for nested messages (stub imports use the
  // simple name), when unambiguous.
  const alias = (msg, prefix) => {
    for (const n of msg.nested) {
      const flat = pbFlatName(model.package, n.fullName);
      if (!exported.has(n.name) && !n.mapEntry) { out += 'export const ' + n.name + ' = ' + flat + ';\n'; exported.add(n.name); }
      alias(n, prefix);
    }
  };
  for (const m of model.messages) alias(m, '');
  for (const [file, names] of reexports) {
    const fresh = [...names].filter((n) => !exported.has(n));
    if (fresh.length) out += 'export { ' + fresh.sort().join(', ') + ' } from "./' + baseName(file) + '_pb.js";\n';
  }
  return { name: baseName(model.name) + '_pb.js', content: out };
}

// ---------------------------------------------------------------------------
// Go emitter (mirrors the native go template).
// ---------------------------------------------------------------------------

function goPackage(model, params) {
  if (params.go_package) return params.go_package;
  if (!model.package) return 'proto';
  const parts = model.package.split('.');
  return parts[parts.length - 1];
}

function goDeprecated(m) {
  return runSegments(SEGMENT_PROGRAMS.goDeprecated, m, '');
}

function goClientMethod(m, svc) {
  return runSegments(SEGMENT_PROGRAMS.goClientMethod, m, svc);
}

function goServerIfaceMethod(m, svc) {
  return runSegments(SEGMENT_PROGRAMS.goServerIfaceMethod, m, svc);
}

function goServerIfaceMethodDepr(m, svc) {
  return runSegments(SEGMENT_PROGRAMS.goServerIfaceMethodDeprecated, m, svc);
}

function goStreamIfaces(m, svc) {
  return runSegments(SEGMENT_PROGRAMS.goStreamIfaces, m, svc);
}

function goRegisterMethod(m, svc) {
  // Emission single-sourced as segments (SEGMENT_PROGRAMS.goRegisterMethod,
  // from racket/segments.rkt); edit the program there.
  return runSegments(SEGMENT_PROGRAMS.goRegisterMethod, m, svc);
}

function goStreamImpls(m, svc) {
  return runSegments(SEGMENT_PROGRAMS.goStreamImpls, m, svc);
}

function goService(svc) {
  // Emission single-sourced as segments (SEGMENT_PROGRAMS.goService
  // and the per-method programs it calls, from racket/segments.rkt).
  return runSegments(SEGMENT_PROGRAMS.goService, svc, svc.name);
}

function gpPascal(s) {
  return s.split('_').map((p) => (p ? p[0].toUpperCase() + p.slice(1) : '')).join('');
}

function gpFlat(pkg, full) {
  const rel = pkg && full.startsWith(pkg + '.') ? full.slice(pkg.length + 1) : full;
  return rel.split('.').join('_');
}

function gpResolve(model, typeName) {
  const entry = model.types.get(typeName);
  if (!entry) throw new Error('unresolved type ' + typeName);
  return entry;
}

function gpEntryType(entry) {
  if (entry.kind === 'enum') {
    // Mirrors template-go.rkt: 'full includes the parent
    // message, so nested enums flatten to a qualified name
    // (e.g. Outer.Middle.Kind -> Outer_Middle_Kind) and cannot
    // collide on their simple name.
    return gpFlat(entry.pkg, entry.full);
  }
  return gpFlat(entry.pkg, entry.msg.fullName);
}

const GP_VARINT = new Set(VARINT_TYPES);
const GP_FIXED = FIXED_TABLES.go;

const GP_PREAMBLE = 'func appendVarint(out []byte, v uint64) []byte {\n\tfor v > 0x7f {\n\t\tout = append(out, byte(v&0x7f)|0x80)\n\t\tv >>= 7\n\t}\n\treturn append(out, byte(v))\n}\n\n'
  + 'func appendTag(out []byte, field int, wire int) []byte {\n\treturn appendVarint(out, uint64(field<<3|wire))\n}\n\n'
  + 'func appendBytesField(out []byte, field int, payload []byte) []byte {\n\tout = appendTag(out, field, 2)\n\tout = appendVarint(out, uint64(len(payload)))\n\treturn append(out, payload...)\n}\n\n'
  + 'func appendStringField(out []byte, field int, value string) []byte {\n\tif value == "" {\n\t\treturn out\n\t}\n\treturn appendBytesField(out, field, []byte(value))\n}\n\n'
  + 'func zz32(v int32) uint64 { return uint64(uint32((v << 1) ^ (v >> 31))) }\n\nfunc zz64(v int64) uint64 { return uint64((v << 1) ^ (v >> 63)) }\n\n'
  + 'func unzz32(v uint64) int32 { return int32(uint32(v>>1) ^ uint32(-int32(v&1))) }\n\nfunc unzz64(v uint64) int64 { return int64(v>>1) ^ -int64(v&1) }\n\n'
  + 'type pbReader struct {\n\tbuf []byte\n\tpos int\n}\n\n'
  + 'func (r *pbReader) varint() (uint64, error) {\n\tvar result uint64\n\tvar shift uint\n\tfor {\n\t\tif r.pos >= len(r.buf) {\n\t\t\treturn 0, errors.New("truncated varint")\n\t\t}\n\t\tb := r.buf[r.pos]\n\t\tr.pos++\n\t\tresult |= uint64(b&0x7f) << shift\n\t\tif b&0x80 == 0 {\n\t\t\treturn result, nil\n\t\t}\n\t\tshift += 7\n\t\tif shift >= 64 {\n\t\t\treturn 0, errors.New("varint too long")\n\t\t}\n\t}\n}\n\n'
  + 'func (r *pbReader) take(n int) ([]byte, error) {\n\tif r.pos+n > len(r.buf) {\n\t\treturn nil, errors.New("truncated field")\n\t}\n\tv := r.buf[r.pos : r.pos+n]\n\tr.pos += n\n\treturn v, nil\n}\n\n'
  + '// field returns (number, value, done, error); value is uint64 for\n// varints and []byte for length-delimited/fixed fields.\n'
  + 'func (r *pbReader) field() (int, int, any, []byte, bool, error) {\n\tif r.pos >= len(r.buf) {\n\t\treturn 0, 0, nil, nil, true, nil\n\t}\n\tstart := r.pos\n\ttag, err := r.varint()\n\tif err != nil {\n\t\treturn 0, 0, nil, nil, false, err\n\t}\n\tnum := int(tag >> 3)\n\twire := int(tag & 7)\n\tswitch wire {\n\tcase 0:\n\t\tv, err := r.varint()\n\t\treturn num, wire, v, r.buf[start:r.pos], false, err\n\tcase 2:\n\t\tn, err := r.varint()\n\t\tif err != nil {\n\t\t\treturn 0, 0, nil, nil, false, err\n\t\t}\n\t\tv, err := r.take(int(n))\n\t\treturn num, wire, v, r.buf[start:r.pos], false, err\n\tcase 1:\n\t\tv, err := r.take(8)\n\t\treturn num, wire, v, r.buf[start:r.pos], false, err\n\tcase 5:\n\t\tv, err := r.take(4)\n\t\treturn num, wire, v, r.buf[start:r.pos], false, err\n\tdefault:\n\t\treturn 0, 0, nil, nil, false, errors.New("bad wire type")\n\t}\n}\n\n';

function gpScalarType(f) {
  // Leaf payloads single-sourced from scalar-type-tables
  // in spec.rkt (SCALAR_TABLES), same table the native
  // template derives from.
  return SCALAR_TABLES.go.types[f.type] ?? SCALAR_TABLES.go.default;
}

function gpFieldType(model, f) {
  let base;
  if (f.type === FT.MESSAGE) {
    const entry = gpResolve(model, f.typeName);
    if (entry.kind === 'map') {
      const kf = entry.msg.fields.find((x) => x.number === 1);
      const vf = entry.msg.fields.find((x) => x.number === 2);
      base = 'map[' + gpFieldType(model, { ...kf, label: 1 }) + ']' + gpFieldType(model, { ...vf, label: 1 });
    } else {
      base = '*' + gpEntryType(entry);
    }
  } else if (f.type === FT.ENUM) {
    base = gpEntryType(gpResolve(model, f.typeName));
  } else {
    base = gpScalarType(f);
  }
  if (f.label === 3) {
    if (f.type === FT.MESSAGE && gpResolve(model, f.typeName).kind === 'map') return base;
    return '[]' + base;
  }
  return base;
}

function gpVarintExpr(f, v) {
  return runSegments(SEGMENT_PROGRAMS.goPbVarintExpr, f, '', null, [v]);
}
function gpVarintDecode(f, v) {
  return runSegments(SEGMENT_PROGRAMS.goPbVarintDecode, f, '', null, [v]);
}
function gpZero(f) {
  switch (f.type) {
    case FT.MESSAGE: case FT.GROUP: case FT.BYTES: return 'nil';
    case FT.STRING: return '""';
    case FT.BOOL: return 'false';
    default: return '0';
  }
}

function gpOneofClearing(model, f) {
  return oneofSiblings(model, f).map((sib) => '\t\t\tm.' + gpPascal(sib.name) + ' = ' + gpZero(sib) + '\n').join('');
}

function gpSetExpr(sib) {
  const v = 'm.' + gpPascal(sib.name);
  switch (sib.type) {
    case FT.MESSAGE: case FT.GROUP: return v + ' != nil';
    case FT.STRING: return v + ' != ""';
    case FT.BYTES: return 'len(' + v + ') > 0';
    case FT.BOOL: return v;
    default: return v + ' != 0';
  }
}

// Encode-side oneof clearing: suppress f when a later sibling is
// set, so only the winning member is written.
function gpEncodeGuard(model, f, code) {
  const later = oneofLaterSiblings(model, f);
  if (!later.length) return code;
  return '\tif !(' + later.map(gpSetExpr).join(' || ') + ') {\n' + code + '\t}\n';
}

function gpEncodeSingular(model, f, v, indent) {
  return runSegments(SEGMENT_PROGRAMS.goPbEncodeSingular, f, '', model, [v, indent]);
}
function gpEncodeField(model, f) {
  return runSegments(SEGMENT_PROGRAMS.goPbEncodeField, f, '', model);
}
function gpDecodeSingular(model, f, target, src, indent, errStmt) {
  return runSegments(SEGMENT_PROGRAMS.goPbDecodeSingular, f, '', model, [target, src, indent], errStmt);
}
function gpDecodeCase(model, f) {
  return runSegments(SEGMENT_PROGRAMS.goPbDecodeCase, f, '', model);
}
function gpMapEmittedInOwnFile(model, entry) {
  if (entry.file === model.name) return false;
  if (!(model.generateFiles || []).includes(entry.file)) return false;
  for (const e of model.types.values()) {
    if (e.kind !== 'message' || e.file !== entry.file) continue;
    for (const f of e.msg.fields) {
      if (f.type === FT.MESSAGE && f.typeName === entry.full) return true;
    }
  }
  return false;
}

function gpMapHelpers(model, entry) {
  return runSegments(SEGMENT_PROGRAMS.goPbMapHelpers, entry, '', model, [], 'return key, value, err');
}
function gpEnum(entry) {
  return runSegments(SEGMENT_PROGRAMS.goPbEnum, entry, '', null, [gpEntryType(entry)]);
}
function gpDefaultLiteral(model, f) {
  return runSegments(SEGMENT_PROGRAMS.goPbDefaultLiteral, f, '', model);
}
function gpConstructor(model, msg) {
  return runSegments(SEGMENT_PROGRAMS.goPbConstructor, msg, '', model);
}
function gpMessage(model, msg) {
  return runSegments(SEGMENT_PROGRAMS.goPbMessage, msg, '', model);
}
function gpApplyPrefix(content, prefix) {
  const pairs = [
    ['appendVarint', 'AppendVarint'], ['appendTag', 'AppendTag'],
    ['appendBytesField', 'AppendBytesField'], ['appendStringField', 'AppendStringField'],
    ['boolToUint64', 'BoolToUint64'], ['fixed32Bytes', 'Fixed32Bytes'],
    ['fixed64Bytes', 'Fixed64Bytes'], ['pbFloat32Bits', 'Float32Bits'],
    ['pbFloat32FromBits', 'Float32FromBits'], ['pbFloat64Bits', 'Float64Bits'],
    ['pbFloat64FromBits', 'Float64FromBits'], ['pbReader', 'Reader'],
    ['unzz32', 'Unzz32'], ['unzz64', 'Unzz64'], ['zz32', 'Zz32'], ['zz64', 'Zz64'],
  ];
  let s = content;
  for (const [from, to] of pairs) {
    s = s.replace(new RegExp('\\b' + from + '\\b', 'g'), prefix + to);
  }
  return s;
}

function emitGoPbFile(model, params) {
  if (!model.messages.length) return null;
  const base = baseName(model.name);
  let out = '// @generated by protoc-gen-grpc-dc-go. DO NOT EDIT.\n'
    + '// source: ' + model.name + '\n\n'
    + 'package ' + goPackage(model, params) + '\n\n'
    + 'import (\n\t"encoding/binary"\n\t"errors"\n\t"math"' + (model.messages.some((msg) => msg.fields.some((f) => f.type === FT.MESSAGE && gpResolve(model, f.typeName).kind === 'map')) ? '\n\t"sort"' : '') + '\n)\n\n'
    + 'func boolToUint64(b bool) uint64 {\n\tif b {\n\t\treturn 1\n\t}\n\treturn 0\n}\n\n'
    + 'func fixed32Bytes(v uint32) []byte {\n\tvar b [4]byte\n\tbinary.LittleEndian.PutUint32(b[:], v)\n\treturn b[:]\n}\n\n'
    + 'func fixed64Bytes(v uint64) []byte {\n\tvar b [8]byte\n\tbinary.LittleEndian.PutUint64(b[:], v)\n\treturn b[:]\n}\n\n'
    + 'func pbFloat32Bits(f float32) uint32 { return math.Float32bits(f) }\n\nfunc pbFloat32FromBits(u uint32) float32 { return math.Float32frombits(u) }\n\nfunc pbFloat64Bits(f float64) uint64 { return math.Float64bits(f) }\n\nfunc pbFloat64FromBits(u uint64) float64 { return math.Float64frombits(u) }\n\n'
    + GP_PREAMBLE;
  // Enums (file-level + nested), in descriptor order.
  const enumEntries = [];
  const walkEnums = (msg) => {
    for (const e of msg.enums) {
      const entry = model.types.get(msg.fullName + '.' + e.name);
      if (entry) enumEntries.push(entry);
    }
    for (const n of msg.nested) walkEnums(n);
  };
  for (const m of model.messages) walkEnums(m);
  for (const e of model.enums) {
    const entry = model.types.get((model.package ? model.package + '.' : '') + e.name);
    if (entry) enumEntries.push(entry);
  }
  for (const e of enumEntries) out += gpEnum(e);
  // Map helpers for every map field in the file's messages.
  const seenMaps = new Set();
  const emitMapHelpers = (msg) => {
    for (const f of msg.fields) {
      if (f.type === FT.MESSAGE) {
        const e = gpResolve(model, f.typeName);
        if (e.kind === 'map' && !seenMaps.has(e.msg.fullName) && !gpMapEmittedInOwnFile(model, e)) {
          seenMaps.add(e.msg.fullName);
          out += gpMapHelpers(model, e);
        }
      }
    }
    for (const n of msg.nested) emitMapHelpers(n);
  };
  for (const m of model.messages) emitMapHelpers(m);
  const emitMsg = (msg) => {
    if (msg.mapEntry) return;
    out += gpMessage(model, msg);
    for (const n of msg.nested) emitMsg(n);
  };
  for (const m of model.messages) emitMsg(m);
  return { name: base + '_pb.go', content: gpApplyPrefix(out, gpPascal(base) + 'Pb') };
}

function emitGoFile(model, params) {
  const base = baseName(model.name);
  const stub = {
    name: base + '_grpc_dc.go',
    content: '// @generated by protoc-gen-grpc-dc-go. DO NOT EDIT.\n'
      + '// source: ' + model.name + '\n\n'
      + 'package ' + goPackage(model, params) + '\n\n'
      + (model.services.length === 0
        ? ''
        : 'import (\n\t"context"\n\n\tgrpcdc "' + GO_MODULE_PATH + '"\n)\n\n')
      + model.services.map(goService).join(''),
  };
  const pb = emitGoPbFile(model, params);
  return pb ? [stub, pb] : stub;
}

JS
)

(define js-part-4 #<<JS
// ---------------------------------------------------------------------------
// Python emitter (mirrors the native python template).
// ---------------------------------------------------------------------------

function snake(s) {
  let out = '';
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (c >= 'A' && c <= 'Z') out += (i > 0 ? '_' : '') + c.toLowerCase();
    else out += c;
  }
  return out;
}

function pyDeprecated(m) {
  return runSegments(SEGMENT_PROGRAMS.pyDeprecated, m, '');
}
function pyClientMethod(pb, m) {
  return runSegments(SEGMENT_PROGRAMS.pyClientMethod, m, '', null, [pb]);
}
function pyAsyncClientMethod(pb, m) {
  return runSegments(SEGMENT_PROGRAMS.pyAsyncClientMethod, m, '', null, [pb]);
}
function pyServerHandler(pb, m) {
  return runSegments(SEGMENT_PROGRAMS.pyServerHandler, m, '', null, [pb]);
}
const PY_STREAM_HELPERS = `class _RecvStream:
    """Client receiving stream: recv() raises EOFError at end."""

    def __init__(self, stream, resp_cls):
        self._stream = stream
        self._resp_cls = resp_cls

    def recv(self):
        if self._stream is None:
            raise EOFError("stream closed")
        return self._stream.recv(self._resp_cls())

    def close(self):
        """Abandon the call early: RST so the server stops."""
        stream, self._stream = self._stream, None
        if stream is not None:
            stream.cancel()

    def __del__(self):
        self.close()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
        return False

    def __iter__(self):
        return self

    def __next__(self):
        try:
            return self.recv()
        except EOFError:
            raise StopIteration


class _SendStream:
    """Server-streaming sink passed to service implementations."""

    def __init__(self, ctx, sink):
        self.context = ctx
        self._sink = sink

    def send(self, resp):
        self._sink.send(resp.marshal_dc())


class _ClientStreamImpl:
    """Client-streaming stream passed to service implementations."""

    def __init__(self, ctx, reqs, req_cls):
        self.context = ctx
        self._reqs = reqs
        self._req_cls = req_cls
        self.resp = None

    def recv(self):
        return self._reqs.recv_into(self._req_cls())

    def send_and_close(self, resp):
        self.resp = resp


class _BidiStream:
    """Bidi stream passed to service implementations."""

    def __init__(self, ctx, reqs, sink, req_cls):
        self.context = ctx
        self._reqs = reqs
        self._sink = sink
        self._req_cls = req_cls

    def send(self, resp):
        self._sink.send(resp.marshal_dc())

    def recv(self):
        return self._reqs.recv_into(self._req_cls())


class _AsyncRecvStream:
    """Async client receiving stream: async-for or await recv()."""

    def __init__(self, stream, resp_cls):
        self._stream = stream
        self._resp_cls = resp_cls

    async def recv(self):
        return await self._stream.recv(self._resp_cls())

    def cancel(self):
        self._stream.cancel()

    async def aclose(self):
        self.cancel()

    def __aiter__(self):
        return self

    async def __anext__(self):
        try:
            return await self.recv()
        except EOFError:
            raise StopAsyncIteration


`;
function pyMethodEntry(m) {
  return runSegments(SEGMENT_PROGRAMS.pyMethodEntry, m, '');
}
function pyService(pb, svc) {
  return runSegments(SEGMENT_PROGRAMS.pyService, svc, svc.name, null, [pb]);
}
function emitPythonFile(model, params) {
  const base = baseName(model.name);
  const pb = base + '_pb';
  const stub = {
    name: base + '_grpc_dc.py',
    content: '# @generated by protoc-gen-grpc-dc-python. DO NOT EDIT.\n'
      + '# source: ' + model.name + '\n\n'
      + 'try:\n    from . import ' + pb + '\nexcept ImportError:  # direct module load\n    import ' + pb + '\n\n'
      + 'import grpcdc\n'
      + (params.trace === 'hooks'
        ? '\n# trace=hooks: register an observer via grpcdc.set_tracer(...)\nset_tracer = grpcdc.set_tracer\nset_trace_filter = grpcdc.set_trace_filter\n'
          + (params.trace_methods ? 'grpcdc.set_trace_filter("' + params.trace_methods + '")\n' : '')
        : '')
      + '\n'
      + PY_STREAM_HELPERS
      + model.services.map((svc) => pyService(pb, svc)).join(''),
  };
  const pbFile = emitPythonPbFile(model);
  return pbFile ? [stub, pbFile] : stub;
}

// ---------------------------------------------------------------------------
// Python message classes (<base>_pb.py), mirroring
// the native Python template's emit-python-pb-file byte-for-byte.
// ---------------------------------------------------------------------------

const PY_PB_PREAMBLE = `import struct as _struct


def _append_varint(out, value):
    v = value & 0xFFFFFFFFFFFFFFFF
    while v > 0x7F:
        out.append((v & 0x7F) | 0x80)
        v >>= 7
    out.append(v)
    return out


def _append_tag(out, field, wire):
    return _append_varint(out, (field << 3) | wire)


def _append_varint_field(out, field, value):
    if value == 0:
        return out
    out = _append_tag(out, field, 0)
    return _append_varint(out, value)


def _append_bytes_field(out, field, data):
    out = _append_tag(out, field, 2)
    out = _append_varint(out, len(data))
    out.extend(data)
    return out


def _append_string_field(out, field, value):
    if value == "":
        return out
    return _append_bytes_field(out, field, value.encode("utf-8"))


def _append_fixed_field(out, field, payload):
    out = _append_tag(out, field, 1 if len(payload) == 8 else 5)
    out.extend(payload)
    return out


class _Reader:
    def __init__(self, buf):
        self.buf = bytes(buf)
        self.pos = 0

    def varint(self):
        result = 0
        shift = 0
        while True:
            if self.pos >= len(self.buf):
                raise ValueError("truncated varint")
            b = self.buf[self.pos]
            self.pos += 1
            result |= (b & 0x7F) << shift
            if not (b & 0x80):
                return result
            shift += 7
            if shift >= 64:
                raise ValueError("varint too long")

    def take(self, n):
        if self.pos + n > len(self.buf):
            raise ValueError("truncated field")
        value = self.buf[self.pos:self.pos + n]
        self.pos += n
        return value

    def field(self):
        if self.pos >= len(self.buf):
            return None
        start = self.pos
        tag = self.varint()
        num, wire = tag >> 3, tag & 7
        if wire == 0:
            return num, wire, self.varint(), self.buf[start:self.pos]
        if wire == 2:
            return num, wire, self.take(self.varint()), self.buf[start:self.pos]
        if wire == 1:
            return num, wire, self.take(8), self.buf[start:self.pos]
        if wire == 5:
            return num, wire, self.take(4), self.buf[start:self.pos]
        raise ValueError("bad wire type")


def _as_int32(value):
    return ((value & 0xFFFFFFFF) ^ 0x80000000) - 0x80000000


def _as_int64(value):
    return ((value & 0xFFFFFFFFFFFFFFFF) ^ 0x8000000000000000) - 0x8000000000000000


def _unzz32(value):
    v = value & 0xFFFFFFFF
    return (v >> 1) ^ -(v & 1)


def _unzz64(value):
    v = value & 0xFFFFFFFFFFFFFFFF
    return (v >> 1) ^ -(v & 1)


`;

const PY_PB_VARINT = new Set(VARINT_TYPES);
const PY_PB_FIXED_FORMATS = {};
const PY_PB_FIXED_SIZES = {};
for (const [pyN, [pySize, pyFmt]] of Object.entries(FIXED_TABLES.python)) {
  PY_PB_FIXED_FORMATS[pyN] = pyFmt;
  PY_PB_FIXED_SIZES[pyN] = pySize;
}

function pyPbFlat(pkg, full) {
  const rel = pkg && full.startsWith(pkg + '.') ? full.slice(pkg.length + 1) : full;
  return rel.split('.').join('_');
}

function pyPbResolve(model, typeName) {
  const entry = model.types.get(typeName);
  if (!entry) throw new Error('unresolved type ' + typeName);
  return entry;
}

function pyPbEnumFull(entry) {
  return entry.full;
}

function pyPbRef(model, entry) {
  const flat = pyPbFlat(entry.pkg, entry.kind === 'enum' ? pyPbEnumFull(entry) : entry.msg.fullName);
  if (entry.file === model.name) return flat;
  return baseName(entry.file) + '_pb.' + flat;
}

function pyPbVarintExpr(f, v) {
  return runSegments(SEGMENT_PROGRAMS.pyPbVarintExpr, f, '', null, [v]);
}
function pyPbVarintDecode(f, v) {
  return runSegments(SEGMENT_PROGRAMS.pyPbVarintDecode, f, '', null, [v]);
}
function pyPbExplicitLiteral(model, f) {
  const lit = runSegments(SEGMENT_PROGRAMS.pyPbExplicitLiteral, f, '', model);
  return lit === '' ? null : lit;
}
function pyPbDefault(f, model) {
  return runSegments(SEGMENT_PROGRAMS.pyPbDefault, f, '', model);
}
function pyPbDefaultExpr(f, model) {
  return runSegments(SEGMENT_PROGRAMS.pyPbDefaultExpr, f, '', model);
}
function pyPbEncodeSingular(model, f, v, indent) {
  return runSegments(SEGMENT_PROGRAMS.pyPbEncodeSingular, f, '', model, [v, indent]);
}
function pyPbOneofClearing(model, f) {
  return runSegments(SEGMENT_PROGRAMS.pyPbOneofClearing, f, '', model);
}
function pyPbEncodeField(model, f) {
  return runSegments(SEGMENT_PROGRAMS.pyPbEncodeField, f, '', model);
}
function pyPbDecodeSingular(model, f, target, src, indent) {
  return runSegments(SEGMENT_PROGRAMS.pyPbDecodeSingular, f, '', model, [target, src, indent]);
}
function pyPbDecodeCase(model, f, first) {
  return runSegments(SEGMENT_PROGRAMS.pyPbDecodeCase, f, '', model, [first ? 'if' : 'elif']);
}
function pyPbMapHelpers(model, entry) {
  return runSegments(SEGMENT_PROGRAMS.pyPbMapHelpers, entry, '', model);
}
function pyPbInitLine(model, f) {
  return runSegments(SEGMENT_PROGRAMS.pyPbInitLine, f, '', model);
}
function pyPbClass(model, msg) {
  return runSegments(SEGMENT_PROGRAMS.pyPbMessage, msg, '', model);
}
function pyPbEnum(entry) {
  return runSegments(SEGMENT_PROGRAMS.pyPbEnum, entry, '', null);
}
function emitPythonPbFile(model) {
  const messages = model.messages;
  const serviceTypes = new Set();
  for (const s of model.services) for (const m of s.methods) { serviceTypes.add(m.inputFull); serviceTypes.add(m.outputFull); }
  const imports = new Map();
  const reexports = new Map();
  const addImport = (entry, alsoExport) => {
    if (entry.file === model.name) return;
    if (!imports.has(entry.file)) imports.set(entry.file, new Set());
    imports.get(entry.file).add(pyPbRef(model, entry));
    if (alsoExport) {
      if (!reexports.has(entry.file)) reexports.set(entry.file, new Set());
      reexports.get(entry.file).add(pyPbRef(model, entry));
    }
  };
  const scanFields = (msg) => {
    for (const f of msg.fields) {
      if (f.type === 11 || f.type === 14) {
        const e = pyPbResolve(model, f.typeName);
        addImport(e, false);
        if (f.type === 11 && e.kind === 'map') {
          for (const ef of e.msg.fields) if (ef.type === 11 || ef.type === 14) addImport(pyPbResolve(model, ef.typeName), false);
        }
      }
    }
    for (const n of msg.nested) scanFields(n);
  };
  for (const m of messages) scanFields(m);
  for (const t of serviceTypes) {
    const entry = model.types.get(t);
    if (entry && entry.kind !== 'enum') addImport(entry, true);
  }
  if (!messages.length && reexports.size === 0) return null;
  let out = '# @generated by protoc-gen-grpc-dc-python. DO NOT EDIT.\n'
    + '# source: ' + model.name + '\n\n'
    + '"""Generated protobuf messages (dependency-free wire format)."""\n\n';
  for (const dep of [...imports.keys()].sort()) {
    const depBase = baseName(dep);
    out += 'try:\n    from . import ' + depBase + '_pb\nexcept ImportError:  # direct module load\n    import ' + depBase + '_pb\n\n';
  }
  if (reexports.size) {
    for (const dep of [...reexports.keys()].sort()) {
      for (const flat of [...reexports.get(dep)].sort()) {
        out += flat.split('.').pop() + ' = ' + flat + '\n';
      }
    }
    out += '\n';
  }
  out += PY_PB_PREAMBLE;
  const enumEntries = [];
  const collectEnums = (msg) => {
    for (const e of msg.enums) enumEntries.push(model.types.get(msg.fullName + '.' + e.name));
    for (const n of msg.nested) collectEnums(n);
  };
  for (const m of messages) collectEnums(m);
  for (const e of model.enums) enumEntries.push(model.types.get((model.package ? model.package + '.' : '') + e.name));
  const seenEnums = new Set();
  for (const e of enumEntries) {
    if (!e) continue;
    const flat = pyPbFlat(e.pkg, pyPbEnumFull(e));
    if (seenEnums.has(flat)) continue;
    seenEnums.add(flat);
    out += pyPbEnum(e);
  }
  const seenMaps = new Set();
  const emitMapHelpers = (msg) => {
    for (const f of msg.fields) {
      if (f.type === 11) {
        const e = pyPbResolve(model, f.typeName);
        if (e.kind === 'map' && !seenMaps.has(e.msg.fullName)) { seenMaps.add(e.msg.fullName); out += pyPbMapHelpers(model, e); }
      }
    }
    for (const n of msg.nested) emitMapHelpers(n);
  };
  for (const m of messages) emitMapHelpers(m);
  const exported = new Set();
  const emitMsg = (msg) => {
    if (msg.mapEntry) return;
    out += pyPbClass(model, msg);
    exported.add(pyPbFlat(model.package, msg.fullName));
    for (const n of msg.nested) emitMsg(n);
  };
  for (const m of messages) emitMsg(m);
  const emitAliases = (msg) => {
    for (const n of msg.nested) {
      if (!n.mapEntry && !exported.has(n.name)) {
        out += n.name + ' = ' + pyPbFlat(model.package, n.fullName) + '\n';
        exported.add(n.name);
      }
      emitAliases(n);
    }
  };
  for (const m of messages) emitAliases(m);
  return { name: baseName(model.name) + '_pb.py', content: out };
}

// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
// Plugin protocol reframing for the in-browser plugin runner
// (the app worker): the protocompile compiler emits a
// FileDescriptorSet; protoc hands plugins a CodeGeneratorRequest
// instead. Reframe the former into the latter, and decode the
// CodeGeneratorResponse a plugin run produces.
// ---------------------------------------------------------------------------

function varintFieldBytes(value) {
  let n = BigInt.asUintN(64, BigInt(value));
  const out = [];
  while (n > 0x7fn) {
    out.push(Number((n & 0x7fn) | 0x80n));
    n >>= 7n;
  }
  out.push(Number(n));
  return out;
}

export function buildPluginRequest(setBytes, entries, parameter) {
  const files = getAllBytes(pbParse(setBytes), 1);
  const enc = new TextEncoder();
  const out = [];
  const pushField = (num, payload) => {
    out.push(...varintFieldBytes((BigInt(num) << 3n) | 2n), ...varintFieldBytes(payload.length), ...payload);
  };
  for (const e of entries) pushField(1, enc.encode(e));
  if (parameter) pushField(2, enc.encode(parameter));
  for (const f of files) pushField(15, f);
  return new Uint8Array(out);
}

export function parsePluginResponse(bytes) {
  const fields = pbParse(bytes);
  const err = firstBytes(fields, 1);
  if (err !== null) throw new Error(utf8.decode(err));
  return getAllBytes(fields, 15).map((entry) => {
    const ef = pbParse(entry);
    const content = firstBytes(ef, 15);
    return { name: getString(ef, 1), content: content === null ? new Uint8Array(0) : content };
  });
}

// Entry points. generateFiles mirrors the protoc plugin contract:
// one output file per file-to-generate, stamped with the generated
// code license header exactly like the native plugins do.
// ---------------------------------------------------------------------------

function stampGeneratedHeader(file) {
  // Mirrors the native stamp-generated-header, PHP included.
  if (file.name.endsWith('.php')) {
    return {
      name: file.name,
      content: '<?php\n// Generated code: use without restriction (see GENERATED-CODE-LICENSE.md).\n' + file.content.slice('<?php\n'.length),
    };
  }
  const prefix = file.name.endsWith('.py') || file.name.endsWith('.rb') ? '#' : file.name.endsWith('.lua') ? '--' : '//';
  return {
    name: file.name,
    content: prefix + ' Generated code: use without restriction (see GENERATED-CODE-LICENSE.md).\n' + file.content,
  };
}


// ---------------------------------------------------------------------------
// C99 generator, mirroring the native C template: message types in
// <base>_messages.h plus stubs in <base>_grpc_dc.h over the grpcdc
// C runtime. Byte-identical to the native protoc-gen-grpc-dc-c
// plugin.
// ---------------------------------------------------------------------------

const CB_VARINT = new Set(VARINT_TYPES);
const CB_FIXED = FIXED_TABLES.c;

function cbPascal(s) {
  return s.split(/[_.-]/).map((p) => (p ? p[0].toUpperCase() + p.slice(1) : '')).join('');
}

function cbSnake(s) {
  let out = '';
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (c >= 'A' && c <= 'Z') out += (i === 0 ? '' : '_') + c.toLowerCase();
    else out += c;
  }
  return out;
}

function cbResolve(model, typeName) {
  const entry = model.types.get(typeName);
  if (!entry) throw new Error('unresolved type ' + typeName);
  return entry;
}

function cbRel(pkg, full) {
  const rel = pkg && full.startsWith(pkg + '.') ? full.slice(pkg.length + 1) : full;
  return rel.split('.').join('_');
}

function cbEntryRef(model, entry) {
  return cbRel(entry.pkg, entry.kind === 'enum' ? entry.full : entry.msg.fullName);
}

function cbEntrySupport(entry) {
  return cbPascal(baseName(entry.file)) + 'Pb';
}

function cbScalar(f) {
  // Leaf payloads single-sourced from scalar-type-tables
  // in spec.rkt (SCALAR_TABLES), same table the native
  // template derives from.
  return SCALAR_TABLES.c.types[f.type] ?? SCALAR_TABLES.c.default;
}

function cbMsgName(model, msg) {
  return cbRel(model.package, msg.fullName);
}

function cbType(model, f, support) {
  return runSegments(SEGMENT_PROGRAMS.cPbType, f, '', model, [support]);
}
function cbExplicitLiteral(model, f) {
  const lit = runSegments(SEGMENT_PROGRAMS.cPbExplicitLiteral, f, '', model);
  return lit === '' ? null : lit;
}
function cbDefault(model, f, support) {
  return runSegments(SEGMENT_PROGRAMS.cPbDefault, f, '', model, [support]);
}
function cbVarintExpr(f, v) {
  return runSegments(SEGMENT_PROGRAMS.cPbVarintExpr, f, '', null, [v]);
}
function cbVarintDecode(f, v) {
  return runSegments(SEGMENT_PROGRAMS.cPbVarintDecode, f, '', null, [v]);
}
function cbNonzero(f, v) {
  return runSegments(SEGMENT_PROGRAMS.cPbNonzero, f, '', null, [v]);
}
function cbEncodeSingular(model, f, v, indent, support) {
  return runSegments(SEGMENT_PROGRAMS.cPbEncodeSingular, f, '', model, [v, indent, support]);
}
function cbEncodeField(model, f, support) {
  return runSegments(SEGMENT_PROGRAMS.cPbEncodeField, f, '', model, [support]);
}
function cbDecodeSingular(model, f, target, src, indent, support) {
  return runSegments(SEGMENT_PROGRAMS.cPbDecodeSingular, f, '', model, [target, src, indent, support]);
}
function cbSrc(f) {
  return CB_VARINT.has(f.type) ? 'field.varint_value' : (CB_FIXED[f.type] ? 'field.fixed_value' : 'field.bytes_value');
}

function cbGrowStmt(model, f, v, expr, indent, support) {
  return runSegments(SEGMENT_PROGRAMS.cPbGrow, f, '', model, [v, expr, indent ?? '', support ?? '']);
}
function cbDecodeCase(model, f, support) {
  return runSegments(SEGMENT_PROGRAMS.cPbDecodeCase, f, '', model, [support]);
}
function cbMapHelpers(model, entry, support) {
  return runSegments(SEGMENT_PROGRAMS.cPbMapHelpers, entry, '', model, [support]);
}
function cbSupportBlock(support, guard) {
  const P = support;
  return '#ifndef ' + guard + '\n#define ' + guard + '\n\n'
    + '#include <stdbool.h>\n#include <stdint.h>\n#include <stdlib.h>\n#include <string.h>\n\n'
    + 'typedef struct { uint8_t *data; size_t len; } ' + P + 'Bytes;\n\n'
    + 'static inline ' + P + 'Bytes ' + P + '_bytes_empty(void) { ' + P + 'Bytes b; b.data = NULL; b.len = 0; return b; }\n'
    + 'static inline ' + P + 'Bytes ' + P + '_bytes_copy(const uint8_t *data, size_t len) { ' + P + 'Bytes b; b.data = (uint8_t *)malloc(len ? len : 1); if (len) memcpy(b.data, data, len); b.len = len; return b; }\n'
    + 'static inline char *' + P + '_strdup_bytes(const uint8_t *data, size_t len) { char *s = (char *)malloc(len + 1); if (len) memcpy(s, data, len); s[len] = 0; return s; }\n\n'
    + 'typedef struct { uint8_t *data; size_t len; size_t cap; } ' + P + 'Writer;\n\n'
    + 'static inline void ' + P + '_writer_init(' + P + 'Writer *w) { w->data = NULL; w->len = 0; w->cap = 0; }\n'
    + 'static inline void ' + P + '_writer_free(' + P + 'Writer *w) { free(w->data); w->data = NULL; w->len = w->cap = 0; }\n'
    + 'static inline void ' + P + '_writer_reserve(' + P + 'Writer *w, size_t n) { if (w->len + n > w->cap) { size_t cap = w->cap ? w->cap * 2 : 64; while (cap < w->len + n) cap *= 2; w->data = (uint8_t *)realloc(w->data, cap); w->cap = cap; } }\n'
    + 'static inline void ' + P + '_writer_varint(' + P + 'Writer *w, uint64_t v) { ' + P + '_writer_reserve(w, 10); while (v > 0x7f) { w->data[w->len++] = (uint8_t)((v & 0x7f) | 0x80); v >>= 7; } w->data[w->len++] = (uint8_t)v; }\n'
    + 'static inline void ' + P + '_writer_tag(' + P + 'Writer *w, int field, int wire) { ' + P + '_writer_varint(w, (uint64_t)((field << 3) | wire)); }\n'
    + 'static inline void ' + P + '_writer_bytes_field(' + P + 'Writer *w, int field, const uint8_t *payload, size_t len) { ' + P + '_writer_tag(w, field, 2); ' + P + '_writer_varint(w, (uint64_t)len); ' + P + '_writer_reserve(w, len); if (len) memcpy(w->data + w->len, payload, len); w->len += len; }\n'
    + 'static inline void ' + P + '_writer_string_field(' + P + 'Writer *w, int field, const char *value) { if (!value || !value[0]) return; ' + P + '_writer_bytes_field(w, field, (const uint8_t *)value, strlen(value)); }\n'
    + 'static inline void ' + P + '_writer_raw(' + P + 'Writer *w, const uint8_t *payload, size_t len) { ' + P + '_writer_reserve(w, len); if (len) memcpy(w->data + w->len, payload, len); w->len += len; }\n'
    + 'static inline void ' + P + '_writer_fixed_u32(' + P + 'Writer *w, uint32_t v) { ' + P + '_writer_reserve(w, 4); for (int i = 0; i < 4; i++) w->data[w->len++] = (uint8_t)((v >> (8 * i)) & 0xff); }\n'
    + 'static inline void ' + P + '_writer_fixed_u64(' + P + 'Writer *w, uint64_t v) { ' + P + '_writer_reserve(w, 8); for (int i = 0; i < 8; i++) w->data[w->len++] = (uint8_t)((v >> (8 * i)) & 0xff); }\n'
    + 'static inline void ' + P + '_writer_fixed_i32(' + P + 'Writer *w, int32_t v) { ' + P + '_writer_fixed_u32(w, (uint32_t)v); }\n'
    + 'static inline void ' + P + '_writer_fixed_i64(' + P + 'Writer *w, int64_t v) { ' + P + '_writer_fixed_u64(w, (uint64_t)v); }\n'
    + 'static inline void ' + P + '_writer_fixed_f32(' + P + 'Writer *w, float v) { uint32_t u; memcpy(&u, &v, 4); ' + P + '_writer_fixed_u32(w, u); }\n'
    + 'static inline void ' + P + '_writer_fixed_f64(' + P + 'Writer *w, double v) { uint64_t u; memcpy(&u, &v, 8); ' + P + '_writer_fixed_u64(w, u); }\n'
    + 'static inline float ' + P + '_fixed_to_f32(uint32_t u) { float v; memcpy(&v, &u, 4); return v; }\n'
    + 'static inline double ' + P + '_fixed_to_f64(uint64_t u) { double v; memcpy(&v, &u, 8); return v; }\n'
    + 'static inline ' + P + 'Bytes ' + P + '_writer_to_bytes(' + P + 'Writer *w) { ' + P + 'Bytes b; b.data = w->data; b.len = w->len; w->data = NULL; w->len = w->cap = 0; return b; }\n\n'
    + 'typedef struct { int number; int wire; uint64_t varint_value; ' + P + 'Bytes bytes_value; uint64_t fixed_value; ' + P + 'Bytes raw_value; } ' + P + 'Field;\n\n'
    + 'typedef struct { const uint8_t *buf; size_t len; size_t pos; } ' + P + 'Reader;\n\n'
    + 'static inline void ' + P + '_reader_init(' + P + 'Reader *r, const uint8_t *buf, size_t len) { r->buf = buf; r->len = len; r->pos = 0; }\n'
    + 'static inline bool ' + P + '_reader_done(const ' + P + 'Reader *r) { return r->pos >= r->len; }\n'
    + 'static inline uint64_t ' + P + '_reader_varint(' + P + 'Reader *r) { uint64_t result = 0; int shift = 0; while (1) { if (r->pos >= r->len) return result; uint8_t b = r->buf[r->pos++]; result |= (uint64_t)(b & 0x7f) << shift; if ((b & 0x80) == 0) return result; shift += 7; if (shift >= 64) return result; } }\n'
    + 'static inline uint32_t ' + P + '_reader_fixed_u32(' + P + 'Reader *r) { uint32_t v = 0; for (int i = 0; i < 4; i++) { if (r->pos < r->len) v |= (uint32_t)r->buf[r->pos++] << (8 * i); } return v; }\n'
    + 'static inline uint64_t ' + P + '_reader_fixed_u64(' + P + 'Reader *r) { uint64_t v = 0; for (int i = 0; i < 8; i++) { if (r->pos < r->len) v |= (uint64_t)r->buf[r->pos++] << (8 * i); } return v; }\n'
    + 'static inline bool ' + P + '_reader_next(' + P + 'Reader *r, ' + P + 'Field *field) {\n'
    + '    if (r->pos >= r->len) return false;\n'
    + '    size_t start = r->pos;\n'
    + '    uint64_t tag = ' + P + '_reader_varint(r); field->number = (int)(tag >> 3); field->wire = (int)(tag & 7);\n'
    + '    field->varint_value = 0; field->fixed_value = 0; field->bytes_value.data = NULL; field->bytes_value.len = 0;\n'
    + '    switch (field->wire) {\n'
    + '        case 0: field->varint_value = ' + P + '_reader_varint(r); break;\n'
    + '        case 2: { uint64_t n = ' + P + '_reader_varint(r); if (r->pos + (size_t)n > r->len) n = r->len - r->pos; field->bytes_value.data = (uint8_t *)(r->buf + r->pos); field->bytes_value.len = (size_t)n; r->pos += (size_t)n; break; }\n'
    + '        case 1: field->bytes_value.data = (uint8_t *)(r->buf + r->pos); field->bytes_value.len = 8 <= r->len - r->pos ? 8 : r->len - r->pos; field->fixed_value = 0; for (size_t i = 0; i < field->bytes_value.len; i++) field->fixed_value |= (uint64_t)r->buf[r->pos + i] << (8 * i); r->pos += field->bytes_value.len; break;\n'
    + '        case 5: field->bytes_value.data = (uint8_t *)(r->buf + r->pos); field->bytes_value.len = 4 <= r->len - r->pos ? 4 : r->len - r->pos; field->fixed_value = 0; for (size_t i = 0; i < field->bytes_value.len; i++) field->fixed_value |= (uint64_t)r->buf[r->pos + i] << (8 * i); r->pos += field->bytes_value.len; break;\n'
    + '        default: return false;\n'
    + '    }\n'
    + '    field->raw_value.data = (uint8_t *)(r->buf + start); field->raw_value.len = r->pos - start;\n'
    + '    return true;\n'
    + '}\n\n';
}

function cbMessageFns(model, msg, support) {
  return runSegments(SEGMENT_PROGRAMS.cPbMessage, msg, '', model, [support]);
}
function emitCPbFiles(model) {
  if (!model.messages.length && !model.enums.length) return [];
  const base = baseName(model.name);
  const support = cbPascal(base) + 'Pb';
  const guard = 'GRPCDC_' + base.toUpperCase() + '_MESSAGES_H';
  const seenMaps = new Map();
  const collect = (msg) => {
    for (const f of msg.fields) {
      if (f.type === FT.MESSAGE) {
        const e = cbResolve(model, f.typeName);
        if (e.kind === 'map' && !seenMaps.has(e.msg.fullName)) seenMaps.set(e.msg.fullName, e);
      }
    }
    for (const n of msg.nested) collect(n);
  };
  for (const m of model.messages) collect(m);
  const mapEntries = [...seenMaps.values()];
  const allMsgs = [];
  const walk = (msg) => {
    if (msg.mapEntry) return;
    allMsgs.push(msg);
    for (const n of msg.nested) walk(n);
  };
  for (const m of model.messages) walk(m);
  const allEnums = [];
  for (const e of model.enums) allEnums.push([e, null]);
  const walkEnums = (msg) => {
    for (const e of msg.enums) allEnums.push([e, cbMsgName(model, msg)]);
    for (const n of msg.nested) walkEnums(n);
  };
  for (const m of model.messages) walkEnums(m);
  const content = '// @generated by protoc-gen-grpc-dc-c. DO NOT EDIT.\n'
    + cbSupportBlock(support, guard)
    + (model.dependencies || []).map((d) => '#include "' + baseName(d) + '_messages.h"\n').join('')
    + ((model.dependencies || []).length ? '\n' : '')
    + allEnums.map(([e, parent]) => {
      const name = parent ? parent + '_' + e.name : e.name;
      return 'typedef enum ' + name + ' {\n'
        + e.values.map((v) => '    ' + name + '_' + v.name + ' = ' + v.number).join(',\n')
        + '\n} ' + name + ';\n\n';
    }).join('')
    + allMsgs.map((m) => 'typedef struct ' + cbMsgName(model, m) + ' ' + cbMsgName(model, m) + ';\n').join('')
    + mapEntries.map((e) => 'typedef struct ' + cbEntryRef(model, e) + ' ' + cbEntryRef(model, e) + ';\n').join('')
    + '\n'
    + allMsgs.map((m) => {
      const name = cbMsgName(model, m);
      return 'struct ' + name + ' {\n'
        + m.fields.map((f) => {
          const repeated = f.label === 3 || (f.type === FT.MESSAGE && cbResolve(model, f.typeName).kind === 'map');
          return '    ' + cbType(model, f, support) + ' ' + f.name + ';\n'
            + (repeated ? '    size_t ' + f.name + '_count;\n' : '');
        }).join('')
        + '    ' + support + 'Bytes unknown_fields;\n};\n\n';
    }).join('')
    + mapEntries.map((e) => {
      const em = e.msg;
      const kf = em.fields.find((x) => x.number === 1);
      const vf = em.fields.find((x) => x.number === 2);
      return 'struct ' + cbEntryRef(model, e) + ' { ' + cbType(model, { ...kf, label: 1 }, support) + ' key; '
        + (vf.type === FT.MESSAGE
          ? cbEntryRef(model, cbResolve(model, vf.typeName))
          : cbType(model, { ...vf, label: 1 }, support))
        + ' value; };\n\n';
    }).join('')
    + allMsgs.map((m) => {
      const name = cbMsgName(model, m);
      return 'static inline void ' + name + '_init(' + name + ' *m);\n'
        + 'static inline ' + support + 'Bytes ' + name + '_marshal(const ' + name + ' *m);\n'
        + 'static inline void ' + name + '_unmarshal(' + name + ' *m, const uint8_t *data, size_t len);\n';
    }).join('')
    + '\n'
    + mapEntries.map((e) => cbMapHelpers(model, e, support)).join('')
    + allMsgs.map((m) => cbMessageFns(model, m, support)).join('')
    + '#endif /* ' + guard + ' */\n';
  return [{ name: base + '_messages.h', content }];
}

function cbTypeRef(model, full) {
  return cbEntryRef(model, cbResolve(model, full));
}

function emitCFile(model, params) {
  const base = baseName(model.name);
  const support = cbPascal(base) + 'Pb';
  const guard = 'GRPCDC_' + base.toUpperCase() + '_GRPC_DC_H';
  const pbFiles = emitCPbFiles(model);
  const parts = [];
  for (const svc of model.services) {
    const S = svc.name;
    const methods = svc.methods;
    const serviceMethods = [...methods, ...(svc.aliasMethods || [])];
    parts.push('/* Service ' + S + ' (' + svc.fullName + '). */\n');
    parts.push('typedef struct { grpcdc_channel *channel; } ' + S + 'Client;\n\n');
    for (const m of serviceMethods) {
      const req = cbTypeRef(model, m.inputFull);
      const resp = cbTypeRef(model, m.outputFull);
      const reqSup = cbEntrySupport(cbResolve(model, m.inputFull));
      const respSup = cbEntrySupport(cbResolve(model, m.outputFull));
      const name = cbSnake(m.name);
      if (m.deprecated) parts.push('/* Deprecated in the proto schema. */\n');
      if (m.kind === 'unary') {
        parts.push('static inline grpcdc_status ' + S + 'Client_' + name + '(' + S + 'Client *c, const ' + req + ' *req, ' + resp + ' *resp, const grpcdc_kv *md, size_t md_count, int64_t deadline_ms) {\n'
          + '    ' + reqSup + 'Bytes rb = ' + req + '_marshal(req);\n'
          + '    grpcdc_bytes out; grpcdc_status st = grpcdc_channel_unary(c->channel, ' + JSON.stringify(m.path) + ', rb.data, rb.len, md, md_count, deadline_ms, &out);\n'
          + '    free(rb.data);\n'
          + '    if (st.code == 0) { memset(resp, 0, sizeof(*resp)); ' + resp + '_unmarshal(resp, out.data, out.len); grpcdc_bytes_free(&out); }\n'
          + '    return st;\n}\n\n');
      } else if (m.kind === 'server-streaming') {
        parts.push('typedef struct { grpcdc_stream *raw; } ' + S + m.name + 'Client;\n\n'
          + 'static inline grpcdc_status ' + S + 'Client_' + name + '(' + S + 'Client *c, const ' + req + ' *req, ' + S + m.name + 'Client *out_stream, const grpcdc_kv *md, size_t md_count, int64_t deadline_ms) {\n'
          + '    ' + reqSup + 'Bytes rb = ' + req + '_marshal(req);\n'
          + '    grpcdc_status st = grpcdc_channel_open(c->channel, ' + JSON.stringify(m.path) + ', rb.data, rb.len, 1, md, md_count, deadline_ms, &out_stream->raw);\n'
          + '    free(rb.data);\n    return st;\n}\n\n'
          + 'static inline int ' + S + m.name + 'Client_recv(' + S + m.name + 'Client *s, ' + resp + ' *resp, grpcdc_status *st) {\n'
          + '    grpcdc_bytes out; int r = grpcdc_stream_recv(s->raw, &out, st);\n'
          + '    if (r == 1) { memset(resp, 0, sizeof(*resp)); ' + resp + '_unmarshal(resp, out.data, out.len); grpcdc_bytes_free(&out); }\n'
          + '    return r;\n}\n\n'
          + 'static inline void ' + S + m.name + 'Client_close(' + S + m.name + 'Client *s) { grpcdc_stream_free(s->raw); }\n\n'
          + 'static inline void ' + S + m.name + 'Client_cancel(' + S + m.name + 'Client *s) { grpcdc_stream_cancel(s->raw); }\n\n');
      } else if (m.kind === 'client-streaming') {
        parts.push('static inline grpcdc_status ' + S + 'Client_' + name + '(' + S + 'Client *c, const ' + req + ' *reqs, size_t req_count, ' + resp + ' *resp, const grpcdc_kv *md, size_t md_count, int64_t deadline_ms) {\n'
          + '    grpcdc_stream *raw; grpcdc_status st;\n'
          + '    st = grpcdc_channel_open(c->channel, ' + JSON.stringify(m.path) + ', NULL, 0, 0, md, md_count, deadline_ms, &raw);\n'
          + '    if (st.code != 0) return st;\n'
          + '    for (size_t i = 0; i < req_count; i++) {\n'
          + '        ' + reqSup + 'Bytes rb = ' + req + '_marshal(&reqs[i]);\n'
          + '        st = grpcdc_stream_send(raw, rb.data, rb.len); free(rb.data);\n'
          + '        if (st.code != 0) { grpcdc_stream_free(raw); return st; }\n    }\n'
          + '    st = grpcdc_stream_close_send(raw);\n'
          + '    if (st.code != 0) { grpcdc_stream_free(raw); return st; }\n'
          + '    grpcdc_bytes out; int r = grpcdc_stream_recv(raw, &out, &st);\n'
          + '    if (r == 1) { memset(resp, 0, sizeof(*resp)); ' + resp + '_unmarshal(resp, out.data, out.len); grpcdc_bytes_free(&out); }\n'
          + '    grpcdc_stream_free(raw);\n'
          + '    if (r == 0) return grpcdc_status_make(2, "missing response");\n'
          + '    return st;\n}\n\n');
      } else if (m.kind === 'bidi') {
        parts.push('typedef struct { grpcdc_stream *raw; } ' + S + m.name + 'Client;\n\n'
          + 'static inline grpcdc_status ' + S + 'Client_' + name + '(' + S + 'Client *c, const ' + req + ' *reqs, size_t req_count, ' + S + m.name + 'Client *out_stream, const grpcdc_kv *md, size_t md_count, int64_t deadline_ms) {\n'
          + '    grpcdc_status st;\n'
          + '    st = grpcdc_channel_open(c->channel, ' + JSON.stringify(m.path) + ', NULL, 0, 0, md, md_count, deadline_ms, &out_stream->raw);\n'
          + '    if (st.code != 0) return st;\n'
          + '    for (size_t i = 0; i < req_count; i++) {\n'
          + '        ' + reqSup + 'Bytes rb = ' + req + '_marshal(&reqs[i]);\n'
          + '        st = grpcdc_stream_send(out_stream->raw, rb.data, rb.len); free(rb.data);\n'
          + '        if (st.code != 0) { grpcdc_stream_free(out_stream->raw); return st; }\n    }\n'
          + '    return grpcdc_stream_close_send(out_stream->raw);\n}\n\n'
          + 'static inline int ' + S + m.name + 'Client_recv(' + S + m.name + 'Client *s, ' + resp + ' *resp, grpcdc_status *st) {\n'
          + '    grpcdc_bytes out; int r = grpcdc_stream_recv(s->raw, &out, st);\n'
          + '    if (r == 1) { memset(resp, 0, sizeof(*resp)); ' + resp + '_unmarshal(resp, out.data, out.len); grpcdc_bytes_free(&out); }\n'
          + '    return r;\n}\n\n'
          + 'static inline void ' + S + m.name + 'Client_close(' + S + m.name + 'Client *s) { grpcdc_stream_free(s->raw); }\n\n'
          + 'static inline void ' + S + m.name + 'Client_cancel(' + S + m.name + 'Client *s) { grpcdc_stream_cancel(s->raw); }\n\n');
      }
    }
    // server stream helper types
    for (const m of methods) {
      const req = cbTypeRef(model, m.inputFull);
      const resp = cbTypeRef(model, m.outputFull);
      const respSup = cbEntrySupport(cbResolve(model, m.outputFull));
      if (m.kind === 'server-streaming') {
        parts.push('typedef struct { grpcdc_server_stream *raw; } ' + S + m.name + 'Stream;\n'
          + 'static inline grpcdc_status ' + S + m.name + 'Stream_send(' + S + m.name + 'Stream *s, const ' + resp + ' *resp) { ' + respSup + 'Bytes rb = ' + resp + '_marshal(resp); grpcdc_status st = grpcdc_server_stream_send(s->raw, rb.data, rb.len); free(rb.data); return st; }\n\n');
      } else if (m.kind === 'client-streaming') {
        parts.push('typedef struct { grpcdc_server_stream *raw; } ' + S + m.name + 'Stream;\n'
          + 'static inline int ' + S + m.name + 'Stream_recv(' + S + m.name + 'Stream *s, ' + req + ' *req, grpcdc_status *st) { grpcdc_bytes out; int r = grpcdc_server_stream_recv(s->raw, &out, st); if (r == 1) { memset(req, 0, sizeof(*req)); ' + req + '_unmarshal(req, out.data, out.len); grpcdc_bytes_free(&out); } return r; }\n\n');
      } else if (m.kind === 'bidi') {
        parts.push('typedef struct { grpcdc_server_stream *raw; } ' + S + m.name + 'Stream;\n'
          + 'static inline grpcdc_status ' + S + m.name + 'Stream_send(' + S + m.name + 'Stream *s, const ' + resp + ' *resp) { ' + respSup + 'Bytes rb = ' + resp + '_marshal(resp); grpcdc_status st = grpcdc_server_stream_send(s->raw, rb.data, rb.len); free(rb.data); return st; }\n'
          + 'static inline int ' + S + m.name + 'Stream_recv(' + S + m.name + 'Stream *s, ' + req + ' *req, grpcdc_status *st) { grpcdc_bytes out; int r = grpcdc_server_stream_recv(s->raw, &out, st); if (r == 1) { memset(req, 0, sizeof(*req)); ' + req + '_unmarshal(req, out.data, out.len); grpcdc_bytes_free(&out); } return r; }\n\n');
      }
    }
    parts.push('typedef struct {\n    void *ctx;\n'
      + methods.map((m) => {
        const req = cbTypeRef(model, m.inputFull);
        const resp = cbTypeRef(model, m.outputFull);
        const snake = cbSnake(m.name);
        if (m.kind === 'unary') return '    grpcdc_status (*' + snake + ')(void *ctx, const grpcdc_kv *md, size_t md_count, const ' + req + ' *req, ' + resp + ' *resp);\n';
        if (m.kind === 'server-streaming') return '    grpcdc_status (*' + snake + ')(void *ctx, const grpcdc_kv *md, size_t md_count, const ' + req + ' *req, ' + S + m.name + 'Stream *stream);\n';
        if (m.kind === 'client-streaming') return '    grpcdc_status (*' + snake + ')(void *ctx, ' + S + m.name + 'Stream *stream, ' + resp + ' *resp);\n';
        return '    grpcdc_status (*' + snake + ')(void *ctx, ' + S + m.name + 'Stream *stream);\n';
      }).join('')
      + '} ' + S + 'ServerImpl;\n\n');
    for (const m of methods) {
      const req = cbTypeRef(model, m.inputFull);
      const resp = cbTypeRef(model, m.outputFull);
      const respSup = cbEntrySupport(cbResolve(model, m.outputFull));
      const snake = cbSnake(m.name);
      if (m.kind === 'unary') {
        parts.push('static grpcdc_status ' + S + '_' + snake + '_unary_adapter(void *impl, const grpcdc_kv *md, size_t md_count, grpcdc_bytes reqb, grpcdc_bytes *respb) {\n'
          + '    ' + S + 'ServerImpl *impl_ = (' + S + 'ServerImpl *)impl;\n'
          + '    ' + req + ' req; memset(&req, 0, sizeof(req)); ' + req + '_unmarshal(&req, reqb.data, reqb.len);\n'
          + '    ' + resp + ' resp; memset(&resp, 0, sizeof(resp));\n'
          + '    grpcdc_status st = impl_->' + snake + '(impl_->ctx, md, md_count, &req, &resp);\n'
          + '    if (st.code == 0) { ' + respSup + 'Bytes rb = ' + resp + '_marshal(&resp); respb->data = rb.data; respb->len = rb.len; }\n'
          + '    return st;\n}\n\n');
      } else if (m.kind === 'server-streaming') {
        parts.push('static grpcdc_status ' + S + '_' + snake + '_sstream_adapter(void *impl, const grpcdc_kv *md, size_t md_count, grpcdc_bytes reqb, grpcdc_server_stream *raw) {\n'
          + '    ' + S + 'ServerImpl *impl_ = (' + S + 'ServerImpl *)impl;\n'
          + '    ' + req + ' req; memset(&req, 0, sizeof(req)); ' + req + '_unmarshal(&req, reqb.data, reqb.len);\n'
          + '    ' + S + m.name + 'Stream stream; stream.raw = raw;\n'
          + '    return impl_->' + snake + '(impl_->ctx, md, md_count, &req, &stream);\n}\n\n');
      } else if (m.kind === 'client-streaming') {
        parts.push('static grpcdc_status ' + S + '_' + snake + '_cstream_adapter(void *impl, grpcdc_server_stream *raw, grpcdc_bytes *respb) {\n'
          + '    ' + S + 'ServerImpl *impl_ = (' + S + 'ServerImpl *)impl;\n'
          + '    ' + S + m.name + 'Stream stream; stream.raw = raw;\n'
          + '    ' + resp + ' resp; memset(&resp, 0, sizeof(resp));\n'
          + '    grpcdc_status st = impl_->' + snake + '(impl_->ctx, &stream, &resp);\n'
          + '    if (st.code == 0) { ' + respSup + 'Bytes rb = ' + resp + '_marshal(&resp); respb->data = rb.data; respb->len = rb.len; }\n'
          + '    return st;\n}\n\n');
      } else if (m.kind === 'bidi') {
        parts.push('static grpcdc_status ' + S + '_' + snake + '_bidi_adapter(void *impl, grpcdc_server_stream *raw) {\n'
          + '    ' + S + 'ServerImpl *impl_ = (' + S + 'ServerImpl *)impl;\n'
          + '    ' + S + m.name + 'Stream stream; stream.raw = raw;\n'
          + '    return impl_->' + snake + '(impl_->ctx, &stream);\n}\n\n');
      }
    }
    parts.push('static inline void ' + S + 'Server_register(grpcdc_server *srv, ' + S + 'ServerImpl *impl) {\n'
      + '    static const grpcdc_method_desc methods[] = {\n'
      + methods.map((m) => {
        const snake = cbSnake(m.name);
        if (m.kind === 'unary') return '        { ' + JSON.stringify(m.name) + ', 0, ' + S + '_' + snake + '_unary_adapter, 0, 0, 0 },\n';
        if (m.kind === 'server-streaming') return '        { ' + JSON.stringify(m.name) + ', 1, 0, ' + S + '_' + snake + '_sstream_adapter, 0, 0 },\n';
        if (m.kind === 'client-streaming') return '        { ' + JSON.stringify(m.name) + ', 2, 0, 0, ' + S + '_' + snake + '_cstream_adapter, 0 },\n';
        return '        { ' + JSON.stringify(m.name) + ', 3, 0, 0, 0, ' + S + '_' + snake + '_bidi_adapter },\n';
      }).join('')
      + '    };\n'
      + '    grpcdc_server_add_service(srv, ' + JSON.stringify(svc.fullName) + ', methods, sizeof(methods) / sizeof(methods[0]), impl);\n}\n\n');
  }
  const stub = {
    name: base + '_grpc_dc.h',
    content: '// @generated by protoc-gen-grpc-dc-c. DO NOT EDIT.\n'
      + '// source: ' + model.name + '\n\n'
      + '#ifndef ' + guard + '\n#define ' + guard + '\n\n'
      + '#include "grpcdc/grpcdc.h"\n'
      + (model.dependencies || []).map((d) => '#include "' + baseName(d) + '_messages.h"\n').join('')
      + (pbFiles.length ? '#include "' + base + '_messages.h"\n' : '')
      + '\n'
      + parts.join('')
      + '#endif /* ' + guard + ' */\n',
  };
  return pbFiles.length ? [stub, ...pbFiles] : stub;
}

const EMITTERS = { js: emitJsFile, c: emitCFile, go: emitGoFile, python: emitPythonFile, rust: emitRustFile, java: emitJavaFile, csharp: emitCsharpFile, cpp: emitCppFile, swift: emitSwiftFile, kotlin: emitKotlinFile, dart: emitDartFile, zig: emitZigFile, lua: emitLuaFile, ruby: emitRubyFile, php: emitPhpFile, scala: emitScalaFile, 'wasm-go': emitWasmGoFile, 'wasm-zig': emitWasmZigFile, 'wasm-cpp': emitWasmCppFile, 'wasm-swift': emitWasmSwiftFile, 'wasm-kotlin': emitWasmKotlinFile, 'wasm-scala': emitWasmScalaFile, 'kotlin-native': emitKotlinNativeFile };

export const GENERATOR_LANGUAGES = Object.keys(EMITTERS);

export function describeFiles(setBytes, entries) {
  return buildModel(setBytes, entries);
}

export function generateFiles(lang, setBytes, entries, parameter) {
  const emit = EMITTERS[lang];
  if (!emit) throw new Error('unsupported generator language: ' + lang);
  const params = parseParams(parameter || '');
  const files = [];
  for (const model of buildModel(setBytes, entries)) {
    const produced = emit(model, params);
    for (const f of Array.isArray(produced) ? produced : [produced]) if (f) files.push(f);
  }
  return files.map(stampGeneratedHeader);
}
JS
)

(define js-part-5 #<<JS
// ---------------------------------------------------------------------------
// Rust emitter (mirrors the native rust template).
// ---------------------------------------------------------------------------

function snakeCase(s) {
  let out = '';
  let prevLower = false;
  for (const c of s) {
    if (c >= 'A' && c <= 'Z') {
      if (prevLower && out.length) out += '_';
      out += c.toLowerCase();
      prevLower = false;
    } else {
      out += c;
      prevLower = true;
    }
  }
  return out;
}

function rustDeprecated(m, indent) {
  return runSegments(SEGMENT_PROGRAMS.rustDeprecated, m, '', null, [indent]);
}
function rustClientMethod(m, msgmod) {
  return runSegments(SEGMENT_PROGRAMS.rustClientMethod, m, '', null, [msgmod]);
}
function rustClientOptionsMethod(m, msgmod) {
  return runSegments(SEGMENT_PROGRAMS.rustClientOptionsMethod, m, '', null, [msgmod]);
}
function rustTraitMethod(m, msgmod) {
  return runSegments(SEGMENT_PROGRAMS.rustTraitMethodDeprecated, m, '', null, [msgmod]);
}
function rustRegisterMethod(m, serviceVar) {
  return runSegments(SEGMENT_PROGRAMS.rustRegisterMethod, m, '', null, [serviceVar]);
}
function rustService(svc, msgmod) {
  return runSegments(SEGMENT_PROGRAMS.rustService, svc, svc.name, null, [msgmod]);
}
function rpSnake(s) {
  return s.split('_').map((p) => p.toLowerCase()).join('_');
}

function rpCamel(s) {
  return s.split('_').map((p) => (p ? p[0].toUpperCase() + p.slice(1).toLowerCase() : '')).join('');
}

const RP_RUST_KEYWORDS = new Set(['type', 'ref', 'box', 'self', 'Self', 'crate', 'super', 'move', 'static', 'mut', 'fn', 'struct', 'enum', 'impl', 'trait', 'loop', 'match', 'mod', 'pub', 'use', 'where', 'async', 'await', 'dyn', 'abstract', 'become', 'do', 'final', 'macro', 'override', 'priv', 'typeof', 'unsized', 'virtual', 'yield', 'try', 'gen']);

function rpFieldName(f) {
  const name = rpSnake(f.name);
  return RP_RUST_KEYWORDS.has(name) ? 'r#' + name : name;
}

function rpFlat(pkg, full) {
  const rel = pkg && full.startsWith(pkg + '.') ? full.slice(pkg.length + 1) : full;
  return rel.split('.').join('_');
}

function rpResolve(model, typeName) {
  const entry = model.types.get(typeName);
  if (!entry) throw new Error('unresolved type ' + typeName);
  return entry;
}

function rpEntryRef(model, entry) {
  const flat = rpFlat(entry.pkg, entry.full !== undefined && entry.full !== null
    ? entry.full
    : (entry.kind === 'enum'
      ? (entry.msg ? entry.msg.fullName + '.' + entry.enum.name : (entry.pkg ? entry.pkg + '.' : '') + entry.enum.name)
      : entry.msg.fullName));
  if (entry.kind === 'map' || entry.file === model.name) return flat;
  return 'crate::' + baseName(entry.file) + '_pb::' + (entry.kind === 'enum' ? entry.enum.name : flat);
}

function rpElemType(model, f) {
  return runSegments(SEGMENT_PROGRAMS.rsPbElemType, f, '', model);
}
function rpType(model, f) {
  return runSegments(SEGMENT_PROGRAMS.rsPbType, f, '', model);
}
function rpDefault(model, f) {
  return runSegments(SEGMENT_PROGRAMS.rsPbDefault, f, '', model);
}
function rpVarintExpr(f, v) {
  return runSegments(SEGMENT_PROGRAMS.rsPbVarintExpr, f, '', null, [v]);
}
function rpVarintDecode(f, v) {
  return runSegments(SEGMENT_PROGRAMS.rsPbVarintDecode, f, '', null, [v]);
}
const RP_FIXED = FIXED_TABLES.rust;

function rpFixedInfo(f) {
  return RP_FIXED[f.type] || null;
}

function rpWire(f) {
  return rpFixedInfo(f)[0] === 8 ? 1 : 5;
}

function rpFixedEncodeExpr(f, v) {
  return runSegments(SEGMENT_PROGRAMS.rsPbFixedEncode, f, '', null, [v]);
}
function rpFixedDecodeExpr(f, src) {
  return runSegments(SEGMENT_PROGRAMS.rsPbFixedDecode, f, '', null, [src]);
}
function rpEncodeSingular(model, f, v, indent) {
  return runSegments(SEGMENT_PROGRAMS.rsPbEncodeSingular, f, '', model, [v, indent]);
}
function rpFixedEncodeExprPayload(f, v) {
  return runSegments(SEGMENT_PROGRAMS.rsPbFixedEncodePayload, f, '', null, [v]);
}
function rpEncodeField(model, f) {
  return runSegments(SEGMENT_PROGRAMS.rsPbEncodeField, f, '', model);
}
function rpDecodeSingular(model, f, target, src, indent) {
  return runSegments(SEGMENT_PROGRAMS.rsPbDecodeSingular, f, '', model, [target, src, indent]);
}
function rpOneofClearing(model, f) {
  return runSegments(SEGMENT_PROGRAMS.rsPbOneofClearing, f, '', model);
}
function rpFixedDecodeExpr32(f, src) {
  return runSegments(SEGMENT_PROGRAMS.rsPbFixedDecode32, f, '', null, [src]);
}
function rpDecodeCase(model, f) {
  return runSegments(SEGMENT_PROGRAMS.rsPbDecodeCase, f, '', model);
}
function rpDecodeSingularKv(model, f, target, field, indent) {
  return runSegments(SEGMENT_PROGRAMS.rsPbDecodeSingularKv, f, '', model, [target, field, indent]);
}
function rpMapHelpers(model, entry) {
  return runSegments(SEGMENT_PROGRAMS.rsPbMapHelpers, entry, '', model);
}
function rpEnumNamed(model, full, e) {
  return runSegments(SEGMENT_PROGRAMS.rsPbEnumNamed, e, '', model, [full]);
}
function rpMessageStruct(model, msg) {
  return runSegments(SEGMENT_PROGRAMS.rsPbMessage, msg, '', model);
}
let rpNoStd = false;
function rpMapType() {
  return rpNoStd ? 'BTreeMap' : 'std::collections::HashMap';
}

const RP_SUPPORT = 'fn pb_append_varint(out: &mut Vec<u8>, value: u64) {\n    let mut v = value;\n    while v > 0x7f {\n        out.push(((v & 0x7f) as u8) | 0x80);\n        v >>= 7;\n    }\n    out.push(v as u8);\n}\n\n'
  + 'fn pb_append_tag(out: &mut Vec<u8>, field: u32, wire: u32) {\n    pb_append_varint(out, ((field << 3) | wire) as u64);\n}\n\n'
  + 'fn pb_append_bytes_field(out: &mut Vec<u8>, field: u32, payload: &[u8]) {\n    pb_append_tag(out, field, 2);\n    pb_append_varint(out, payload.len() as u64);\n    out.extend_from_slice(payload);\n}\n\n'
  + 'fn pb_append_string_field(out: &mut Vec<u8>, field: u32, value: &str) {\n    if !value.is_empty() {\n        pb_append_bytes_field(out, field, value.as_bytes());\n    }\n}\n\n'
  + 'fn pb_append_fixed32(out: &mut Vec<u8>, value: u32) {\n    out.extend_from_slice(&value.to_le_bytes());\n}\n\n'
  + 'fn pb_append_fixed64(out: &mut Vec<u8>, value: u64) {\n    out.extend_from_slice(&value.to_le_bytes());\n}\n\n'
  + '#[derive(Clone, Debug, Default)]\nstruct PbField {\n    number: u32,\n    wire: u32,\n    varint_value: u64,\n    bytes_value: Vec<u8>,\n    fixed_value: u64,\n    raw_value: Vec<u8>,\n}\n\n'
  + 'struct PbReader<\'a> {\n    buf: &\'a [u8],\n    pos: usize,\n}\n\n'
  + 'impl<\'a> PbReader<\'a> {\n    fn new(buf: &\'a [u8]) -> Self {\n        PbReader { buf, pos: 0 }\n    }\n\n'
  + '    fn done(&self) -> bool {\n        self.pos >= self.buf.len()\n    }\n\n'
  + '    fn varint(&mut self) -> Result<u64, String> {\n        let mut result: u64 = 0;\n        let mut shift = 0;\n        loop {\n            if self.pos >= self.buf.len() {\n                return Err("truncated varint".to_string());\n            }\n            let b = self.buf[self.pos];\n            self.pos += 1;\n            result |= ((b & 0x7f) as u64) << shift;\n            if b & 0x80 == 0 {\n                return Ok(result);\n            }\n            shift += 7;\n            if shift >= 70 {\n                return Err("varint too long".to_string());\n            }\n        }\n    }\n\n'
  + '    fn take(&mut self, n: usize) -> Result<Vec<u8>, String> {\n        if self.pos + n > self.buf.len() {\n            return Err("truncated field".to_string());\n        }\n        let v = self.buf[self.pos..self.pos + n].to_vec();\n        self.pos += n;\n        Ok(v)\n    }\n\n'
  + '    fn next(&mut self) -> Result<Option<PbField>, String> {\n        if self.done() {\n            return Ok(None);\n        }\n        let start = self.pos;\n        let tag = self.varint()?;\n        let mut field = PbField {\n            number: (tag >> 3) as u32,\n            wire: (tag & 7) as u32,\n            ..Default::default()\n        };\n        match field.wire {\n            0 => field.varint_value = self.varint()?,\n            2 => {\n                let n = self.varint()? as usize;\n                field.bytes_value = self.take(n)?;\n            }\n            1 => {\n                field.bytes_value = self.take(8)?;\n                field.fixed_value = u64::from_le_bytes(field.bytes_value[..8].try_into().unwrap());\n            }\n            5 => {\n                field.bytes_value = self.take(4)?;\n                field.fixed_value = u32::from_le_bytes(field.bytes_value[..4].try_into().unwrap()) as u64;\n            }\n            _ => return Err("bad wire type".to_string()),\n        }\n        field.raw_value = self.buf[start..self.pos].to_vec();\n        Ok(Some(field))\n    }\n}\n\n';

function emitRustPbFile(model, noStd) {
  if (!model.messages.length && !model.enums.length) return null;
  const base = baseName(model.name);
  rpNoStd = !!noStd;
  let out = '// @generated by protoc-gen-grpc-dc-rust. DO NOT EDIT.\n'
    + '// source: ' + model.name + '\n'
    + '// Cross-file message types resolve to crate::<base>_pb modules.\n'
    + '#![allow(dead_code, clippy::all)]\n\n'
    + (rpNoStd ? 'extern crate alloc;\nuse alloc::{boxed::Box, collections::BTreeMap, string::{String, ToString}, vec::Vec};\n\n' : '')
    + RP_SUPPORT;
  for (const e of model.enums) {
    out += rpEnumNamed(model, (model.package === '' ? e.name : model.package + '.' + e.name), e);
  }
  // Map helpers for every map field in the file's messages.
  const seenMaps = new Set();
  const helpers = [];
  const collect = (msg) => {
    for (const f of msg.fields) {
      if (f.type === FT.MESSAGE) {
        const e = rpResolve(model, f.typeName);
        if (e.kind === 'map' && !seenMaps.has(e.msg.fullName)) {
          seenMaps.add(e.msg.fullName);
          helpers.push(rpMapHelpers(model, e));
        }
      }
    }
    for (const n of msg.nested) collect(n);
  };
  for (const m of model.messages) collect(m);
  for (const m of model.messages) {
    if (!m.mapEntry) out += rpMessageStruct(model, m);
  }
  out += helpers.join('');
  return { name: base + '_pb.rs', content: out };
}

function emitRustFile(model, params) {
  const msgmod = params.message_module || 'crate::pb';
  const base = baseName(model.name);
  const stub = {
    name: base + '_grpc_dc.rs',
    content: '// @generated by protoc-gen-grpc-dc-rust. DO NOT EDIT.\n'
      + '// source: ' + model.name + '\n'
      + '#![allow(dead_code, unused_imports, clippy::all)]\n\n'
      + model.services.map((s) => rustService(s, msgmod)).join(''),
  };
  const pb = emitRustPbFile(model, params.rust_no_std === 'true' || params.rust_no_std === '1');
  return pb ? [stub, pb] : stub;
}

JS
)

(define js-part-6 #<<JS
// ---------------------------------------------------------------------------
// Java emitter (mirrors the native java template).
// ---------------------------------------------------------------------------

function pascalName(s) {
  // The native templates define pascal via string-split with a
  // *string* separator, which the template treats literally — so no
  // split ever happens and pascal is just capitalize-first.
  return s ? s[0].toUpperCase() + s.slice(1) : s;
}

function javaDeprecated(m, indent) {
  return m.deprecated ? indent + '@Deprecated\n' : '';
}

function javaClientMethodRaw(m, svc) {
  const name = m.name;
  const req = m.input;
  const resp = m.output;
  const path = q(m.path);
  switch (m.kind) {
    case 'unary':
      return '        public ' + resp + ' ' + name + '(' + req + ' req, Map<String, String> metadata) throws Exception {\n'
        + '            ' + resp + ' resp = new ' + resp + '();\n'
        + '            channel.unary(' + path + ', req, resp, metadata);\n'
        + '            return resp;\n        }\n\n'
        + '        public ' + resp + ' ' + name + '(' + req + ' req) throws Exception {\n'
        + '            return ' + name + '(req, null);\n        }\n';
    case 'server-streaming':
      return '        public ' + svc + name + 'Stream ' + name + '(' + req + ' req, Map<String, String> metadata) throws Exception {\n'
        + '            return new ' + svc + name + 'Stream(channel.serverStream(' + path + ', req, metadata));\n        }\n\n'
        + '        public ' + svc + name + 'Stream ' + name + '(' + req + ' req) throws Exception {\n'
        + '            return ' + name + '(req, null);\n        }\n';
    case 'client-streaming':
      return '        public ' + resp + ' ' + name + '(List<' + req + '> reqs, Map<String, String> metadata) throws Exception {\n'
        + '            ' + resp + ' resp = new ' + resp + '();\n'
        + '            channel.clientStream(' + path + ', reqs, resp, metadata);\n'
        + '            return resp;\n        }\n\n'
        + '        public ' + resp + ' ' + name + '(List<' + req + '> reqs) throws Exception {\n'
        + '            return ' + name + '(reqs, null);\n        }\n';
    default:
      return '        public ' + svc + name + 'Stream ' + name + '(List<' + req + '> reqs, Map<String, String> metadata) throws Exception {\n'
        + '            return new ' + svc + name + 'Stream(channel.bidi(' + path + ', reqs, metadata));\n        }\n\n'
        + '        public ' + svc + name + 'Stream ' + name + '(List<' + req + '> reqs) throws Exception {\n'
        + '            return ' + name + '(reqs, null);\n        }\n';
  }
}

function javaClientTimeoutMethod(m, svc) {
  const name = m.name;
  const req = m.input;
  const resp = m.output;
  const path = q(m.path);
  switch (m.kind) {
    case 'unary':
      return '\n        /** Deadline variant: timeout propagates as grpc-timeout; expiry raises DEADLINE_EXCEEDED. */\n'
        + '        public ' + resp + ' ' + name + '(' + req + ' req, Map<String, String> metadata, java.time.Duration timeout) throws Exception {\n'
        + '            ' + resp + ' resp = new ' + resp + '();\n'
        + '            channel.unary(' + path + ', req, resp, metadata, timeout);\n'
        + '            return resp;\n        }\n';
    case 'server-streaming':
      return '\n        /** Deadline variant of ' + name + '. */\n'
        + '        public ' + svc + name + 'Stream ' + name + '(' + req + ' req, Map<String, String> metadata, java.time.Duration timeout) throws Exception {\n'
        + '            return new ' + svc + name + 'Stream(channel.serverStream(' + path + ', req, metadata, timeout));\n        }\n';
    case 'client-streaming':
      return '\n        /** Deadline variant of ' + name + '. */\n'
        + '        public ' + resp + ' ' + name + '(List<' + req + '> reqs, Map<String, String> metadata, java.time.Duration timeout) throws Exception {\n'
        + '            ' + resp + ' resp = new ' + resp + '();\n'
        + '            channel.clientStream(' + path + ', reqs, resp, metadata, timeout);\n'
        + '            return resp;\n        }\n';
    default:
      return '\n        /** Deadline variant of ' + name + '. */\n'
        + '        public ' + svc + name + 'Stream ' + name + '(List<' + req + '> reqs, Map<String, String> metadata, java.time.Duration timeout) throws Exception {\n'
        + '            return new ' + svc + name + 'Stream(channel.bidi(' + path + ', reqs, metadata, timeout));\n        }\n';
  }
}

function javaClientStreamClass(m, svc) {
  if (m.kind !== 'server-streaming' && m.kind !== 'bidi') return '';
  return '    /** Receiving stream for ' + svc + '.' + m.name + ': recv() throws EOFException at end. Close to abandon early (RST). */\n'
    + '    public static final class ' + svc + m.name + 'Stream implements AutoCloseable {\n'
    + '        private final Channel.ClientStream stream;\n\n'
    + '        ' + svc + m.name + 'Stream(Channel.ClientStream stream) {\n'
    + '            this.stream = stream;\n        }\n\n'
    + '        public ' + m.output + ' recv() throws Exception {\n'
    + '            ' + m.output + ' resp = new ' + m.output + '();\n'
    + '            stream.recv(resp);\n            return resp;\n        }\n\n'
    + '        /** Initial metadata (response headers); null until they arrive. */\n'
    + '        public Map<String, String> headers() {\n'
    + '            return stream.headers() == null ? null : stream.headers().metadata;\n        }\n\n'
    + '        /** Trailing metadata of the terminal status; null until it arrives. */\n'
    + '        public Map<String, String> trailers() {\n'
    + '            return stream.trailers();\n        }\n\n'
    + '        /** Abort this stream (sends RST, wakes a pending recv). */\n'
    + '        public void cancel() {\n'
    + '            stream.cancel();\n        }\n\n'
    + '        /** Abandon the call if still live (RST); no-op once terminated. */\n'
    + '        @Override\n'
    + '        public void close() {\n'
    + '            stream.close();\n        }\n    }\n\n';
}

function javaServerIfaceMethodRaw(m, svc) {
  switch (m.kind) {
    case 'unary':
      return '        ' + m.output + ' ' + m.name + '(Endpoint.CallContext ctx, ' + m.input + ' req) throws Exception;\n';
    case 'server-streaming':
      return '        void ' + m.name + '(' + m.input + ' req, ' + svc + m.name + 'Server stream) throws Exception;\n';
    default:
      return '        void ' + m.name + '(' + svc + m.name + 'Server stream) throws Exception;\n';
  }
}

function javaServerStreamIfaces(m, svc) {
  switch (m.kind) {
    case 'unary':
      return '';
    case 'server-streaming':
      return '    /** Server-streaming sink passed to service implementations. */\n'
        + '    public interface ' + svc + m.name + 'Server {\n'
        + '        void send(' + m.output + ' resp) throws Exception;\n'
        + '        Endpoint.CallContext context();\n    }\n\n';
    case 'client-streaming':
      return '    /** Client-streaming stream passed to service implementations. */\n'
        + '    public interface ' + svc + m.name + 'Server {\n'
        + '        ' + m.input + ' recv() throws Exception;\n'
        + '        void sendAndClose(' + m.output + ' resp) throws Exception;\n'
        + '        Endpoint.CallContext context();\n    }\n\n';
    default:
      return '    /** Bidi stream passed to service implementations. */\n'
        + '    public interface ' + svc + m.name + 'Server {\n'
        + '        void send(' + m.output + ' resp) throws Exception;\n'
        + '        ' + m.input + ' recv() throws Exception;\n'
        + '        Endpoint.CallContext context();\n    }\n\n';
  }
}

const JAVA_KIND_CONSTS = {
  unary: 'KIND_UNARY',
  'server-streaming': 'KIND_SERVER_STREAMING',
  'client-streaming': 'KIND_CLIENT_STREAMING',
  bidi: 'KIND_BIDI',
};

function javaRegisterMethod(m, svc) {
  const impl = m.implName;
  const head = '                    new Server.Method(' + q(m.name) + ', ' + q(m.path) + ', Server.' + JAVA_KIND_CONSTS[m.kind] + ', (ctx, reqs, sink) -> {\n';
  switch (m.kind) {
    case 'unary':
      return head
        + '                        ' + m.input + ' req = new ' + m.input + '();\n'
        + '                        reqs.recvInto(req);\n'
        + '                        sink.send(impl.' + impl + '(ctx, req).marshalDc());\n'
        + '                    }),\n';
    case 'server-streaming':
      return head
        + '                        ' + m.input + ' req = new ' + m.input + '();\n'
        + '                        reqs.recvInto(req);\n'
        + '                        impl.' + impl + '(req, new ' + svc + impl + 'ServerImpl(ctx, sink));\n'
        + '                    }),\n';
    case 'client-streaming':
      return head
        + '                        ' + svc + impl + 'ServerImpl stream = new ' + svc + impl + 'ServerImpl(ctx, reqs);\n'
        + '                        impl.' + impl + '(stream);\n'
        + '                        if (stream.resp == null) {\n'
        + '                            throw new StatusException(Wire.CODE_INTERNAL,\n'
        + '                                    "client-streaming handler never called SendAndClose");\n'
        + '                        }\n'
        + '                        sink.send(stream.resp.marshalDc());\n'
        + '                    }),\n';
    default:
      return head
        + '                        impl.' + impl + '(new ' + svc + impl + 'ServerImpl(ctx, reqs, sink));\n'
        + '                    }),\n';
  }
}

function javaStreamImpls(m, svc) {
  const head = '    private static final class ' + svc + m.name + 'ServerImpl implements ' + svc + m.name + 'Server {\n';
  switch (m.kind) {
    case 'unary':
      return '';
    case 'server-streaming':
      return head
        + '        private final Endpoint.CallContext ctx;\n'
        + '        private final Server.ServerSink sink;\n\n'
        + '        ' + svc + m.name + 'ServerImpl(Endpoint.CallContext ctx, Server.ServerSink sink) {\n'
        + '            this.ctx = ctx;\n            this.sink = sink;\n        }\n\n'
        + '        public void send(' + m.output + ' resp) throws Exception {\n'
        + '            sink.send(resp.marshalDc());\n        }\n\n'
        + '        public Endpoint.CallContext context() {\n            return ctx;\n        }\n    }\n\n';
    case 'client-streaming':
      return head
        + '        private final Endpoint.CallContext ctx;\n'
        + '        private final Server.RequestStream reqs;\n'
        + '        ' + m.output + ' resp;\n\n'
        + '        ' + svc + m.name + 'ServerImpl(Endpoint.CallContext ctx, Server.RequestStream reqs) {\n'
        + '            this.ctx = ctx;\n            this.reqs = reqs;\n        }\n\n'
        + '        public ' + m.input + ' recv() throws Exception {\n'
        + '            ' + m.input + ' req = new ' + m.input + '();\n'
        + '            reqs.recvInto(req);\n            return req;\n        }\n\n'
        + '        public void sendAndClose(' + m.output + ' resp) {\n'
        + '            this.resp = resp;\n        }\n\n'
        + '        public Endpoint.CallContext context() {\n            return ctx;\n        }\n    }\n\n';
    default:
      return head
        + '        private final Endpoint.CallContext ctx;\n'
        + '        private final Server.RequestStream reqs;\n'
        + '        private final Server.ServerSink sink;\n\n'
        + '        ' + svc + m.name + 'ServerImpl(Endpoint.CallContext ctx, Server.RequestStream reqs, Server.ServerSink sink) {\n'
        + '            this.ctx = ctx;\n            this.reqs = reqs;\n            this.sink = sink;\n        }\n\n'
        + '        public void send(' + m.output + ' resp) throws Exception {\n'
        + '            sink.send(resp.marshalDc());\n        }\n\n'
        + '        public ' + m.input + ' recv() throws Exception {\n'
        + '            ' + m.input + ' req = new ' + m.input + '();\n'
        + '            reqs.recvInto(req);\n            return req;\n        }\n\n'
        + '        public Endpoint.CallContext context() {\n            return ctx;\n        }\n    }\n\n';
  }
}

function javaClientAsyncMethod(m, svc) {
  const name = m.name;
  const req = m.input;
  const resp = m.output;
  switch (m.kind) {
    case 'unary':
      return '        public CompletableFuture<' + resp + '> ' + name + 'Async(' + req + ' req, Map<String, String> metadata) {\n'
        + '            return CompletableFuture.supplyAsync(() -> {\n'
        + '                try {\n                    return ' + name + '(req, metadata);\n'
        + '                } catch (Exception e) {\n                    throw new CompletionException(e);\n                }\n            });\n        }\n\n'
        + '        public CompletableFuture<' + resp + '> ' + name + 'Async(' + req + ' req) {\n'
        + '            return ' + name + 'Async(req, null);\n        }\n';
    case 'server-streaming':
      return '        /** Collect-all async convenience over the blocking stream. */\n'
        + '        public CompletableFuture<List<' + resp + '>> ' + name + 'AllAsync(' + req + ' req, Map<String, String> metadata) {\n'
        + '            return CompletableFuture.supplyAsync(() -> {\n'
        + '                try {\n                    List<' + resp + '> out = new ArrayList<>();\n'
        + '                    ' + svc + name + 'Stream stream = ' + name + '(req, metadata);\n'
        + '                    while (true) {\n                        try {\n                            out.add(stream.recv());\n'
        + '                        } catch (java.io.EOFException eof) {\n                            return out;\n                        }\n                    }\n'
        + '                } catch (Exception e) {\n                    throw new CompletionException(e);\n                }\n            });\n        }\n\n'
        + '        public CompletableFuture<List<' + resp + '>> ' + name + 'AllAsync(' + req + ' req) {\n'
        + '            return ' + name + 'AllAsync(req, null);\n        }\n';
    case 'client-streaming':
      return '        public CompletableFuture<' + resp + '> ' + name + 'Async(List<' + req + '> reqs, Map<String, String> metadata) {\n'
        + '            return CompletableFuture.supplyAsync(() -> {\n'
        + '                try {\n                    return ' + name + '(reqs, metadata);\n'
        + '                } catch (Exception e) {\n                    throw new CompletionException(e);\n                }\n            });\n        }\n\n'
        + '        public CompletableFuture<' + resp + '> ' + name + 'Async(List<' + req + '> reqs) {\n'
        + '            return ' + name + 'Async(reqs, null);\n        }\n';
    default:
      return '        /** Collect-all async convenience over the blocking stream. */\n'
        + '        public CompletableFuture<List<' + resp + '>> ' + name + 'AllAsync(List<' + req + '> reqs, Map<String, String> metadata) {\n'
        + '            return CompletableFuture.supplyAsync(() -> {\n'
        + '                try {\n                    List<' + resp + '> out = new ArrayList<>();\n'
        + '                    ' + svc + name + 'Stream stream = ' + name + '(reqs, metadata);\n'
        + '                    while (true) {\n                        try {\n                            out.add(stream.recv());\n'
        + '                        } catch (java.io.EOFException eof) {\n                            return out;\n                        }\n                    }\n'
        + '                } catch (Exception e) {\n                    throw new CompletionException(e);\n                }\n            });\n        }\n\n'
        + '        public CompletableFuture<List<' + resp + '>> ' + name + 'AllAsync(List<' + req + '> reqs) {\n'
        + '            return ' + name + 'AllAsync(reqs, null);\n        }\n';
  }
}

function javaServerAsyncIfaceMethod(m, svc) {
  switch (m.kind) {
    case 'unary':
      return '        CompletableFuture<' + m.output + '> ' + m.name + 'Async(Endpoint.CallContext ctx, ' + m.input + ' req);\n';
    case 'server-streaming':
      return '        CompletableFuture<Void> ' + m.name + 'Async(' + m.input + ' req, ' + svc + m.name + 'Server stream);\n';
    default:
      return '        CompletableFuture<Void> ' + m.name + 'Async(' + svc + m.name + 'Server stream);\n';
  }
}

const JAVA_ADAPTER_CATCH =
  '            } catch (CompletionException e) {\n'
  + '                Throwable cause = e.getCause();\n'
  + '                if (cause instanceof Exception ex) throw ex;\n'
  + '                throw e;\n            }\n';

function javaServerAsyncAdapterMethod(m, svc) {
  switch (m.kind) {
    case 'unary':
      return '        public ' + m.output + ' ' + m.name + '(Endpoint.CallContext ctx, ' + m.input + ' req) throws Exception {\n'
        + '            try {\n                return impl.' + m.name + 'Async(ctx, req).join();\n'
        + JAVA_ADAPTER_CATCH + '        }\n\n';
    case 'server-streaming':
      return '        public void ' + m.name + '(' + m.input + ' req, ' + svc + m.name + 'Server stream) throws Exception {\n'
        + '            try {\n                impl.' + m.name + 'Async(req, stream).join();\n'
        + JAVA_ADAPTER_CATCH + '        }\n\n';
    default:
      return '        public void ' + m.name + '(' + svc + m.name + 'Server stream) throws Exception {\n'
        + '            try {\n                impl.' + m.name + 'Async(stream).join();\n'
        + JAVA_ADAPTER_CATCH + '        }\n\n';
  }
}

function javaService(svc) {
  const sname = svc.name;
  const all = svc.methods.concat(aliasClientMethods(svc));
  return '    /** Client for ' + svc.fullName + '. */\n'
    + '    public static final class ' + sname + 'Client {\n'
    + '        private final Channel channel;\n\n'
    + '        public ' + sname + 'Client(Channel channel) {\n            this.channel = channel;\n        }\n\n'
    + all.map((m) => javaDeprecated(m, '        ') + javaClientMethodRaw(m, sname) + javaClientTimeoutMethod(m, sname)).join('')
    + all.map((m) => javaClientAsyncMethod(m, sname)).join('')
    + '    }\n\n'
    + svc.methods.map((m) => javaClientStreamClass(m, sname)).join('')
    + '    /** Service implementation interface for ' + svc.fullName + '. */\n'
    + '    public interface ' + sname + 'Server {\n'
    + svc.methods.map((m) => javaDeprecated(m, '        ') + javaServerIfaceMethodRaw(m, sname)).join('')
    + '    }\n\n'
    + svc.methods.map((m) => javaServerStreamIfaces(m, sname)).join('')
    + svc.methods.map((m) => javaStreamImpls(m, sname)).join('')
    + '    /** Async service implementation interface for ' + svc.fullName + '. */\n'
    + '    public interface ' + sname + 'ServerAsync {\n'
    + svc.methods.map((m) => javaServerAsyncIfaceMethod(m, sname)).join('')
    + '    }\n\n'
    + '    private static final class ' + sname + 'ServerAsyncAdapter implements ' + sname + 'Server {\n'
    + '        private final ' + sname + 'ServerAsync impl;\n\n'
    + '        ' + sname + 'ServerAsyncAdapter(' + sname + 'ServerAsync impl) {\n            this.impl = impl;\n        }\n\n'
    + svc.methods.map((m) => javaServerAsyncAdapterMethod(m, sname)).join('')
    + '    }\n\n'
    + '    /** Register an implementation of ' + svc.fullName + ' on a Server. */\n'
    + '    public static void register' + sname + 'Server(Server server, ' + sname + 'Server impl) {\n'
    + '        server.registerService(new Server.ServiceDesc(\n                ' + q(svc.fullName) + ',\n                List.of(\n'
    + svc.methods.concat(aliasServerMethods(svc)).map((m) => javaRegisterMethod(m, sname).replace(/\}\),[ \t\r\n]*$/, '})')).join(',\n')
    + '\n                )));\n    }\n'
    + '    /** Register an async implementation of ' + svc.fullName + ' on a Server. */\n'
    + '    public static void register' + sname + 'ServerAsync(Server server, ' + sname + 'ServerAsync impl) {\n'
    + '        register' + sname + 'Server(server, new ' + sname + 'ServerAsyncAdapter(impl));\n    }\n';
}


// ---------------------------------------------------------------------------
// Java message types, mirroring the native java template (the jp*
// functions): one public class per top-level message and enum,
// plus a package-private <Base>Pb wire-support class per proto
// file. Byte-identical to the native protoc-gen-grpc-dc-java
// plugin.
// ---------------------------------------------------------------------------

const JP_VARINT = new Set(VARINT_TYPES);
const JP_FIXED = FIXED_TABLES.java;

function jpCamel(s) {
  const parts = s.split('_');
  if (!parts.length) return s;
  return parts[0] + parts.slice(1).map((p) => (p ? p[0].toUpperCase() + p.slice(1) : '')).join('');
}

function jpFieldName(f) {
  return f.jsonName ? f.jsonName : jpCamel(f.name);
}

function jpResolve(model, typeName) {
  const entry = model.types.get(typeName);
  if (!entry) throw new Error('unresolved type ' + typeName);
  return entry;
}

function jpRel(pkg, full) {
  const rel = pkg && full.startsWith(pkg + '.') ? full.slice(pkg.length + 1) : full;
  return rel.split('.').join('.');
}

function jpEntryRef(model, entry) {
  const rel = entry.kind === 'enum'
    ? (entry.msg
      ? jpRel(entry.pkg, entry.msg.fullName) + '.' + entry.enum.name
      : jpRel(entry.pkg, (entry.pkg ? entry.pkg + '.' : '') + entry.enum.name))
    : jpRel(entry.pkg, entry.msg.fullName);
  if (entry.file === model.name) return rel;
  return entry.pkg === '' ? rel : entry.pkg + '.' + rel;
}

function jpScalar(f) {
  // Leaf payloads single-sourced from scalar-type-tables
  // in spec.rkt (SCALAR_TABLES), same table the native
  // template derives from.
  return SCALAR_TABLES.java.types[f.type] ?? SCALAR_TABLES.java.default;
}

function jpType(model, f, boxed) {
  let singular;
  if (f.type === FT.MESSAGE) {
    const entry = jpResolve(model, f.typeName);
    if (entry.kind === 'map') {
      const kf = entry.msg.fields.find((x) => x.number === 1);
      const vf = entry.msg.fields.find((x) => x.number === 2);
      singular = 'java.util.Map<' + jpType(model, { ...kf, label: 1 }, true) + ', ' + jpType(model, { ...vf, label: 1 }, true) + '>';
    } else {
      singular = jpEntryRef(model, entry);
    }
  } else if (f.type === FT.ENUM) {
    singular = jpEntryRef(model, jpResolve(model, f.typeName));
  } else {
    const s = jpScalar(f);
    singular = boxed ? s[1] : s[0];
  }
  if (f.type === FT.MESSAGE && jpResolve(model, f.typeName).kind === 'map') return singular;
  if (f.label === 3) return 'java.util.List<' + jpType(model, { ...f, label: 1 }, true) + '>';
  return singular;
}

function jpExplicitLiteral(model, f) {
  const d = fieldExplicitDefault(f);
  if (d === null) return null;
  switch (f.type) {
    case 9: return JSON.stringify(d);
    case 8: return d;
    case 14: return jpEntryRef(model, jpResolve(model, f.typeName)) + '.' + d;
    case 2: return d + 'f';
    default: return d;
  }
}

function jpBoxedDefault(model, f) {
  if (f.type === 1) return '0.0';
  if (f.type === 2) return '0.0f';
  return jpDefault(model, f);
}

function jpDefault(model, f) {
  const lit = jpExplicitLiteral(model, f);
  if (lit !== null) return lit;
  if (f.type === FT.MESSAGE && jpResolve(model, f.typeName).kind === 'map') return 'new java.util.LinkedHashMap<>()';
  if (f.label === 3) return 'new java.util.ArrayList<>()';
  if (f.type === FT.MESSAGE) return 'null';
  if (f.type === FT.ENUM) {
    const entry = jpResolve(model, f.typeName);
    return jpEntryRef(model, entry) + '.' + entry.enum.values[0].name;
  }
  return jpScalar(f)[2];
}

function jpVarintExpr(f, v) {
  switch (f.type) {
    case 8: return '(' + v + ' ? 1 : 0)';
    case 17: return '((' + v + ' << 1) ^ (' + v + ' >> 31))';
    case 18: return '((' + v + ' << 1) ^ (' + v + ' >> 63))';
    default: return v;
  }
}

function jpVarintDecode(f, v) {
  switch (f.type) {
    case 5: case 14: case 13: return '(int) ' + v;
    case 3: case 4: return v;
    case 8: return v + ' != 0';
    case 17: return '(int) ((' + v + ' >>> 1) ^ -(' + v + ' & 1))';
    case 18: return '((' + v + ' >>> 1) ^ -(' + v + ' & 1))';
    default: throw new Error('not a varint type');
  }
}

function jpNonzero(f, v) {
  switch (f.type) {
    case 8: return v;
    case 14: return v + ' != null && ' + v + '.number != 0';
    default: return v + ' != 0';
  }
}

function jpFixedBits(info, f, v) {
  return v;
}

function jpEncodeSingular(model, f, v, indent, support) {
  const n = f.number;
  const proto2 = model.syntax === 'proto2';
  if (JP_VARINT.has(f.type)) {
    const expr = f.type === 14 ? v + '.number' : jpVarintExpr(f, v);
    if (proto2) return indent + '{ w.tag(' + n + ', 0); w.varint(' + expr + '); }\n';
    return indent + 'if (' + jpNonzero(f, v) + ') { w.tag(' + n + ', 0); w.varint(' + expr + '); }\n';
  }
  const fixed = JP_FIXED[f.type];
  if (fixed) {
    const wire = fixed[0] === 8 ? 1 : 5;
    if (proto2) return indent + '{ w.tag(' + n + ', ' + wire + '); w.fixed' + fixed[1] + '(' + jpFixedBits(fixed, f, v) + '); }\n';
    return indent + 'if (' + jpNonzero(f, v) + ') { w.tag(' + n + ', ' + wire + '); w.fixed' + fixed[1] + '(' + jpFixedBits(fixed, f, v) + '); }\n';
  }
  switch (f.type) {
    case 9: return proto2
      ? indent + 'if (' + v + ' != null) w.bytesField(' + n + ', ' + v + '.getBytes(java.nio.charset.StandardCharsets.UTF_8));\n'
      : indent + 'w.stringField(' + n + ', ' + v + ');\n';
    case 12: return proto2
      ? indent + 'if (' + v + ' != null) w.bytesField(' + n + ', ' + v + ');\n'
      : indent + 'if (' + v + ' != null && ' + v + '.length > 0) w.bytesField(' + n + ', ' + v + ');\n';
    case 11: return indent + 'if (' + v + ' != null) w.bytesField(' + n + ', ' + v + '.marshalDc());\n';
    default: throw new Error('unsupported field type ' + f.type + ' (groups)');
  }
}

function jpSetExpr(sib) {
  const v = jpFieldName(sib);
  switch (sib.type) {
    case 11: case 10: return v + ' != null';
    case 9: return '(' + v + ' != null && !' + v + '.isEmpty())';
    case 12: return '(' + v + ' != null && ' + v + '.length > 0)';
    default: return jpNonzero(sib, v);
  }
}

// Encode-side oneof clearing: suppress f when a later sibling is
// set, so only the winning member is written.
function jpEncodeGuard(model, f, code) {
  const later = oneofLaterSiblings(model, f);
  if (!later.length) return code;
  return '        if (!(' + later.map(jpSetExpr).join(' || ') + ')) {\n' + (code.endsWith('\n') ? code : code + '\n') + '        }\n';
}

function jpEncodeField(model, f, support) {
  const v = jpFieldName(f);
  const n = f.number;
  if (f.type === FT.MESSAGE && jpResolve(model, f.typeName).kind === 'map') {
    const entry = jpResolve(model, f.typeName);
    const helper = support + '.' + jpMapHelperName(model, entry) + 'Encode';
    const kf = entry.msg.fields.find((x) => x.number === 1);
    const vf = entry.msg.fields.find((x) => x.number === 2);
    return '        if (' + v + ' != null) for (java.util.Map.Entry<' + jpType(model, { ...kf, label: 1 }, true) + ', ' + jpType(model, { ...vf, label: 1 }, true) + '> e : ' + v + '.entrySet()) w.bytesField(' + n + ', ' + helper + '(e.getKey(), e.getValue()));\n';
  }
  if (f.label !== 3) return jpEncodeSingular(model, f, v, '        ', support);
  if (JP_VARINT.has(f.type)) {
    return '        if (' + v + ' != null && !' + v + '.isEmpty()) {\n'
      + '            ' + support + '.Writer payload = new ' + support + '.Writer();\n'
      + '            for (' + jpType(model, { ...f, label: 1 }, true) + ' x : ' + v + ') payload.varint(' + (f.type === 14 ? 'x.number' : jpVarintExpr(f, 'x')) + ');\n'
      + '            w.bytesField(' + n + ', payload.toBytes());\n        }\n';
  }
  const fixed = JP_FIXED[f.type];
  if (fixed) {
    return '        if (' + v + ' != null && !' + v + '.isEmpty()) {\n'
      + '            ' + support + '.Writer payload = new ' + support + '.Writer();\n'
      + '            for (' + jpType(model, { ...f, label: 1 }, true) + ' x : ' + v + ') payload.fixed' + fixed[1] + '(' + jpFixedBits(fixed, f, 'x') + ');\n'
      + '            w.bytesField(' + n + ', payload.toBytes());\n        }\n';
  }
  switch (f.type) {
    case 9: return '        if (' + v + ' != null) for (String x : ' + v + ') w.bytesField(' + n + ', x.getBytes(java.nio.charset.StandardCharsets.UTF_8));\n';
    case 12: return '        if (' + v + ' != null) for (byte[] x : ' + v + ') w.bytesField(' + n + ', x);\n';
    case 11: return '        if (' + v + ' != null) for (' + jpType(model, { ...f, label: 1 }, true) + ' x : ' + v + ') w.bytesField(' + n + ', x.marshalDc());\n';
    default: throw new Error('unsupported repeated field type ' + f.type);
  }
}

function jpDecodeSingular(model, f, target, src, indent) {
  if (JP_VARINT.has(f.type)) {
    return indent + target + ' = ' + (f.type === 14
      ? jpEntryRef(model, jpResolve(model, f.typeName)) + '.fromNumber(' + jpVarintDecode({ ...f, type: 5 }, src) + ')'
      : jpVarintDecode(f, src)) + ';\n';
  }
  if (JP_FIXED[f.type]) {
    let conv;
    switch (f.type) {
      case 2: conv = 'Float.intBitsToFloat((int) ' + src + ')'; break;
      case 1: conv = 'Double.longBitsToDouble(' + src + ')'; break;
      case 7: case 15: conv = '(int) ' + src; break;
      default: conv = src;
    }
    return indent + target + ' = ' + conv + ';\n';
  }
  switch (f.type) {
    case 9: return indent + target + ' = new String(' + src + ', java.nio.charset.StandardCharsets.UTF_8);\n';
    case 12: return indent + target + ' = ' + src + ';\n';
    case 11: {
      const ref = jpEntryRef(model, jpResolve(model, f.typeName));
      return indent + target + ' = new ' + ref + '();\n' + indent + target + '.unmarshalDc(' + src + ');\n';
    }
    default: throw new Error('unsupported field type ' + f.type);
  }
}

function jpOneofClearing(model, f) {
  return oneofSiblings(model, f).map((sib) => '                    ' + jpFieldName(sib) + ' = ' + jpDefault(model, sib) + ';\n').join('');
}

function jpDecodeCase(model, f, support) {
  const v = jpFieldName(f);
  const head = '                case ' + f.number + ' -> {\n';
  const tail = '                }\n';
  if (f.type === FT.MESSAGE && jpResolve(model, f.typeName).kind === 'map') {
    const entry = jpResolve(model, f.typeName);
    const helper = support + '.' + jpMapHelperName(model, entry) + 'Decode';
    const kf = entry.msg.fields.find((x) => x.number === 1);
    const vf = entry.msg.fields.find((x) => x.number === 2);
    return head
      + '                    Object[] kv = ' + helper + '(field.bytesValue);\n'
      + '                    ' + v + '.put((' + jpType(model, { ...kf, label: 1 }, true) + ') kv[0], (' + jpType(model, { ...vf, label: 1 }, true) + ') kv[1]);\n'
      + tail;
  }
  if (f.label !== 3) {
    const src = JP_VARINT.has(f.type) ? 'field.varintValue' : (JP_FIXED[f.type] ? 'field.fixedValue' : 'field.bytesValue');
    return head + jpOneofClearing(model, f) + jpDecodeSingular(model, f, v, src, '                    ') + tail;
  }
  if (JP_VARINT.has(f.type)) {
    const conv = (src) => f.type === 14
      ? jpEntryRef(model, jpResolve(model, f.typeName)) + '.fromNumber(' + jpVarintDecode({ ...f, type: 5 }, src) + ')'
      : jpVarintDecode(f, src);
    return head
      + '                    if (field.wire == 2) {\n'
      + '                        ' + support + '.Reader sub = new ' + support + '.Reader(field.bytesValue);\n'
      + '                        while (!sub.done()) {\n'
      + '                            ' + v + '.add(' + conv('sub.varint()') + ');\n'
      + '                        }\n                    } else {\n'
      + '                        ' + v + '.add(' + conv('field.varintValue') + ');\n'
      + '                    }\n'
      + tail;
  }
  if (JP_FIXED[f.type]) {
    const subConv = f.type === 2 ? 'Float.intBitsToFloat(sub.fixed32())'
      : f.type === 1 ? 'Double.longBitsToDouble(sub.fixed64())'
      : (f.type === 7 || f.type === 15) ? 'sub.fixed32()' : 'sub.fixed64()';
    const oneConv = f.type === 2 ? 'Float.intBitsToFloat((int) field.fixedValue)'
      : f.type === 1 ? 'Double.longBitsToDouble(field.fixedValue)'
      : (f.type === 7 || f.type === 15) ? '(int) field.fixedValue' : 'field.fixedValue';
    return head
      + '                    if (field.wire == 2) {\n'
      + '                        ' + support + '.Reader sub = new ' + support + '.Reader(field.bytesValue);\n'
      + '                        while (!sub.done()) ' + v + '.add(' + subConv + ');\n'
      + '                    } else {\n'
      + '                        ' + v + '.add(' + oneConv + ');\n'
      + '                    }\n'
      + tail;
  }
  switch (f.type) {
    case 9: return head + '                    ' + v + '.add(new String(field.bytesValue, java.nio.charset.StandardCharsets.UTF_8));\n' + tail;
    case 12: return head + '                    ' + v + '.add(field.bytesValue);\n' + tail;
    case 11: return head
      + '                    ' + jpType(model, { ...f, label: 1 }, true) + ' item = new ' + jpType(model, { ...f, label: 1 }, true) + '();\n'
      + '                    item.unmarshalDc(field.bytesValue);\n'
      + '                    ' + v + '.add(item);\n'
      + tail;
    default: throw new Error('unsupported repeated field type ' + f.type);
  }
}

function jpMapHelperName(model, entry) {
  return jpRel(entry.pkg, entry.msg.fullName).split('.').join('');
}

function jpDecodeSingularStmt(model, f, target) {
  const src = JP_VARINT.has(f.type) ? 'field.varintValue' : (JP_FIXED[f.type] ? 'field.fixedValue' : 'field.bytesValue');
  return jpDecodeSingular(model, f, target, src, '').replace(/\n+$/, '');
}

function jpMapHelpers(model, entry, support) {
  const msg = entry.msg;
  const base = jpMapHelperName(model, entry);
  const keyF = msg.fields.find((x) => x.number === 1);
  const valF = msg.fields.find((x) => x.number === 2);
  if (!keyF || !valF) throw new Error('map entry lacks key/value');
  const kt = jpType(model, { ...keyF, label: 1 }, true);
  const vt = jpType(model, { ...valF, label: 1 }, true);
  return '    static byte[] ' + base + 'Encode(' + kt + ' key, ' + vt + ' value) {\n'
    + '        Writer w = new Writer();\n'
    + jpEncodeSingular(model, { ...keyF, label: 1 }, 'key', '        ', support)
    + jpEncodeSingular(model, { ...valF, label: 1 }, 'value', '        ', support)
    + '        return w.toBytes();\n    }\n\n'
    + '    static Object[] ' + base + 'Decode(byte[] bytes) {\n'
    + '        ' + kt + ' key = ' + jpBoxedDefault(model, { ...keyF, label: 1 }) + ';\n'
    + '        ' + vt + ' value = ' + jpBoxedDefault(model, { ...valF, label: 1 }) + ';\n'
    + '        Reader r = new Reader(bytes);\n        Field field;\n        while ((field = r.next()) != null) {\n            switch (field.number) {\n'
    + '                case ' + keyF.number + ': ' + jpDecodeSingularStmt(model, { ...keyF, label: 1 }, 'key') + ' break;\n'
    + '                case ' + valF.number + ': ' + jpDecodeSingularStmt(model, { ...valF, label: 1 }, 'value') + ' break;\n'
    + '                default: break;\n            }\n        }\n        return new Object[] { key, value };\n    }\n\n';
}

function jpEnumValues(e) {
  return e.values.map((v) => '        ' + v.name + '(' + v.number + ')').join(',\n') + ';\n';
}

function jpEnumBody(e, indent) {
  return indent + 'public final int number;\n'
    + indent + e.name + '(int number) { this.number = number; }\n'
    + indent + 'public static ' + e.name + ' fromNumber(int number) {\n'
    + indent + '    switch (number) {\n'
    + e.values.map((v) => indent + '        case ' + v.number + ': return ' + v.name + ';\n').join('')
    + indent + '        default: return ' + e.values[0].name + ';\n    }\n}\n';
}

function jpNestedEnum(model, msg, e) {
  return '        public enum ' + e.name + ' {\n'
    + jpEnumValues(e)
    + jpEnumBody(e, '            ')
    + '        }\n';
}

function jpMessageClass(model, msg, support) {
  const name = msg.name;
  return '    public static final class ' + name + ' implements grpcdc.Marshaler, grpcdc.Unmarshaler {\n'
    + msg.fields.map((f) => '        public ' + jpType(model, f, false) + ' ' + jpFieldName(f) + ' = ' + jpDefault(model, f) + ';\n').join('')
    + '        public byte[] unknownFields = new byte[0];\n'
    + '        public ' + name + '() {}\n'
    + (msg.fields.length
      ? '        public ' + name + '(' + msg.fields.map((f) => jpType(model, f, false) + ' ' + jpFieldName(f)).join(', ') + ') {\n'
        + msg.fields.map((f) => '            this.' + jpFieldName(f) + ' = ' + jpFieldName(f) + ';\n').join('')
        + '        }\n'
      : '')
    + '\n        @Override\n        public byte[] marshalDc() {\n'
    + '            ' + support + '.Writer w = new ' + support + '.Writer();\n'
    + msg.fields.map((f) => jpEncodeGuard(model, f, jpEncodeField(model, f, support))).join('')
    + '            w.raw(unknownFields);\n'
    + '            return w.toBytes();\n        }\n\n'
    + '        @Override\n        public void unmarshalDc(byte[] data) {\n'
    + '            unknownFields = new byte[0];\n'
    + msg.fields.map((f) => '            ' + jpFieldName(f) + ' = ' + jpDefault(model, f) + ';\n').join('')
    + '            ' + support + '.Reader r = new ' + support + '.Reader(data);\n'
    + '            ' + support + '.Field field;\n'
    + '            while ((field = r.next()) != null) {\n                switch (field.number) {\n'
    + msg.fields.map((f) => jpDecodeCase(model, f, support)).join('')
    + '                    default -> { unknownFields = ' + support + '.concatBytes(unknownFields, field.rawValue); }\n                }\n            }\n        }\n'
    + msg.nested.map((n) => jpMessageClass(model, n, support)).join('')
    + msg.enums.map((e) => jpNestedEnum(model, msg, e)).join('')
    + '    }\n';
}

function jpTopEnum(model, e, pkg) {
  return '// @generated by protoc-gen-grpc-dc-java. DO NOT EDIT.\n'
    + (pkg ? 'package ' + pkg + ';\n\n' : '')
    + 'public enum ' + e.name + ' {\n'
    + jpEnumValues(e)
    + jpEnumBody(e, '    ')
    + '}\n';
}

function jpTopMessage(model, msg, pkg, support) {
  const name = msg.name;
  return '// @generated by protoc-gen-grpc-dc-java. DO NOT EDIT.\n'
    + (pkg ? 'package ' + pkg + ';\n\n' : '')
    + 'public final class ' + name + ' implements grpcdc.Marshaler, grpcdc.Unmarshaler {\n'
    + msg.fields.map((f) => '    public ' + jpType(model, f, false) + ' ' + jpFieldName(f) + ' = ' + jpDefault(model, f) + ';\n').join('')
    + '    public byte[] unknownFields = new byte[0];\n'
    + '    public ' + name + '() {}\n'
    + (msg.fields.length
      ? '    public ' + name + '(' + msg.fields.map((f) => jpType(model, f, false) + ' ' + jpFieldName(f)).join(', ') + ') {\n'
        + msg.fields.map((f) => '        this.' + jpFieldName(f) + ' = ' + jpFieldName(f) + ';\n').join('')
        + '    }\n'
      : '')
    + '\n    @Override\n    public byte[] marshalDc() {\n'
    + '        ' + support + '.Writer w = new ' + support + '.Writer();\n'
    + msg.fields.map((f) => jpEncodeGuard(model, f, jpEncodeField(model, f, support))).join('')
    + '        w.raw(unknownFields);\n'
    + '        return w.toBytes();\n    }\n\n'
    + '    @Override\n    public void unmarshalDc(byte[] data) {\n'
    + '        unknownFields = new byte[0];\n'
    + msg.fields.map((f) => '        ' + jpFieldName(f) + ' = ' + jpDefault(model, f) + ';\n').join('')
    + '        ' + support + '.Reader r = new ' + support + '.Reader(data);\n'
    + '        ' + support + '.Field field;\n'
    + '        while ((field = r.next()) != null) {\n            switch (field.number) {\n'
    + msg.fields.map((f) => jpDecodeCase(model, f, support)).join('')
    + '                default -> { unknownFields = ' + support + '.concatBytes(unknownFields, field.rawValue); }\n            }\n        }\n    }\n'
    + msg.nested.map((n) => jpMessageClass(model, n, support)).join('')
    + msg.enums.map((e) => jpNestedEnum(model, msg, e)).join('')
    + '}\n';
}

const JP_SUPPORT_HEAD = '    static final class Writer {\n'
  + '        private final java.io.ByteArrayOutputStream out = new java.io.ByteArrayOutputStream();\n'
  + '        void varint(long value) { long v = value; while ((v & ~0x7fL) != 0) { out.write(((int) (v & 0x7f)) | 0x80); v >>>= 7; } out.write((int) v); }\n'
  + '        void tag(int field, int wire) { varint((field << 3) | wire); }\n'
  + '        void bytesField(int field, byte[] payload) { tag(field, 2); varint(payload.length); out.write(payload, 0, payload.length); }\n'
  + '        void stringField(int field, String value) { if (value == null || value.isEmpty()) return; bytesField(field, value.getBytes(java.nio.charset.StandardCharsets.UTF_8)); }\n'
  + '        void fixed32(int value) { out.write(value & 0xff); out.write((value >>> 8) & 0xff); out.write((value >>> 16) & 0xff); out.write((value >>> 24) & 0xff); }\n'
  + '        void fixed64(long value) { for (int i = 0; i < 8; i++) out.write((int) ((value >>> (8 * i)) & 0xff)); }\n'
  + '        void fixedInt(int value) { fixed32(value); }\n'
  + '        void fixedLong(long value) { fixed64(value); }\n'
  + '        void fixedFloat(float value) { fixed32(Float.floatToIntBits(value)); }\n'
  + '        void fixedDouble(double value) { fixed64(Double.doubleToLongBits(value)); }\n'
  + '        void raw(byte[] payload) { out.write(payload, 0, payload.length); }\n'
  + '        byte[] toBytes() { return out.toByteArray(); }\n'
  + '    }\n\n'
  + '    static byte[] concatBytes(byte[] a, byte[] b) { byte[] out = java.util.Arrays.copyOf(a, a.length + b.length); System.arraycopy(b, 0, out, a.length, b.length); return out; }\n\n'
  + '    static final class Field {\n'
  + '        final int number; final int wire; final long varintValue; final byte[] bytesValue; final long fixedValue; final byte[] rawValue;\n'
  + '        Field(int number, int wire, long varintValue, byte[] bytesValue, long fixedValue, byte[] rawValue) { this.number = number; this.wire = wire; this.varintValue = varintValue; this.bytesValue = bytesValue; this.fixedValue = fixedValue; this.rawValue = rawValue; }\n'
  + '    }\n\n'
  + '    static final class Reader {\n'
  + '        private final byte[] buf; private int pos;\n'
  + '        Reader(byte[] buf) { this.buf = buf; }\n'
  + '        boolean done() { return pos >= buf.length; }\n'
  + '        long varint() { long result = 0; int shift = 0; while (true) { if (pos >= buf.length) throw new IllegalArgumentException("truncated varint"); int b = buf[pos++] & 0xff; result |= (long) (b & 0x7f) << shift; if ((b & 0x80) == 0) return result; shift += 7; if (shift >= 64) throw new IllegalArgumentException("varint too long"); } }\n'
  + '        byte[] take(int n) { if (pos + n > buf.length) throw new IllegalArgumentException("truncated field"); byte[] v = new byte[n]; System.arraycopy(buf, pos, v, 0, n); pos += n; return v; }\n'
  + '        int fixed32() { byte[] b = take(4); return (b[0] & 0xff) | ((b[1] & 0xff) << 8) | ((b[2] & 0xff) << 16) | ((b[3] & 0xff) << 24); }\n'
  + '        long fixed64() { byte[] b = take(8); long v = 0; for (int i = 0; i < 8; i++) v |= (long) (b[i] & 0xff) << (8 * i); return v; }\n'
  + '        Field next() {\n'
  + '            if (pos >= buf.length) return null;\n'
  + '            int start = pos;\n'
  + '            long tag = varint(); int number = (int) (tag >> 3); int wire = (int) (tag & 7);\n'
  + '            switch (wire) {\n'
  + '                case 0: { long v = varint(); return new Field(number, wire, v, null, 0, java.util.Arrays.copyOfRange(buf, start, pos)); }\n'
  + '                case 2: { int n = (int) varint(); byte[] b = take(n); return new Field(number, wire, 0, b, 0, java.util.Arrays.copyOfRange(buf, start, pos)); }\n'
  + '                case 1: { byte[] b = take(8); long v = 0; for (int i = 0; i < 8; i++) v |= (long) (b[i] & 0xff) << (8 * i); return new Field(number, wire, 0, b, v, java.util.Arrays.copyOfRange(buf, start, pos)); }\n'
  + '                case 5: { byte[] b = take(4); int v = (b[0] & 0xff) | ((b[1] & 0xff) << 8) | ((b[2] & 0xff) << 16) | ((b[3] & 0xff) << 24); return new Field(number, wire, 0, b, v, java.util.Arrays.copyOfRange(buf, start, pos)); }\n'
  + '                default: throw new IllegalArgumentException("bad wire type " + wire);\n'
  + '            }\n'
  + '        }\n'
  + '    }\n'
  + '}\n';

function jpSupportClass(base, pkg, helpersText) {
  const support = pascalName(base) + 'Pb';
  let content = '// @generated by protoc-gen-grpc-dc-java. DO NOT EDIT.\n'
    + (pkg ? 'package ' + pkg + ';\n\n' : '')
    + 'final class ' + support + ' {\n'
    + '    private ' + support + '() {}\n\n'
    + JP_SUPPORT_HEAD;
  if (helpersText) {
    content = content.replace('    static final class Writer {', helpersText + '    static final class Writer {');
  }
  return { name: support + '.java', content };
}

function emitJavaPbFiles(model) {
  if (!model.messages.length && !model.enums.length) return [];
  const base = baseName(model.name);
  const pkg = model.package;
  const support = pascalName(base) + 'Pb';
  const seenMaps = new Set();
  const helpers = [];
  const collect = (msg) => {
    for (const f of msg.fields) {
      if (f.type === FT.MESSAGE) {
        const e = jpResolve(model, f.typeName);
        if (e.kind === 'map' && !seenMaps.has(e.msg.fullName)) {
          seenMaps.add(e.msg.fullName);
          helpers.push(jpMapHelpers(model, e, support));
        }
      }
    }
    for (const n of msg.nested) collect(n);
  };
  for (const m of model.messages) collect(m);
  const files = [jpSupportClass(base, pkg, helpers.length ? helpers.join('') : '')];
  for (const m of model.messages) {
    if (!m.mapEntry) files.push({ name: m.name + '.java', content: jpTopMessage(model, m, pkg, support) });
  }
  for (const e of model.enums) {
    files.push({ name: e.name + '.java', content: jpTopEnum(model, e, pkg) });
  }
  return files;
}

function javaQualifyType(pkg, simple, full) {
  if (!full || !pkg || full.startsWith(pkg + '.')) return simple;
  return full.split('.').slice(0, -1).join('.') + '.' + simple;
}

function javaQualifyServices(pkg, services) {
  return services.map((svc) => ({
    ...svc,
    methods: svc.methods.map((m) => ({
      ...m,
      input: javaQualifyType(pkg, m.input, m.inputFull),
      output: javaQualifyType(pkg, m.output, m.outputFull),
    })),
  }));
}

function emitJavaFile(model, params) {
  const base = baseName(model.name);
  const className = pascalName(base) + 'GrpcDc';
  const pkg = model.package;
  const stub = {
    name: className + '.java',
    content: '// @generated by protoc-gen-grpc-dc-java. DO NOT EDIT.\n'
      + '// source: ' + model.name + '\n\n'
      + (pkg ? 'package ' + pkg + ';\n\n' : '')
      + 'import grpcdc.Channel;\nimport grpcdc.Endpoint;\nimport grpcdc.Server;\nimport grpcdc.StatusException;\nimport grpcdc.Wire;\n'
      + 'import java.util.ArrayList;\nimport java.util.List;\nimport java.util.Map;\n'
      + 'import java.util.concurrent.CompletableFuture;\nimport java.util.concurrent.CompletionException;\n\n'
      + '/** Generated gRPC-over-DataChannels stubs for ' + model.name + '. */\n'
      + 'public final class ' + className + ' {\n    private ' + className + '() {}\n\n'
      + javaQualifyServices(pkg, model.services).map(javaService).join('')
      + '}\n',
  };
  const pbFiles = emitJavaPbFiles(model);
  return pbFiles.length ? [stub, ...pbFiles] : stub;
}

JS
)

(define js-part-7 #<<JS
// ---------------------------------------------------------------------------
// C# emitter (mirrors the native csharp template).
// ---------------------------------------------------------------------------

function pascalCs(s) {
  // See pascalName: the template's string-split never splits.
  return s ? s[0].toUpperCase() + s.slice(1) : s;
}











const CS_KIND_CONSTS = {
  unary: 'KindUnary',
  'server-streaming': 'KindServerStreaming',
  'client-streaming': 'KindClientStreaming',
  bidi: 'KindBidi',
};











function csService(svc) {
  return runSegments(SEGMENT_PROGRAMS.csService, svc, svc.name);
}


// ---------------------------------------------------------------------------
// C# message types, mirroring the native csharp template (the
// cs-pb-* functions): one public class per top-level message and
// enum, plus an internal <Base>Pb wire-support class per proto
// file. Byte-identical to the native protoc-gen-grpc-dc-csharp
// plugin.
// ---------------------------------------------------------------------------

const CSP_VARINT = new Set(VARINT_TYPES);
const CSP_FIXED = FIXED_TABLES.csharp;

function cspPascal(s) {
  return s.split('_').map((p) => (p ? p[0].toUpperCase() + p.slice(1) : '')).join('');
}

function cspFindOwner(model, f) {
  const walk = (msg) => {
    if (msg.fields.includes(f)) return msg;
    for (const n of msg.nested) { const r = walk(n); if (r) return r; }
    return null;
  };
  for (const m of model.messages) { const r = walk(m); if (r) return r; }
  return null;
}

function cspFieldName(model, f) {
  const n = cspPascal(f.name);
  const owner = cspFindOwner(model, f);
  if (owner && (owner.name === n || owner.nested.some((m) => m.name === n) || owner.enums.some((e) => e.name === n))) return n + '_';
  return n;
}

function csQualifyType(pkg, simple, full) {
  if (!full || !pkg || full.startsWith(pkg + '.')) return simple;
  return full[0].toUpperCase() + full.slice(1);
}

function csQualifyServices(pkg, services) {
  return services.map((svc) => ({
    ...svc,
    methods: svc.methods.map((m) => ({
      ...m,
      input: csQualifyType(pkg, m.input, m.inputFull),
      output: csQualifyType(pkg, m.output, m.outputFull),
    })),
  }));
}

function cspResolve(model, typeName) {
  const entry = model.types.get(typeName);
  if (!entry) throw new Error('unresolved type ' + typeName);
  return entry;
}

function cspNs(pkg) {
  return pkg === '' ? 'Proto' : pascalName(pkg);
}

function cspRel(pkg, full) {
  const rel = pkg && full.startsWith(pkg + '.') ? full.slice(pkg.length + 1) : full;
  return rel.split('.').join('.');
}

function cspEntryRef(model, entry) {
  const rel = entry.kind === 'enum'
    ? (entry.msg
      ? cspRel(entry.pkg, entry.msg.fullName) + '.' + entry.enum.name
      : cspRel(entry.pkg, (entry.pkg ? entry.pkg + '.' : '') + entry.enum.name))
    : cspRel(entry.pkg, entry.msg.fullName);
  if (entry.file === model.name) return rel;
  return cspNs(entry.pkg) + '.' + rel;
}

































function cspMapHelperName(model, entry) {
  return cspRel(entry.pkg, entry.msg.fullName).split('.').join('');
}

function cspMapHelpers(model, entry, support) {
  return runSegments(SEGMENT_PROGRAMS.csPbMapHelpers, entry, null, model, [support]);
}

const CSP_SUPPORT_BODY = '    internal sealed class Writer {\n'
  + '        private readonly System.IO.MemoryStream _out = new();\n'
  + '        public void Varint(long value) { ulong v = unchecked((ulong) value); while ((v & ~0x7fUL) != 0) { _out.WriteByte((byte) ((v & 0x7f) | 0x80)); v >>= 7; } _out.WriteByte((byte) v); }\n'
  + '        public void Tag(int field, int wire) { Varint((field << 3) | wire); }\n'
  + '        public void BytesField(int field, byte[] payload) { Tag(field, 2); Varint(payload.Length); _out.Write(payload, 0, payload.Length); }\n'
  + '        public void StringField(int field, string value) { if (string.IsNullOrEmpty(value)) return; BytesField(field, System.Text.Encoding.UTF8.GetBytes(value)); }\n'
  + '        public void Raw(byte[] payload) { _out.Write(payload, 0, payload.Length); }\n'
  + '        public void FixedInt(int value) { _out.WriteByte((byte) value); _out.WriteByte((byte) (value >> 8)); _out.WriteByte((byte) (value >> 16)); _out.WriteByte((byte) (value >> 24)); }\n'
  + '        public void FixedLong(long value) { for (int i = 0; i < 8; i++) _out.WriteByte((byte) (value >> (8 * i))); }\n'
  + '        public void FixedFloat(float value) { FixedInt(BitConverter.SingleToInt32Bits(value)); }\n'
  + '        public void FixedDouble(double value) { FixedLong(BitConverter.DoubleToInt64Bits(value)); }\n'
  + '        public byte[] ToBytes() => _out.ToArray();\n'
  + '    }\n\n'
  + '    internal static byte[] ConcatBytes(byte[] a, byte[] b) { var o = new byte[a.Length + b.Length]; Array.Copy(a, o, a.Length); Array.Copy(b, 0, o, a.Length, b.Length); return o; }\n\n'
  + '    internal sealed class Field {\n'
  + '        public int Number { get; } public int Wire { get; } public long VarintValue { get; } public byte[] BytesValue { get; } public long FixedValue { get; } public byte[] RawValue { get; }\n'
  + '        internal Field(int number, int wire, long varintValue, byte[] bytesValue, long fixedValue, byte[] rawValue) { Number = number; Wire = wire; VarintValue = varintValue; BytesValue = bytesValue; FixedValue = fixedValue; RawValue = rawValue; }\n'
  + '    }\n\n'
  + '    internal sealed class Reader {\n'
  + '        private readonly byte[] _buf; private int _pos;\n'
  + '        internal Reader(byte[] buf) { _buf = buf; }\n'
  + '        public bool Done => _pos >= _buf.Length;\n'
  + '        public long Varint() { long result = 0; int shift = 0; while (true) { if (_pos >= _buf.Length) throw new ArgumentException("truncated varint"); int b = _buf[_pos++]; result |= (long) (b & 0x7f) << shift; if ((b & 0x80) == 0) return result; shift += 7; if (shift >= 64) throw new ArgumentException("varint too long"); } }\n'
  + '        public byte[] Take(int n) { if (_pos + n > _buf.Length) throw new ArgumentException("truncated field"); var v = new byte[n]; Array.Copy(_buf, _pos, v, 0, n); _pos += n; return v; }\n'
  + '        public byte[] TakeFrom(int start) { var v = new byte[_pos - start]; Array.Copy(_buf, start, v, 0, v.Length); return v; }\n'
  + '        public int Fixed32() { var b = Take(4); return b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24); }\n'
  + '        public long Fixed64() { var b = Take(8); long v = 0; for (int i = 0; i < 8; i++) v |= (long) b[i] << (8 * i); return v; }\n'
  + '        public Field Next() {\n'
  + '            if (_pos >= _buf.Length) return null;\n'
  + '            int start = _pos;\n'
  + '            long tag = Varint(); int number = (int) (tag >> 3); int wire = (int) (tag & 7);\n'
  + '            switch (wire) {\n'
  + '                case 0: { long v = Varint(); return new Field(number, wire, v, null, 0, TakeFrom(start)); }\n'
  + '                case 2: { int n = (int) Varint(); var b = Take(n); return new Field(number, wire, 0, b, 0, TakeFrom(start)); }\n'
  + '                case 1: { var b = Take(8); long v = 0; for (int i = 0; i < 8; i++) v |= (long) b[i] << (8 * i); return new Field(number, wire, 0, b, v, TakeFrom(start)); }\n'
  + '                case 5: { var b = Take(4); int v = b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24); return new Field(number, wire, 0, b, v, TakeFrom(start)); }\n'
  + '                default: throw new ArgumentException("bad wire type " + wire);\n'
  + '            }\n'
  + '        }\n'
  + '    }\n'
  + '}\n';

function cspSupportClass(base, pkg, helpersText) {
  const support = pascalName(base) + 'Pb';
  let content = '// @generated by protoc-gen-grpc-dc-csharp. DO NOT EDIT.\n'
    + 'using System;\n\n'
    + 'namespace ' + cspNs(pkg) + ';\n\n'
    + 'internal static class ' + support + ' {\n'
    + CSP_SUPPORT_BODY;
  if (helpersText) {
    content = content.replace('    internal sealed class Writer {', helpersText + '    internal sealed class Writer {');
  }
  return { name: support + '.cs', content };
}

function cspParamName(model, f) {
  const n = cspFieldName(model, f);
  return n[0].toLowerCase() + n.slice(1);
}

function cspMessageClass(model, msg, support, indent, decl) {
  return runSegments(SEGMENT_PROGRAMS.csPbMessage, msg, null, model, [support, indent, decl]);
}



function cspTopEnum(model, e, pkg) {
  return '// @generated by protoc-gen-grpc-dc-csharp. DO NOT EDIT.\n'
    + 'namespace ' + cspNs(pkg) + ';\n\n'
    + 'public enum ' + e.name + ' {\n'
    + e.values.map((v) => '    ' + v.name + ' = ' + v.number).join(',\n')
    + '\n}\n';
}

function emitCsharpPbFiles(model) {
  if (!model.messages.length && !model.enums.length) return [];
  const base = baseName(model.name);
  const pkg = model.package;
  const support = pascalName(base) + 'Pb';
  const seenMaps = new Set();
  const helpers = [];
  const collect = (msg) => {
    for (const f of msg.fields) {
      if (f.type === FT.MESSAGE) {
        const e = cspResolve(model, f.typeName);
        if (e.kind === 'map' && !seenMaps.has(e.msg.fullName)) {
          seenMaps.add(e.msg.fullName);
          helpers.push(cspMapHelpers(model, e, support));
        }
      }
    }
    for (const n of msg.nested) collect(n);
  };
  for (const m of model.messages) collect(m);
  const files = [cspSupportClass(base, pkg, helpers.length ? helpers.join('') : '')];
  for (const m of model.messages) {
    if (!m.mapEntry) {
      files.push({
        name: m.name + '.cs',
        content: '// @generated by protoc-gen-grpc-dc-csharp. DO NOT EDIT.\n'
          + 'using System;\nusing Grpcdc;\n\n'
          + 'namespace ' + cspNs(pkg) + ';\n\n'
          + cspMessageClass(model, m, support, '', 'public sealed'),
      });
    }
  }
  for (const e of model.enums) {
    files.push({ name: e.name + '.cs', content: cspTopEnum(model, e, pkg) });
  }
  return files;
}

function emitCsharpFile(model, params) {
  const base = baseName(model.name);
  const className = pascalCs(base) + 'GrpcDc';
  const ns = model.package ? pascalCs(model.package) : 'Proto';
  const stub = {
    name: className + '.cs',
    content: '// @generated by protoc-gen-grpc-dc-csharp. DO NOT EDIT.\n'
      + '// source: ' + model.name + '\n\n'
      + 'using System;\nusing System.Collections.Generic;\nusing System.Runtime.CompilerServices;\nusing System.Threading;\nusing System.Threading.Tasks;\nusing Grpcdc;\n\n'
      + 'namespace ' + ns + ';\n\n'
      + '/// <summary>Generated gRPC-over-DataChannels stubs for ' + model.name + '.</summary>\n'
      + 'public static class ' + className + '\n{\n'
      + csQualifyServices(model.package, model.services).map(csService).join('')
      + '}\n',
  };
  const pbFiles = emitCsharpPbFiles(model);
  return pbFiles.length ? [stub, ...pbFiles] : stub;
}

JS
)

(define js-part-8 #<<JS
// ---------------------------------------------------------------------------
// C++ emitter (mirrors the native cpp template).
// ---------------------------------------------------------------------------

function cppDeprecated(m, indent) {
  return m.deprecated ? indent + '[[deprecated("deprecated in the proto schema")]]\n' : '';
}

function cppClientMethodRaw(m, svc) {
  const path = q(m.path);
  switch (m.kind) {
    case 'unary':
      return '    ' + m.output + ' ' + m.name + '(' + m.input + ' req,\n'
        + '                       const grpcdc::Metadata* metadata = nullptr, std::optional<std::chrono::milliseconds> timeout = std::nullopt) {\n'
        + '      ' + m.output + ' resp;\n'
        + '      channel_->Unary(' + path + ', req, resp, metadata, timeout);\n'
        + '      return resp;\n    }\n\n';
    case 'server-streaming':
      return '    ' + svc + m.name + 'Stream ' + m.name + '(\n'
        + '        ' + m.input + ' req, const grpcdc::Metadata* metadata = nullptr, std::optional<std::chrono::milliseconds> timeout = std::nullopt) {\n'
        + '      return ' + svc + m.name + 'Stream(\n'
        + '          channel_->ServerStream(' + path + ', req, metadata, timeout));\n    }\n\n';
    case 'client-streaming':
      return '    ' + m.output + ' ' + m.name + '(std::vector<' + m.input + '> reqs,\n'
        + '                              const grpcdc::Metadata* metadata = nullptr, std::optional<std::chrono::milliseconds> timeout = std::nullopt) {\n'
        + '      std::vector<const grpcdc::Marshaler*> ptrs;\n'
        + '      for (auto& r : reqs) ptrs.push_back(&r);\n'
        + '      ' + m.output + ' resp;\n'
        + '      channel_->ClientStreamCall(' + path + ', ptrs, resp, metadata, timeout);\n'
        + '      return resp;\n    }\n\n';
    default:
      return '    ' + svc + m.name + 'Stream ' + m.name + '(std::vector<' + m.input + '> reqs,\n'
        + '                        const grpcdc::Metadata* metadata = nullptr, std::optional<std::chrono::milliseconds> timeout = std::nullopt) {\n'
        + '      std::vector<const grpcdc::Marshaler*> ptrs;\n'
        + '      for (auto& r : reqs) ptrs.push_back(&r);\n'
        + '      return ' + svc + m.name + 'Stream(channel_->Bidi(' + path + ', ptrs, metadata, timeout));\n    }\n\n';
  }
}

function cppClientStreamClass(m, svc) {
  if (m.kind !== 'server-streaming' && m.kind !== 'bidi') return '';
  return '    class ' + svc + m.name + 'Stream {\n'
    + '     public:\n'
    + '      explicit ' + svc + m.name + 'Stream(grpcdc::Channel::ClientStream stream)\n'
    + '          : stream_(std::move(stream)) {}\n'
    + '      ' + m.output + ' Recv() {\n'
    + '        ' + m.output + ' resp;\n'
    + '        stream_.Recv(resp);\n        return resp;\n      }\n\n'
    + '      /// Initial metadata (response headers).\n'
    + '      const grpcdc::Metadata& Headers() const { return stream_.headers().metadata; }\n\n'
    + '      /// Trailing metadata of the terminal status.\n'
    + '      const grpcdc::Metadata& Trailers() const { return stream_.trailers(); }\n\n'
    + '      /// Abort this stream (sends RST, wakes a pending Recv).\n'
    + '      void Cancel() { stream_.Cancel(); }\n\n'
    + '     private:\n'
    + '      grpcdc::Channel::ClientStream stream_;\n    };\n\n';
}

const CPP_ASYNC_COLLECT = (capture) =>
  '      return std::async(std::launch::async, [this, ' + capture + ', metadata, timeout] {\n';

function cppClientAsyncMethod(m, svc) {
  switch (m.kind) {
    case 'unary':
      return '    std::future<' + m.output + '> ' + m.name + 'Async(\n'
        + '        ' + m.input + ' req, const grpcdc::Metadata* metadata = nullptr, std::optional<std::chrono::milliseconds> timeout = std::nullopt) {\n'
        + '      return std::async(std::launch::async,\n'
        + '                        [this, req, metadata, timeout] { return ' + m.name + '(req, metadata, timeout); });\n    }\n\n';
    case 'server-streaming':
      return '    std::future<std::vector<' + m.output + '>> ' + m.name + 'Async(\n'
        + '        ' + m.input + ' req, const grpcdc::Metadata* metadata = nullptr, std::optional<std::chrono::milliseconds> timeout = std::nullopt) {\n'
        + CPP_ASYNC_COLLECT('req')
        + '        auto stream = ' + m.name + '(req, metadata, timeout);\n'
        + '        std::vector<' + m.output + '> out;\n'
        + '        while (true) {\n          try {\n            out.push_back(stream.Recv());\n'
        + '          } catch (const grpcdc::EndOfStream&) {\n            break;\n          }\n        }\n'
        + '        return out;\n      });\n    }\n\n';
    case 'client-streaming':
      return '    std::future<' + m.output + '> ' + m.name + 'Async(\n'
        + '        std::vector<' + m.input + '> reqs,\n'
        + '        const grpcdc::Metadata* metadata = nullptr, std::optional<std::chrono::milliseconds> timeout = std::nullopt) {\n'
        + '      return std::async(\n'
        + '          std::launch::async,\n'
        + '          [this, reqs, metadata, timeout] { return ' + m.name + '(reqs, metadata, timeout); });\n    }\n\n';
    default:
      return '    std::future<std::vector<' + m.output + '>> ' + m.name + 'Async(\n'
        + '        std::vector<' + m.input + '> reqs,\n'
        + '        const grpcdc::Metadata* metadata = nullptr, std::optional<std::chrono::milliseconds> timeout = std::nullopt) {\n'
        + CPP_ASYNC_COLLECT('reqs')
        + '        auto stream = ' + m.name + '(reqs, metadata, timeout);\n'
        + '        std::vector<' + m.output + '> out;\n'
        + '        while (true) {\n          try {\n            out.push_back(stream.Recv());\n'
        + '          } catch (const grpcdc::EndOfStream&) {\n            break;\n          }\n        }\n'
        + '        return out;\n      });\n    }\n\n';
  }
}

function cppClientCoroStreamClass(m, svc) {
  if (m.kind !== 'server-streaming' && m.kind !== 'bidi') return '';
  return '    class ' + svc + m.name + 'Stream {\n'
    + '     public:\n'
    + '      explicit ' + svc + m.name + 'Stream(grpcdc::AsyncClientStream stream)\n'
    + '          : stream_(std::move(stream)) {}\n'
    + '      /// Next response, or std::nullopt when the call completed OK.\n'
    + '      grpcdc::Task<std::optional<' + m.output + '>> Recv() {\n'
    + '        ' + m.output + ' resp;\n'
    + '        try {\n          co_await stream_.Recv(resp);\n'
    + '        } catch (const grpcdc::EndOfStream&) {\n          co_return std::nullopt;\n        }\n'
    + '        co_return resp;\n      }\n'
    + '      void Cancel() { stream_.Cancel(); }\n\n'
    + '     private:\n'
    + '      grpcdc::AsyncClientStream stream_;\n    };\n\n';
}

function cppClientCoroMethod(m, svc) {
  const path = q(m.path);
  switch (m.kind) {
    case 'unary':
      return '    grpcdc::Task<' + m.output + '> ' + m.name + '(' + m.input + ' req,\n'
        + '                       const grpcdc::Metadata* metadata = nullptr, std::optional<std::chrono::milliseconds> timeout = std::nullopt) {\n'
        + '      ' + m.output + ' resp;\n'
        + '      co_await channel_->Unary(' + path + ', req, resp, metadata, timeout);\n'
        + '      co_return resp;\n    }\n\n';
    case 'server-streaming':
      return '    grpcdc::Task<' + svc + m.name + 'Stream> ' + m.name + '(\n'
        + '        ' + m.input + ' req, const grpcdc::Metadata* metadata = nullptr, std::optional<std::chrono::milliseconds> timeout = std::nullopt) {\n'
        + '      co_return ' + svc + m.name + 'Stream(\n'
        + '          co_await channel_->ServerStream(' + path + ', req, metadata, timeout));\n    }\n\n';
    case 'client-streaming':
      return '    grpcdc::Task<' + m.output + '> ' + m.name + '(std::vector<' + m.input + '> reqs,\n'
        + '                              const grpcdc::Metadata* metadata = nullptr, std::optional<std::chrono::milliseconds> timeout = std::nullopt) {\n'
        + '      std::vector<const grpcdc::Marshaler*> ptrs;\n'
        + '      for (auto& r : reqs) ptrs.push_back(&r);\n'
        + '      ' + m.output + ' resp;\n'
        + '      co_await channel_->ClientStreamCall(' + path + ', ptrs, resp, metadata, timeout);\n'
        + '      co_return resp;\n    }\n\n';
    default:
      return '    grpcdc::Task<' + svc + m.name + 'Stream> ' + m.name + '(std::vector<' + m.input + '> reqs,\n'
        + '                        const grpcdc::Metadata* metadata = nullptr, std::optional<std::chrono::milliseconds> timeout = std::nullopt) {\n'
        + '      std::vector<const grpcdc::Marshaler*> ptrs;\n'
        + '      for (auto& r : reqs) ptrs.push_back(&r);\n'
        + '      co_return ' + svc + m.name + 'Stream(\n'
        + '          co_await channel_->Bidi(' + path + ', ptrs, metadata, timeout));\n    }\n\n';
  }
}

function cppServerStreamIface(m, svc) {
  switch (m.kind) {
    case 'unary':
      return '';
    case 'server-streaming':
      return '  /// Server-streaming sink passed to service implementations.\n'
        + '  struct ' + svc + m.name + 'Server {\n'
        + '    virtual ~' + svc + m.name + 'Server() = default;\n'
        + '    virtual void Send(' + m.output + '& resp) = 0;\n'
        + '    virtual grpcdc::Endpoint::CallContext& Context() = 0;\n  };\n\n';
    case 'client-streaming':
      return '  /// Client-streaming stream passed to service implementations.\n'
        + '  struct ' + svc + m.name + 'Server {\n'
        + '    virtual ~' + svc + m.name + 'Server() = default;\n'
        + '    virtual ' + m.input + ' Recv() = 0;\n'
        + '    virtual void SendAndClose(' + m.output + '& resp) = 0;\n'
        + '    virtual grpcdc::Endpoint::CallContext& Context() = 0;\n  };\n\n';
    default:
      return '  /// Bidi stream passed to service implementations.\n'
        + '  struct ' + svc + m.name + 'Server {\n'
        + '    virtual ~' + svc + m.name + 'Server() = default;\n'
        + '    virtual void Send(' + m.output + '& resp) = 0;\n'
        + '    virtual ' + m.input + ' Recv() = 0;\n'
        + '    virtual grpcdc::Endpoint::CallContext& Context() = 0;\n  };\n\n';
  }
}

function cppServerIfaceMethodRaw(m, svc) {
  switch (m.kind) {
    case 'unary':
      return '    virtual ' + m.output + ' ' + m.name + '(grpcdc::Endpoint::CallContext& ctx,\n                               ' + m.input + '& req) = 0;\n';
    case 'server-streaming':
      return '    virtual void ' + m.name + '(' + m.input + '& req,\n                              ' + svc + m.name + 'Server& stream) = 0;\n';
    default:
      return '    virtual void ' + m.name + '(' + svc + m.name + 'Server& stream) = 0;\n';
  }
}

function cppServerAsyncIfaceMethod(m, svc) {
  switch (m.kind) {
    case 'unary':
      return '    virtual std::future<' + m.output + '> ' + m.name + 'Async(\n        grpcdc::Endpoint::CallContext& ctx, ' + m.input + '& req) = 0;\n';
    case 'server-streaming':
      return '    virtual std::future<void> ' + m.name + 'Async(\n        ' + m.input + '& req, ' + svc + m.name + 'Server& stream) = 0;\n';
    case 'client-streaming':
      return '    virtual std::future<void> ' + m.name + 'Async(\n        ' + svc + m.name + 'Server& stream) = 0;\n';
    default:
      return '    virtual std::future<void> ' + m.name + 'Async(' + svc + m.name + 'Server& stream) = 0;\n';
  }
}

function cppServerAsyncAdapterMethod(m, svc) {
  switch (m.kind) {
    case 'unary':
      return '    ' + m.output + ' ' + m.name + '(grpcdc::Endpoint::CallContext& ctx,\n'
        + '                       ' + m.input + '& req) override {\n'
        + '      return impl_->' + m.name + 'Async(ctx, req).get();\n    }\n';
    case 'server-streaming':
      return '    void ' + m.name + '(' + m.input + '& req,\n'
        + '                      ' + svc + m.name + 'Server& stream) override {\n'
        + '      impl_->' + m.name + 'Async(req, stream).get();\n    }\n';
    case 'client-streaming':
      return '    void ' + m.name + '(' + svc + m.name + 'Server& stream) override {\n'
        + '      impl_->' + m.name + 'Async(stream).get();\n    }\n';
    default:
      return '    void ' + m.name + '(' + svc + m.name + 'Server& stream) override { impl_->' + m.name + 'Async(stream).get(); }\n';
  }
}

function cppStreamImpl(m, svc) {
  switch (m.kind) {
    case 'unary':
      return '';
    case 'server-streaming':
      return '  class ' + svc + m.name + 'ServerImpl : public ' + svc + m.name + 'Server {\n'
        + '   public:\n'
        + '    ' + svc + m.name + 'ServerImpl(grpcdc::Endpoint::CallContext& ctx,\n'
        + '                               grpcdc::Server::ServerSink& sink)\n'
        + '        : ctx_(ctx), sink_(sink) {}\n'
        + '    void Send(' + m.output + '& resp) override { sink_(resp.MarshalDc()); }\n'
        + '    grpcdc::Endpoint::CallContext& Context() override { return ctx_; }\n\n'
        + '   private:\n'
        + '    grpcdc::Endpoint::CallContext& ctx_;\n'
        + '    grpcdc::Server::ServerSink& sink_;\n  };\n\n';
    case 'client-streaming':
      return '  class ' + svc + m.name + 'ServerImpl : public ' + svc + m.name + 'Server {\n'
        + '   public:\n'
        + '    ' + svc + m.name + 'ServerImpl(grpcdc::Endpoint::CallContext& ctx,\n'
        + '                               grpcdc::Server::RequestStream& reqs)\n'
        + '        : ctx_(ctx), reqs_(reqs) {}\n'
        + '    ' + m.input + ' Recv() override {\n'
        + '      ' + m.input + ' req;\n      reqs_.RecvInto(req);\n      return req;\n    }\n'
        + '    void SendAndClose(' + m.output + '& resp) override {\n'
        + '      resp_ = resp;\n      has_resp_ = true;\n    }\n'
        + '    grpcdc::Endpoint::CallContext& Context() override { return ctx_; }\n'
        + '    ' + m.output + ' Resp() const { return resp_; }\n'
        + '    bool HasResp() const { return has_resp_; }\n\n'
        + '   private:\n'
        + '    grpcdc::Endpoint::CallContext& ctx_;\n'
        + '    grpcdc::Server::RequestStream& reqs_;\n'
        + '    ' + m.output + ' resp_;\n'
        + '    bool has_resp_ = false;\n  };\n\n';
    default:
      return '  class ' + svc + m.name + 'ServerImpl : public ' + svc + m.name + 'Server {\n'
        + '   public:\n'
        + '    ' + svc + m.name + 'ServerImpl(grpcdc::Endpoint::CallContext& ctx,\n'
        + '                       grpcdc::Server::RequestStream& reqs,\n'
        + '                       grpcdc::Server::ServerSink& sink)\n'
        + '        : ctx_(ctx), reqs_(reqs), sink_(sink) {}\n'
        + '    void Send(' + m.output + '& resp) override { sink_(resp.MarshalDc()); }\n'
        + '    ' + m.input + ' Recv() override {\n'
        + '      ' + m.input + ' req;\n      reqs_.RecvInto(req);\n      return req;\n    }\n'
        + '    grpcdc::Endpoint::CallContext& Context() override { return ctx_; }\n\n'
        + '   private:\n'
        + '    grpcdc::Endpoint::CallContext& ctx_;\n'
        + '    grpcdc::Server::RequestStream& reqs_;\n'
        + '    grpcdc::Server::ServerSink& sink_;\n  };\n\n';
  }
}

const CPP_KIND_CONSTS = {
  unary: 'kKindUnary',
  'server-streaming': 'kKindServerStreaming',
  'client-streaming': 'kKindClientStreaming',
  bidi: 'kKindBidi',
};

function cppRegisterMethod(m, svc) {
  const impl = m.implName;
  const kind = CPP_KIND_CONSTS[m.kind];
  switch (m.kind) {
    case 'unary':
      return '            {' + q(m.name) + ', ' + q(m.path) + ', grpcdc::Server::' + kind + ',\n'
        + '             [&impl](const grpcdc::Endpoint::CallContext& ctx,\n'
        + '                     grpcdc::Server::RequestStream& reqs,\n'
        + '                     grpcdc::Server::ServerSink& sink) {\n'
        + '               ' + m.input + ' req;\n               reqs.RecvInto(req);\n'
        + '               auto mutable_ctx = const_cast<grpcdc::Endpoint::CallContext&>(ctx);\n'
        + '               ' + m.output + ' resp = impl.' + impl + '(mutable_ctx, req);\n'
        + '               sink(resp.MarshalDc());\n             }},\n';
    case 'server-streaming':
      return '            {' + q(m.name) + ', ' + q(m.path) + ',\n'
        + '             grpcdc::Server::' + kind + ',\n'
        + '             [&impl](const grpcdc::Endpoint::CallContext& ctx,\n'
        + '                     grpcdc::Server::RequestStream& reqs,\n'
        + '                     grpcdc::Server::ServerSink& sink) {\n'
        + '               ' + m.input + ' req;\n               reqs.RecvInto(req);\n'
        + '               ' + svc + m.name + 'ServerImpl stream(\n'
        + '                   const_cast<grpcdc::Endpoint::CallContext&>(ctx), sink);\n'
        + '               impl.' + impl + '(req, stream);\n             }},\n';
    case 'client-streaming':
      return '            {' + q(m.name) + ', ' + q(m.path) + ',\n'
        + '             grpcdc::Server::' + kind + ',\n'
        + '             [&impl](const grpcdc::Endpoint::CallContext& ctx,\n'
        + '                     grpcdc::Server::RequestStream& reqs,\n'
        + '                     grpcdc::Server::ServerSink& sink) {\n'
        + '               ' + svc + m.name + 'ServerImpl stream(\n'
        + '                   const_cast<grpcdc::Endpoint::CallContext&>(ctx), reqs);\n'
        + '               impl.' + impl + '(stream);\n'
        + '               if (!stream.HasResp()) {\n'
        + '                 throw grpcdc::StatusException(\n'
        + '                     grpcdc::wire::kCodeInternal,\n'
        + '                     "client-streaming handler never called SendAndClose");\n'
        + '               }\n'
        + '               ' + m.output + ' resp = stream.Resp();\n'
        + '               sink(resp.MarshalDc());\n             }},\n';
    default:
      return '            {' + q(m.name) + ', ' + q(m.path) + ', grpcdc::Server::' + kind + ',\n'
        + '             [&impl](const grpcdc::Endpoint::CallContext& ctx,\n'
        + '                     grpcdc::Server::RequestStream& reqs,\n'
        + '                     grpcdc::Server::ServerSink& sink) {\n'
        + '               ' + svc + m.name + 'ServerImpl stream(\n'
        + '                   const_cast<grpcdc::Endpoint::CallContext&>(ctx), reqs, sink);\n'
        + '               impl.' + impl + '(stream);\n             }},\n';
  }
}

function cppService(svc) {
  const sname = svc.name;
  const all = svc.methods.concat(aliasClientMethods(svc));
  return '  /// Client for ' + svc.fullName + '.\n'
    + '  class ' + sname + 'Client {\n'
    + '   public:\n'
    + '    explicit ' + sname + 'Client(std::shared_ptr<grpcdc::Channel> channel)\n        : channel_(std::move(channel)) {}\n\n'
    + svc.methods.map((m) => cppClientStreamClass(m, sname)).join('')
    + all.map((m) => cppDeprecated(m, '    ') + cppClientMethodRaw(m, sname)).join('')
    + '    // -- async (std::future) surface -------------------------------------\n\n'
    + all.map((m) => cppClientAsyncMethod(m, sname)).join('')
    + '   private:\n    std::shared_ptr<grpcdc::Channel> channel_;\n  };\n\n'
    + '#if __cplusplus >= 202002L\n'
    + '  /// C++20 coroutine client for ' + svc.fullName + ' (co_await / grpcdc::Task).\n'
    + '  class ' + sname + 'ClientCoro {\n'
    + '   public:\n'
    + '    explicit ' + sname + 'ClientCoro(std::shared_ptr<grpcdc::AsyncChannel> channel)\n        : channel_(std::move(channel)) {}\n'
    + '    explicit ' + sname + 'ClientCoro(std::shared_ptr<grpcdc::Channel> channel)\n        : channel_(std::make_shared<grpcdc::AsyncChannel>(std::move(channel))) {}\n\n'
    + all.map((m) => cppClientCoroStreamClass(m, sname)).join('')
    + all.map((m) => cppClientCoroMethod(m, sname)).join('')
    + '   private:\n    std::shared_ptr<grpcdc::AsyncChannel> channel_;\n  };\n'
    + '#endif  // __cplusplus >= 202002L\n\n'
    + svc.methods.map((m) => cppServerStreamIface(m, sname)).join('')
    + '  /// Service implementation interface for ' + svc.fullName + '.\n'
    + '  struct ' + sname + 'Server {\n    virtual ~' + sname + 'Server() = default;\n'
    + svc.methods.map((m) => cppDeprecated(m, '    ') + cppServerIfaceMethodRaw(m, sname)).join('')
    + '  };\n\n'
    + '  /// Async service implementation interface for ' + svc.fullName + '.\n'
    + '  struct ' + sname + 'ServerAsync {\n    virtual ~' + sname + 'ServerAsync() = default;\n'
    + svc.methods.map((m) => cppServerAsyncIfaceMethod(m, sname)).join('')
    + '  };\n\n'
    + ' private:\n'
    + svc.methods.map((m) => cppStreamImpl(m, sname)).join('')
    + '  class ' + sname + 'ServerAsyncAdapter : public ' + sname + 'Server {\n'
    + '   public:\n    explicit ' + sname + 'ServerAsyncAdapter(' + sname + 'ServerAsync* impl) : impl_(impl) {}\n'
    + svc.methods.map((m) => cppServerAsyncAdapterMethod(m, sname)).join('')
    + '\n   private:\n    ' + sname + 'ServerAsync* impl_;\n  };\n\n'
    + ' public:\n'
    + '  /// Register an implementation of ' + svc.fullName + ' on a Server.\n'
    + '  static void Register' + sname + 'Server(grpcdc::Server& server, ' + sname + 'Server& impl) {\n'
    + '    server.RegisterService(grpcdc::Server::ServiceDesc{\n        ' + q(svc.fullName) + ',\n        {\n'
    + svc.methods.concat(aliasServerMethods(svc)).map((m) => cppRegisterMethod(m, sname)).join('')
    + '        }});\n  }\n\n'
    + '  /// Register an async implementation of ' + svc.fullName + ' on a Server.\n'
    + '  static void Register' + sname + 'ServerAsync(grpcdc::Server& server,\n                                      ' + sname + 'ServerAsync& impl) {\n'
    + '    // Adapters are retained for the process lifetime: registration is\n'
    + '    // once-per-process and bounded by service count.\n'
    + '    static std::vector<std::shared_ptr<' + sname + 'ServerAsyncAdapter>> adapters;\n'
    + '    auto adapter = std::make_shared<' + sname + 'ServerAsyncAdapter>(&impl);\n'
    + '    adapters.push_back(adapter);\n'
    + '    Register' + sname + 'Server(server, *adapter);\n  }\n';
}


// ---------------------------------------------------------------------------
// C++ message types, mirroring the native cpp template (the
// cpp-pb-* functions): a single <base>_messages.hpp per proto file
// with the pb_<base> wire-support namespace, enums and message
// classes. Byte-identical to the native protoc-gen-grpc-dc-cpp
// plugin.
// ---------------------------------------------------------------------------

const XPP_VARINT = new Set(VARINT_TYPES);
const XPP_FIXED = FIXED_TABLES.cpp;

function xppResolve(model, typeName) {
  const entry = model.types.get(typeName);
  if (!entry) throw new Error('unresolved type ' + typeName);
  return entry;
}

function xppNs(pkg) {
  return pkg === '' ? 'proto' : pkg.split('.').join('::');
}

function xppRel(pkg, full) {
  const rel = pkg && full.startsWith(pkg + '.') ? full.slice(pkg.length + 1) : full;
  return rel.split('.').join('::');
}

function xppEntryRef(model, entry) {
  const rel = entry.kind === 'enum'
    ? (entry.msg
      ? xppRel(entry.pkg, entry.msg.fullName) + '::' + entry.enum.name
      : xppRel(entry.pkg, (entry.pkg ? entry.pkg + '.' : '') + entry.enum.name))
    : xppRel(entry.pkg, entry.msg.fullName);
  if (entry.file === model.name) return rel;
  return '::' + xppNs(entry.pkg) + '::' + rel;
}

function xppScalar(f) {
  // Leaf payloads single-sourced from scalar-type-tables
  // in spec.rkt (SCALAR_TABLES), same table the native
  // template derives from.
  return SCALAR_TABLES.cpp.types[f.type] ?? SCALAR_TABLES.cpp.default;
}

function xppType(model, f) {
  let singular;
  if (f.type === FT.MESSAGE) {
    const entry = xppResolve(model, f.typeName);
    if (entry.kind === 'map') {
      const kf = entry.msg.fields.find((x) => x.number === 1);
      const vf = entry.msg.fields.find((x) => x.number === 2);
      singular = 'std::map<' + xppType(model, { ...kf, label: 1 }) + ', '
        + (vf.type === FT.MESSAGE
          ? xppEntryRef(model, xppResolve(model, vf.typeName))
          : xppType(model, { ...vf, label: 1 })) + '>';
    } else {
      singular = 'std::optional<' + xppEntryRef(model, entry) + '>';
    }
  } else if (f.type === FT.ENUM) {
    singular = xppEntryRef(model, xppResolve(model, f.typeName));
  } else {
    singular = xppScalar(f)[0];
  }
  if (f.type === FT.MESSAGE && xppResolve(model, f.typeName).kind === 'map') return singular;
  if (f.label === 3) {
    return 'std::vector<' + (f.type === FT.MESSAGE
      ? xppEntryRef(model, xppResolve(model, f.typeName))
      : xppType(model, { ...f, label: 1 })) + '>';
  }
  return singular;
}

function xppExplicitLiteral(model, f) {
  const d = fieldExplicitDefault(f);
  if (d === null) return null;
  switch (f.type) {
    case 9: return JSON.stringify(d);
    case 8: return d;
    case 14: return xppEntryRef(model, xppResolve(model, f.typeName)) + '::' + d;
    default: return d;
  }
}

function xppDefault(model, f) {
  const lit = xppExplicitLiteral(model, f);
  if (lit !== null) return lit;
  if (f.type === FT.MESSAGE && xppResolve(model, f.typeName).kind === 'map') return '{}';
  if (f.label === 3) return '{}';
  if (f.type === FT.MESSAGE) return 'std::nullopt';
  if (f.type === FT.ENUM) {
    const entry = xppResolve(model, f.typeName);
    return xppEntryRef(model, entry) + '::' + entry.enum.values[0].name;
  }
  return xppScalar(f)[1];
}

function xppVarintExpr(f, v) {
  switch (f.type) {
    case 8: return '(' + v + ' ? 1 : 0)';
    case 17: return 'static_cast<std::uint64_t>((' + v + ' << 1) ^ (' + v + ' >> 31))';
    case 18: return 'static_cast<std::uint64_t>((' + v + ' << 1) ^ (' + v + ' >> 63))';
    case 14: return 'static_cast<std::int32_t>(' + v + ')';
    case 5: return 'static_cast<std::int64_t>(' + v + ')';
    default: return 'static_cast<std::uint64_t>(' + v + ')';
  }
}

function xppVarintDecode(f, v) {
  switch (f.type) {
    case 5: return 'static_cast<std::int32_t>(' + v + ')';
    case 13: case 7: return 'static_cast<std::uint32_t>(' + v + ')';
    case 3: return 'static_cast<std::int64_t>(' + v + ')';
    case 4: case 6: return v;
    case 8: return v + ' != 0';
    case 17: return 'static_cast<std::int32_t>((' + v + ' >> 1) ^ -static_cast<std::int64_t>(' + v + ' & 1))';
    case 18: return 'static_cast<std::int64_t>((' + v + ' >> 1) ^ -static_cast<std::int64_t>(' + v + ' & 1))';
    default: throw new Error('not a varint type');
  }
}

function xppNonzero(f, v) {
  switch (f.type) {
    case 8: return v;
    case 14: return 'static_cast<std::int32_t>(' + v + ') != 0';
    default: return v + ' != 0';
  }
}

function xppEncodeSingular(model, f, v, indent, support) {
  const n = f.number;
  const proto2 = model.syntax === 'proto2';
  if (XPP_VARINT.has(f.type)) {
    return proto2
      ? indent + '{ w.Tag(' + n + ', 0); w.Varint(' + xppVarintExpr(f, v) + '); }\n'
      : indent + 'if (' + xppNonzero(f, v) + ') { w.Tag(' + n + ', 0); w.Varint(' + xppVarintExpr(f, v) + '); }\n';
  }
  const fixed = XPP_FIXED[f.type];
  if (fixed) {
    const wire = fixed[0] === 8 ? 1 : 5;
    return proto2
      ? indent + '{ w.Tag(' + n + ', ' + wire + '); w.Fixed' + fixed[1] + '(' + v + '); }\n'
      : indent + 'if (' + xppNonzero(f, v) + ') { w.Tag(' + n + ', ' + wire + '); w.Fixed' + fixed[1] + '(' + v + '); }\n';
  }
  switch (f.type) {
    case 9: return proto2
      ? indent + 'w.BytesField(' + n + ', grpcdc::Bytes(' + v + '.begin(), ' + v + '.end()));\n'
      : indent + 'w.StringField(' + n + ', ' + v + ');\n';
    case 12: return proto2
      ? indent + 'w.BytesField(' + n + ', ' + v + ');\n'
      : indent + 'if (!' + v + '.empty()) w.BytesField(' + n + ', ' + v + ');\n';
    case 11: return indent + 'if (' + v + ') w.BytesField(' + n + ', ' + v + '->MarshalDc());\n';
    default: throw new Error('unsupported field type ' + f.type + ' (groups)');
  }
}

function xppSetExpr(sib) {
  const v = sib.name;
  switch (sib.type) {
    case 11: case 10: return v + '.has_value()';
    case 9: case 12: return '!' + v + '.empty()';
    default: return xppNonzero(sib, v);
  }
}

function xppEncodeGuard(model, f, code) {
  const later = oneofLaterSiblings(model, f);
  if (!later.length) return code;
  return '    if (!(' + later.map(xppSetExpr).join(' || ') + ')) {\n' + (code.endsWith('\n') ? code : code + '\n') + '    }\n';
}

function xppEncodeField(model, f, support) {
  const v = f.name;
  const n = f.number;
  if (f.type === FT.MESSAGE && xppResolve(model, f.typeName).kind === 'map') {
    const entry = xppResolve(model, f.typeName);
    const helper = support + '::' + xppMapHelperName(model, entry) + 'Encode';
    return '    if (!' + v + '.empty()) for (const auto& e : ' + v + ') w.BytesField(' + n + ', ' + helper + '(e.first, e.second));\n';
  }
  if (f.label !== 3) return xppEncodeSingular(model, f, v, '    ', support);
  if (XPP_VARINT.has(f.type)) {
    return '    if (!' + v + '.empty()) {\n'
      + '        ' + support + '::Writer payload;\n'
      + '        for (auto x : ' + v + ') payload.Varint(' + xppVarintExpr(f, 'x') + ');\n'
      + '        w.BytesField(' + n + ', payload.ToBytes());\n    }\n';
  }
  const fixed = XPP_FIXED[f.type];
  if (fixed) {
    return '    if (!' + v + '.empty()) {\n'
      + '        ' + support + '::Writer payload;\n'
      + '        for (auto x : ' + v + ') payload.Fixed' + fixed[1] + '(x);\n'
      + '        w.BytesField(' + n + ', payload.ToBytes());\n    }\n';
  }
  switch (f.type) {
    case 9: return '    for (const auto& x : ' + v + ') w.BytesField(' + n + ', grpcdc::Bytes(x.begin(), x.end()));\n';
    case 12: return '    for (const auto& x : ' + v + ') w.BytesField(' + n + ', x);\n';
    case 11: return '    for (const auto& x : ' + v + ') w.BytesField(' + n + ', x.MarshalDc());\n';
    default: throw new Error('unsupported repeated field type ' + f.type);
  }
}

function xppDecodeSingular(model, f, target, src, indent, support) {
  if (XPP_VARINT.has(f.type)) {
    return indent + target + ' = ' + (f.type === 14
      ? 'static_cast<' + xppEntryRef(model, xppResolve(model, f.typeName)) + '>(' + xppVarintDecode({ ...f, type: 5 }, src) + ')'
      : xppVarintDecode(f, src)) + ';\n';
  }
  if (XPP_FIXED[f.type]) {
    let conv;
    switch (f.type) {
      case 2: conv = support + '::BitsToFloat(static_cast<std::uint32_t>(' + src + '))'; break;
      case 1: conv = support + '::BitsToDouble(' + src + ')'; break;
      case 7: conv = 'static_cast<std::uint32_t>(' + src + ')'; break;
      case 15: conv = 'static_cast<std::int32_t>(' + src + ')'; break;
      default: conv = src;
    }
    return indent + target + ' = ' + conv + ';\n';
  }
  switch (f.type) {
    case 9: return indent + target + ' = std::string(' + src + '.begin(), ' + src + '.end());\n';
    case 12: return indent + target + ' = ' + src + ';\n';
    case 11: return indent + target + '.emplace();\n' + indent + target + '->UnmarshalDc(' + src + ');\n';
    default: throw new Error('unsupported field type ' + f.type);
  }
}

function xppOneofClearing(model, f) {
  return oneofSiblings(model, f).map((sib) => '            ' + sib.name + ' = ' + xppDefault(model, sib) + ';\n').join('');
}

function xppSrc(f) {
  return XPP_VARINT.has(f.type) ? 'field.varint' : (XPP_FIXED[f.type] ? 'field.fixed' : 'field.bytes');
}

function xppDecodeCase(model, f, support) {
  const v = f.name;
  const head = '        case ' + f.number + ': {\n';
  const tail = '            break;\n        }\n';
  const clearing = xppOneofClearing(model, f);
  if (f.type === FT.MESSAGE && xppResolve(model, f.typeName).kind === 'map') {
    const entry = xppResolve(model, f.typeName);
    const helper = support + '::' + xppMapHelperName(model, entry) + 'Decode';
    return head
      + '            auto kv = ' + helper + '(field.bytes);\n'
      + '            ' + v + '[kv.first] = kv.second;\n'
      + tail;
  }
  if (f.label !== 3) {
    return head + clearing + xppDecodeSingular(model, f, v, xppSrc(f), '            ', support) + tail;
  }
  if (XPP_VARINT.has(f.type)) {
    const conv = (src) => f.type === 14
      ? 'static_cast<' + xppEntryRef(model, xppResolve(model, f.typeName)) + '>(' + xppVarintDecode({ ...f, type: 5 }, src) + ')'
      : xppVarintDecode(f, src);
    return head
      + '            if (field.wire == 2) {\n'
      + '                ' + support + '::Reader sub(field.bytes);\n'
      + '                while (!sub.Done()) {\n'
      + '                    ' + v + '.push_back(' + conv('sub.Varint()') + ');\n'
      + '                }\n            } else {\n'
      + '                ' + v + '.push_back(' + conv('field.varint') + ');\n'
      + '            }\n'
      + tail;
  }
  const fixed = XPP_FIXED[f.type];
  if (fixed) {
    const subConv = f.type === 2 ? support + '::BitsToFloat(sub.Fixed32())'
      : f.type === 1 ? support + '::BitsToDouble(sub.Fixed64())'
      : f.type === 7 ? 'static_cast<std::uint32_t>(sub.Fixed32())'
      : f.type === 15 ? 'sub.Fixed32()' : 'sub.Fixed64()';
    const oneConv = f.type === 2 ? support + '::BitsToFloat(static_cast<std::uint32_t>(field.fixed))'
      : f.type === 1 ? support + '::BitsToDouble(field.fixed)'
      : f.type === 7 ? 'static_cast<std::uint32_t>(field.fixed)'
      : f.type === 15 ? 'static_cast<std::int32_t>(field.fixed)' : 'field.fixed';
    return head
      + '            if (field.wire == 2) {\n'
      + '                ' + support + '::Reader sub(field.bytes);\n'
      + '                while (!sub.Done()) ' + v + '.push_back(' + subConv + ');\n'
      + '            } else {\n'
      + '                ' + v + '.push_back(' + oneConv + ');\n'
      + '            }\n'
      + tail;
  }
  switch (f.type) {
    case 9: return head + '            ' + v + '.push_back(std::string(field.bytes.begin(), field.bytes.end()));\n' + tail;
    case 12: return head + '            ' + v + '.push_back(field.bytes);\n' + tail;
    case 11: return head
      + '            ' + xppEntryRef(model, xppResolve(model, f.typeName)) + ' item;\n'
      + '            item.UnmarshalDc(field.bytes);\n'
      + '            ' + v + '.push_back(item);\n'
      + tail;
    default: throw new Error('unsupported repeated field type ' + f.type);
  }
}

function xppMapHelperName(model, entry) {
  return xppRel(entry.pkg, entry.msg.fullName).split('::').join('');
}

function xppMapHelpers(model, entry, support) {
  const msg = entry.msg;
  const base = xppMapHelperName(model, entry);
  const keyF = msg.fields.find((x) => x.number === 1);
  const valF = msg.fields.find((x) => x.number === 2);
  if (!keyF || !valF) throw new Error('map entry lacks key/value');
  const kt = xppType(model, { ...keyF, label: 1 });
  const vt = xppType(model, { ...valF, label: 1 });
  const vtPlain = (valF.type === FT.MESSAGE && xppResolve(model, valF.typeName).kind !== 'map')
    ? xppEntryRef(model, xppResolve(model, valF.typeName))
    : vt;
  const decls = 'inline grpcdc::Bytes ' + base + 'Encode(const ' + kt + '& key, const ' + vtPlain + '& value);\n'
    + 'inline std::pair<' + kt + ', ' + vtPlain + '> ' + base + 'Decode(const grpcdc::Bytes& bytes);\n';
  const defs = 'inline grpcdc::Bytes ' + base + 'Encode(const ' + kt + '& key, const ' + vtPlain + '& value) {\n'
    + '    Writer w;\n'
    + xppEncodeSingular(model, { ...keyF, label: 1 }, 'key', '    ', support)
    + (valF.type === FT.MESSAGE
      ? '    w.BytesField(' + valF.number + ', value.MarshalDc());\n'
      : xppEncodeSingular(model, { ...valF, label: 1 }, 'value', '    ', support))
    + '    return w.ToBytes();\n}\n\n'
    + 'inline std::pair<' + kt + ', ' + vtPlain + '> ' + base + 'Decode(const grpcdc::Bytes& bytes) {\n'
    + '    ' + kt + ' key = ' + xppDefault(model, { ...keyF, label: 1 }) + ';\n'
    + '    ' + vtPlain + ' value' + (valF.type === FT.MESSAGE ? '' : ' = ' + xppDefault(model, { ...valF, label: 1 })) + ';\n'
    + '    Reader r(bytes);\n    Field field;\n    while (r.Next(field)) {\n        switch (field.number) {\n'
    + '            case ' + keyF.number + ': ' + xppDecodeSingular(model, { ...keyF, label: 1 }, 'key', xppSrc(keyF), '', support).replace(/\s+$/, '') + ' break;\n'
    + '            case ' + valF.number + ': ' + (valF.type === FT.MESSAGE
      ? 'value.UnmarshalDc(field.bytes);'
      : xppDecodeSingular(model, { ...valF, label: 1 }, 'value', xppSrc(valF), '', support).replace(/\s+$/, '')) + ' break;\n'
    + '            default: break;\n        }\n    }\n    return {key, value};\n}\n\n';
  return { decls, defs };
}

const XPP_SUPPORT_BODY = 'class Writer {\n'
  + '    grpcdc::Bytes out_;\n'
  + 'public:\n'
  + '    void Varint(std::uint64_t v) { while (v > 0x7f) { out_.push_back(static_cast<std::uint8_t>((v & 0x7f) | 0x80)); v >>= 7; } out_.push_back(static_cast<std::uint8_t>(v)); }\n'
  + '    void Tag(int field, int wire) { Varint(static_cast<std::uint64_t>((field << 3) | wire)); }\n'
  + '    void BytesField(int field, const grpcdc::Bytes& payload) { Tag(field, 2); Varint(payload.size()); out_.insert(out_.end(), payload.begin(), payload.end()); }\n'
  + '    void StringField(int field, const std::string& value) { if (value.empty()) return; BytesField(field, grpcdc::Bytes(value.begin(), value.end())); }\n'
  + '    void FixedInt32(std::int32_t v) { std::uint32_t u = static_cast<std::uint32_t>(v); for (int i = 0; i < 4; i++) out_.push_back(static_cast<std::uint8_t>((u >> (8 * i)) & 0xff)); }\n'
  + '    void FixedInt64(std::int64_t v) { std::uint64_t u = static_cast<std::uint64_t>(v); for (int i = 0; i < 8; i++) out_.push_back(static_cast<std::uint8_t>((u >> (8 * i)) & 0xff)); }\n'
  + '    void FixedFloat(float v) { std::uint32_t u; std::memcpy(&u, &v, 4); FixedInt32(static_cast<std::int32_t>(u)); }\n'
  + '    void FixedDouble(double v) { std::uint64_t u; std::memcpy(&u, &v, 8); FixedInt64(static_cast<std::int64_t>(u)); }\n'
  + '    void Raw(const grpcdc::Bytes& payload) { out_.insert(out_.end(), payload.begin(), payload.end()); }\n'
  + '    grpcdc::Bytes ToBytes() const { return out_; }\n'
  + '};\n\n'
  + 'inline float BitsToFloat(std::uint32_t u) { float v; std::memcpy(&v, &u, 4); return v; }\n'
  + 'inline double BitsToDouble(std::uint64_t u) { double v; std::memcpy(&v, &u, 8); return v; }\n\n'
  + 'struct Field {\n'
  + '    int number = 0; int wire = 0; std::uint64_t varint = 0; grpcdc::Bytes bytes; std::uint64_t fixed = 0; grpcdc::Bytes raw;\n'
  + '};\n\n'
  + 'class Reader {\n'
  + '    grpcdc::Bytes buf_; std::size_t pos_ = 0;\n'
  + 'public:\n'
  + '    explicit Reader(const grpcdc::Bytes& buf) : buf_(buf) {}\n'
  + '    bool Done() const { return pos_ >= buf_.size(); }\n'
  + '    std::uint64_t Varint() { std::uint64_t result = 0; int shift = 0; while (true) { if (pos_ >= buf_.size()) throw std::invalid_argument("truncated varint"); std::uint8_t b = buf_[pos_++]; result |= static_cast<std::uint64_t>(b & 0x7f) << shift; if ((b & 0x80) == 0) return result; shift += 7; if (shift >= 64) throw std::invalid_argument("varint too long"); } }\n'
  + '    grpcdc::Bytes Take(std::size_t n) { if (pos_ + n > buf_.size()) throw std::invalid_argument("truncated field"); grpcdc::Bytes v(buf_.begin() + pos_, buf_.begin() + pos_ + n); pos_ += n; return v; }\n'
  + '    std::uint32_t Fixed32() { auto b = Take(4); return static_cast<std::uint32_t>(b[0]) | (static_cast<std::uint32_t>(b[1]) << 8) | (static_cast<std::uint32_t>(b[2]) << 16) | (static_cast<std::uint32_t>(b[3]) << 24); }\n'
  + '    std::uint64_t Fixed64() { auto b = Take(8); std::uint64_t v = 0; for (int i = 0; i < 8; i++) v |= static_cast<std::uint64_t>(b[i]) << (8 * i); return v; }\n'
  + '    bool Next(Field& field) {\n'
  + '        if (pos_ >= buf_.size()) return false;\n'
  + '        std::size_t start = pos_;\n'
  + '        std::uint64_t tag = Varint(); field.number = static_cast<int>(tag >> 3); field.wire = static_cast<int>(tag & 7);\n'
  + '        switch (field.wire) {\n'
  + '            case 0: field.varint = Varint(); field.raw.assign(buf_.begin() + start, buf_.begin() + pos_); return true;\n'
  + '            case 2: { std::size_t n = static_cast<std::size_t>(Varint()); field.bytes = Take(n); field.raw.assign(buf_.begin() + start, buf_.begin() + pos_); return true; }\n'
  + '            case 1: field.bytes = Take(8); field.fixed = 0; for (int i = 0; i < 8; i++) field.fixed |= static_cast<std::uint64_t>(field.bytes[i]) << (8 * i); field.raw.assign(buf_.begin() + start, buf_.begin() + pos_); return true;\n'
  + '            case 5: field.bytes = Take(4); field.fixed = static_cast<std::uint32_t>(field.bytes[0]) | (static_cast<std::uint32_t>(field.bytes[1]) << 8) | (static_cast<std::uint32_t>(field.bytes[2]) << 16) | (static_cast<std::uint32_t>(field.bytes[3]) << 24); field.raw.assign(buf_.begin() + start, buf_.begin() + pos_); return true;\n'
  + '            default: throw std::invalid_argument("bad wire type");\n'
  + '        }\n'
  + '    }\n'
  + '};\n\n';

function xppNestedEnum(e, indent) {
  return indent + 'enum class ' + e.name + ' : std::int32_t {\n'
    + e.values.map((v) => indent + '  ' + v.name + ' = ' + v.number).join(',\n')
    + '\n' + indent + '};\n';
}

function xppMessageClass(model, msg, support, indent) {
  const pad = indent;
  const name = msg.name;
  return pad + 'class ' + name + ' : public grpcdc::Marshaler, public grpcdc::Unmarshaler {\n'
    + pad + ' public:\n'
    + msg.enums.map((e) => xppNestedEnum(e, indent + '  ')).join('')
    + msg.nested.map((n) => xppMessageClass(model, n, support, indent + '  ')).join('')
    + msg.fields.map((f) => pad + '  ' + xppType(model, f) + ' ' + f.name + ' = ' + xppDefault(model, f) + ';\n').join('')
    + pad + '  grpcdc::Bytes unknown_fields;\n'
    + pad + '  ' + name + '() = default;\n'
    + pad + '  grpcdc::Bytes MarshalDc() const override;\n'
    + pad + '  void UnmarshalDc(const grpcdc::Bytes& data) override;\n'
    + pad + '};\n';
}

function xppMessageImpls(model, msg, support, qual) {
  const q = qual ? qual + '::' + msg.name : msg.name;
  return 'inline grpcdc::Bytes ' + q + '::MarshalDc() const {\n'
    + '    ' + support + '::Writer w;\n'
    + msg.fields.map((f) => xppEncodeGuard(model, f, xppEncodeField(model, f, support))).join('')
    + '    w.Raw(unknown_fields);\n'
    + '    return w.ToBytes();\n}\n\n'
    + 'inline void ' + q + '::UnmarshalDc(const grpcdc::Bytes& data) {\n'
    + '    unknown_fields.clear();\n'
    + msg.fields.map((f) => '    ' + f.name + ' = ' + xppDefault(model, f) + ';\n').join('')
    + '    ' + support + '::Reader r(data);\n'
    + '    ' + support + '::Field field;\n'
    + '    while (r.Next(field)) {\n      switch (field.number) {\n'
    + msg.fields.map((f) => xppDecodeCase(model, f, support)).join('')
    + '        default: unknown_fields.insert(unknown_fields.end(), field.raw.begin(), field.raw.end()); break;\n'
    + '      }\n    }\n}\n\n'
    + msg.nested.filter((n) => !n.mapEntry).map((n) => xppMessageImpls(model, n, support, q)).join('');
}

function xppOrderedMessages(model) {
  const tops = model.messages.filter((m) => !m.mapEntry);
  const topOf = (e) => {
    if (!e || e.file !== model.name) return null;
    return xppRel(model.package, e.full).split('::')[0];
  };
  const depsOf = (m) => {
    const out = [];
    const note = (f) => {
      if (f.type !== 11) return;
      const e = xppResolve(model, f.typeName);
      if (!e) return;
      if (e.kind === 'map') {
        const valF = e.msg.fields.find((x) => x.name === 'value');
        if (valF && valF.type === 11) {
          const ve = xppResolve(model, valF.typeName);
          if (ve && ve.kind === 'message') { const t = topOf(ve); if (t && !out.includes(t)) out.push(t); }
        }
      } else if (e.kind === 'message' && f.label !== 3) {
        const t = topOf(e); if (t && !out.includes(t)) out.push(t);
      }
    };
    const walk = (msg) => { msg.fields.forEach(note); msg.nested.forEach(walk); };
    walk(m);
    return out;
  };
  const depMap = new Map(tops.map((m) => [m.name, depsOf(m)]));
  const remaining = new Set(tops.map((m) => m.name));
  const out = [];
  let rest = tops.slice();
  while (rest.length) {
    const next = rest.find((m) => depMap.get(m.name).every((d) => d === m.name || !remaining.has(d)));
    if (!next) throw new Error('emitCppPbFile: message dependency cycle');
    out.push(next);
    remaining.delete(next.name);
    rest = rest.filter((m) => m !== next);
  }
  return out;
}

function emitCppPbFile(model) {
  if (!model.messages.length && !model.enums.length) return null;
  const base = baseName(model.name);
  const pkg = model.package;
  const support = 'pb_' + base;
  const seenMaps = new Set();
  const helpers = [];
  const collect = (msg) => {
    for (const f of msg.fields) {
      if (f.type === FT.MESSAGE) {
        const e = xppResolve(model, f.typeName);
        if (e.kind === 'map' && !seenMaps.has(e.msg.fullName)) {
          seenMaps.add(e.msg.fullName);
          helpers.push(xppMapHelpers(model, e, support));
        }
      }
    }
    for (const n of msg.nested) collect(n);
  };
  for (const m of model.messages) collect(m);
  const ordered = xppOrderedMessages(model);
  const deps = model.dependencies || [];
  const content = '// @generated by protoc-gen-grpc-dc-cpp. DO NOT EDIT.\n'
    + '#pragma once\n\n'
    + '#include <cstdint>\n#include <cstring>\n#include <map>\n#include <optional>\n#include <stdexcept>\n#include <string>\n#include <utility>\n#include <vector>\n\n'
    + '#include "grpcdc/transport.hpp"\n'
    + deps.map((d) => '#include "' + baseName(d) + '_messages.hpp"\n').join('')
    + '\n'
    + 'namespace ' + xppNs(pkg) + ' {\n\n'
    + model.messages.filter((m) => !m.mapEntry).map((m) => 'class ' + m.name + ';\n').join('')
    + '\n'
    + model.enums.map((e) => 'enum class ' + e.name + ' : std::int32_t {\n'
      + e.values.map((v) => '  ' + v.name + ' = ' + v.number).join(',\n')
      + '\n};\n\n').join('')
    + 'namespace pb_' + base + ' {\n\n'
    + XPP_SUPPORT_BODY
    + '}  // namespace pb_' + base + '\n\n'
    + ordered.map((m) => xppMessageClass(model, m, support, '')).join('')
    + (helpers.length
      ? 'namespace pb_' + base + ' {\n\n' + helpers.map((h) => h.decls).join('') + '}  // namespace pb_' + base + '\n\n'
      : '')
    + ordered.map((m) => xppMessageImpls(model, m, support, '')).join('')
    + (helpers.length
      ? 'namespace pb_' + base + ' {\n\n' + helpers.map((h) => h.defs).join('') + '}  // namespace pb_' + base + '\n\n'
      : '')
    + '}  // namespace ' + xppNs(pkg) + '\n';
  return { name: base + '_messages.hpp', content };
}

function cppStubIncludes(model) {
  if (!model.types) return '#include "examples/' + baseName(model.name) + '_messages.hpp"\n';
  const files = new Set();
  for (const svc of model.services) {
    for (const m of svc.methods) {
      files.add(xppResolve(model, m.inputFull).file);
      files.add(xppResolve(model, m.outputFull).file);
    }
  }
  return [...files].map((f) => '#include "examples/' + baseName(f) + '_messages.hpp"\n').join('');
}

function emitCppFile(model, params) {
  const base = baseName(model.name);
  const structName = pascalName(base) + 'GrpcDc';
  const ns = xppNs(model.package);
  // Qualify cross-package method types (::pkg::...::Type) so stub
  // code resolves message types from other proto files.
  const qual = (full, plain) =>
    (!model.package || !full.includes('.') || full.startsWith(model.package + '.'))
      ? plain
      : '::' + full.split('.').join('::');
  const services = model.services.map((svc) => ({
    ...svc,
    methods: svc.methods.map((m) => ({
      ...m,
      input: qual(m.inputFull, m.input),
      output: qual(m.outputFull, m.output),
    })),
  }));
  const stub = {
    name: base + '_grpc_dc.hpp',
    content: '// @generated by protoc-gen-grpc-dc-cpp. DO NOT EDIT.\n'
      + '// source: ' + model.name + '\n'
      + '#pragma once\n\n'
      + '#include <future>\n#include <optional>\n\n#if __cplusplus >= 202002L\n#include "grpcdc/async.hpp"\n#endif\n'
      + '#include <memory>\n#include <vector>\n\n'
      + cppStubIncludes(model)
      + '#include "grpcdc/channel.hpp"\n#include "grpcdc/server.hpp"\n\n'
      + 'namespace ' + ns + ' {\n\n'
      + '/// Generated gRPC-over-DataChannels stubs for ' + model.name + '.\n'
      + 'struct ' + structName + ' {\n'
      + services.map(cppService).join('')
      + '};\n\n'
      + '}  // namespace ' + ns + '\n',
  };
  const pbFile = emitCppPbFile(model);
  return pbFile ? [stub, pbFile] : stub;
}

JS
)

(define js-part-9 #<<JS
// ---------------------------------------------------------------------------
// Swift emitter (mirrors the native swift template).
// ---------------------------------------------------------------------------



















const SWIFT_KIND_CONSTS = {
  unary: 'KindUnary',
  'server-streaming': 'KindServerStreaming',
  'client-streaming': 'KindClientStreaming',
  bidi: 'KindBidi',
};



function swiftService(svc) {
  return runSegments(SEGMENT_PROGRAMS.swiftService, svc, svc.name);
}

const SWIFT_RUN_BLOCKING =
  '#if canImport(Foundation)\n'
  + '/// Run an async operation to completion on a blocking thread.\n'
  + 'fileprivate func RunBlocking<T>(_ body: @escaping () async throws -> T) throws -> T {\n'
  + '    let semaphore = DispatchSemaphore(value: 0)\n'
  + '    var result: Result<T, Error>!\n'
  + '    Task.detached {\n'
  + '        do {\n            result = .success(try await body())\n'
  + '        } catch {\n            result = .failure(error)\n        }\n'
  + '        semaphore.signal()\n    }\n'
  + '    semaphore.wait()\n'
  + '    return try result.get()\n}\n'
  + '#endif\n';


// ---------------------------------------------------------------------------
// Swift message types, mirroring the native swift template
// (the swift-pb-* functions): a single <Base>Messages.swift per
// proto file with the <Base>Pb wire-support enum, enums and
// message classes. Byte-identical to the native
// protoc-gen-grpc-dc-swift plugin.
// ---------------------------------------------------------------------------

const SWP_VARINT = new Set(VARINT_TYPES);
const SWP_FIXED = FIXED_TABLES.swift;

function swpCamel(s) {
  const parts = s.split('_');
  if (!parts.length) return s;
  return parts[0] + parts.slice(1).map((p) => (p ? p[0].toUpperCase() + p.slice(1) : '')).join('');
}

function swpFieldName(f) {
  return f.jsonName ? f.jsonName : swpCamel(f.name);
}

function swpResolve(model, typeName) {
  const entry = model.types.get(typeName);
  if (!entry) throw new Error('unresolved type ' + typeName);
  return entry;
}

function swpRel(pkg, full) {
  const rel = pkg && full.startsWith(pkg + '.') ? full.slice(pkg.length + 1) : full;
  return rel.split('.').join('.');
}

function swpEntryRef(model, entry) {
  return entry.kind === 'enum'
    ? (entry.msg
      ? swpRel(entry.pkg, entry.msg.fullName) + '.' + entry.enum.name
      : swpRel(entry.pkg, (entry.pkg ? entry.pkg + '.' : '') + entry.enum.name))
    : swpRel(entry.pkg, entry.msg.fullName);
}































function swpMapHelperName(model, entry) {
  return swpRel(entry.pkg, entry.msg.fullName).split('.').join('');
}

function swpMapHelpers(model, entry, support) {
  return runSegments(SEGMENT_PROGRAMS.swiftPbMapHelpers, entry, null, model, [support]);
}

const SWP_SUPPORT_BODY = '    struct BadWireType: Error {}\n'
  + '    final class Writer {\n'
  + '        private var out: [UInt8] = []\n'
  + '        func Varint(_ value: UInt64) { var v = value; while v > 0x7f { out.append(UInt8((v & 0x7f) | 0x80)); v >>= 7 }; out.append(UInt8(v)) }\n'
  + '        func Varint(_ value: Int64) { Varint(UInt64(bitPattern: value)) }\n'
  + '        func Tag(_ field: Int, _ wire: Int) { Varint(UInt64((field << 3) | wire)) }\n'
  + '        func BytesField(_ field: Int, _ payload: [UInt8]) { Tag(field, 2); Varint(UInt64(payload.count)); out += payload }\n'
  + '        func StringField(_ field: Int, _ value: String) { if value.isEmpty { return }; BytesField(field, [UInt8](value.utf8)) }\n'
  + '        func FixedInt32(_ value: Int32) { FixedUInt32(UInt32(bitPattern: value)) }\n'
  + '        func FixedUInt32(_ value: UInt32) { for i in 0..<4 { out.append(UInt8((value >> (8 * i)) & 0xff)) } }\n'
  + '        func FixedInt64(_ value: Int64) { FixedUInt64(UInt64(bitPattern: value)) }\n'
  + '        func FixedUInt64(_ value: UInt64) { for i in 0..<8 { out.append(UInt8((value >> (8 * i)) & 0xff)) } }\n'
  + '        func FixedFloat(_ value: Float) { FixedUInt32(value.bitPattern) }\n'
  + '        func FixedDouble(_ value: Double) { FixedUInt64(value.bitPattern) }\n'
  + '        func Raw(_ payload: [UInt8]) { out += payload }\n'
  + '        func ToBytes() -> [UInt8] { out }\n'
  + '    }\n\n'
  + '    static func BitsToFloat(_ u: UInt32) -> Float { Float(bitPattern: u) }\n'
  + '    static func BitsToDouble(_ u: UInt64) -> Double { Double(bitPattern: u) }\n\n'
  + '    struct Field {\n'
  + '        var number: Int; var wire: Int; var varintValue: UInt64; var bytesValue: [UInt8]; var fixedValue: UInt64; var rawValue: [UInt8]\n'
  + '    }\n\n'
  + '    final class Reader {\n'
  + '        private let buf: [UInt8]; private var pos = 0\n'
  + '        init(_ buf: [UInt8]) { self.buf = buf }\n'
  + '        func Done() -> Bool { pos >= buf.count }\n'
  + '        func Varint() -> UInt64 { var result: UInt64 = 0; var shift: UInt64 = 0; while true { precondition(pos < buf.count, "truncated varint"); let b = buf[pos]; pos += 1; result |= UInt64(b & 0x7f) << shift; if (b & 0x80) == 0 { return result }; shift += 7; precondition(shift < 64, "varint too long") } }\n'
  + '        func Take(_ n: Int) -> [UInt8] { precondition(pos + n <= buf.count, "truncated field"); let v = [UInt8](buf[pos..<(pos + n)]); pos += n; return v }\n'
  + '        func Fixed32() -> UInt32 { let b = Take(4); return UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24) }\n'
  + '        func Fixed64() -> UInt64 { let b = Take(8); var v: UInt64 = 0; for i in 0..<8 { v |= UInt64(b[i]) << (8 * i) }; return v }\n'
  + '        func Next() throws -> Field? {\n'
  + '            if pos >= buf.count { return nil }\n'
  + '            let start = pos\n'
  + '            let tag = Varint(); let number = Int(tag >> 3); let wire = Int(tag & 7)\n'
  + '            switch wire {\n'
  + '            case 0: let v = Varint(); return Field(number: number, wire: wire, varintValue: v, bytesValue: [], fixedValue: 0, rawValue: [UInt8](buf[start..<pos]))\n'
  + '            case 2: let n = Int(Varint()); let b = Take(n); return Field(number: number, wire: wire, varintValue: 0, bytesValue: b, fixedValue: 0, rawValue: [UInt8](buf[start..<pos]))\n'
  + '            case 1: let b = Take(8); var v: UInt64 = 0; for i in 0..<8 { v |= UInt64(b[i]) << (8 * i) }; return Field(number: number, wire: wire, varintValue: 0, bytesValue: b, fixedValue: v, rawValue: [UInt8](buf[start..<pos]))\n'
  + '            case 5: let b = Take(4); let v = UInt64(UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)); return Field(number: number, wire: wire, varintValue: 0, bytesValue: b, fixedValue: v, rawValue: [UInt8](buf[start..<pos]))\n'
  + '            default: throw BadWireType()\n'
  + '            }\n'
  + '        }\n'
  + '    }\n\n';

function swpNestedEnum(e, indent) {
  return runSegments(SEGMENT_PROGRAMS.swiftPbNestedEnum, e, null, null, [indent]);
}

function swpMessageClass(model, msg, support, indent, decl) {
  return runSegments(SEGMENT_PROGRAMS.swiftPbMessage, msg, null, model, [support, indent, decl]);
}

function emitSwiftPbFile(model) {
  if (!model.messages.length && !model.enums.length) return null;
  const base = baseName(model.name);
  const support = pascalName(base) + 'Pb';
  const seenMaps = new Set();
  const helpers = [];
  const collect = (msg) => {
    for (const f of msg.fields) {
      if (f.type === FT.MESSAGE) {
        const e = swpResolve(model, f.typeName);
        if (e.kind === 'map' && !seenMaps.has(e.msg.fullName)) {
          seenMaps.add(e.msg.fullName);
          helpers.push(swpMapHelpers(model, e, support));
        }
      }
    }
    for (const n of msg.nested) collect(n);
  };
  for (const m of model.messages) collect(m);
  const content = '// @generated by protoc-gen-grpc-dc-swift. DO NOT EDIT.\n'
    + '#if canImport(Foundation)\nimport Foundation\n#endif\n\n'
    + 'enum ' + support + ' {\n'
    + SWP_SUPPORT_BODY
    + helpers.join('')
    + '}\n\n'
    + model.enums.map((e) => 'enum ' + e.name + ': Int32 {\n'
      + e.values.map((v) => '    case ' + v.name + ' = ' + v.number).join('\n')
      + '\n}\n\n').join('')
    + model.messages.filter((m) => !m.mapEntry).map((m) => swpMessageClass(model, m, support, '', 'final')).join('');
  return { name: pascalName(base) + 'Messages.swift', content };
}

function emitSwiftFile(model, params) {
  const base = baseName(model.name);
  const enumName = pascalName(base) + 'GrpcDc';
  const stub = {
    name: pascalName(base) + 'GrpcDc.swift',
    content: '// @generated by protoc-gen-grpc-dc-swift. DO NOT EDIT.\n'
      + '// source: ' + model.name + '\n\n'
      + '#if canImport(Foundation)\nimport Foundation\n#endif\n\n'
      + '/// Generated gRPC-over-DataChannels stubs for ' + model.name + '.\n'
      + 'enum ' + enumName + ' {\n'
      + model.services.map(swiftService).join('')
      + '}\n',
  };
  const pbFile = emitSwiftPbFile(model);
  return pbFile ? [stub, pbFile] : stub;
}

JS
)

(define js-part-10 #<<JS
// ---------------------------------------------------------------------------
// Kotlin emitter (mirrors the native kotlin template, native mode).
// kotlinWasmMode mirrors the native kotlin-wasm-mode setting:
// the kotlin-native emitter generates without the async
// (coroutine / CompletableFuture) surface.
// ---------------------------------------------------------------------------

let kotlinWasmMode = false;



















const KOTLIN_KIND_CONSTS = {
  unary: 'KIND_UNARY',
  'server-streaming': 'KIND_SERVER_STREAMING',
  'client-streaming': 'KIND_CLIENT_STREAMING',
  bidi: 'KIND_BIDI',
};



function kotlinService(svc) {
  return runSegments(SEGMENT_PROGRAMS.kotlinService, svc, svc.name);
}


// ---------------------------------------------------------------------------
// Kotlin message types, mirroring the native kotlin template
// (the kt-pb-* functions): a single <Base>Messages.kt per proto
// file with the <Base>Pb wire-support object, enums and message
// classes. Byte-identical to the native protoc-gen-grpc-dc-kotlin
// plugin.
// ---------------------------------------------------------------------------

const KT_VARINT = new Set(VARINT_TYPES);
const KT_FIXED = FIXED_TABLES.kotlin;

function kpCamel(s) {
  const parts = s.split('_');
  if (!parts.length) return s;
  return parts[0] + parts.slice(1).map((p) => (p ? p[0].toUpperCase() + p.slice(1) : '')).join('');
}

function kpFieldName(f) {
  return f.jsonName ? f.jsonName : kpCamel(f.name);
}

function kpResolve(model, typeName) {
  const entry = model.types.get(typeName);
  if (!entry) throw new Error('unresolved type ' + typeName);
  return entry;
}

function kpRel(pkg, full) {
  const rel = pkg && full.startsWith(pkg + '.') ? full.slice(pkg.length + 1) : full;
  return rel.split('.').join('.');
}

function kpEntryRef(model, entry) {
  const rel = entry.kind === 'enum'
    ? (entry.msg
      ? kpRel(entry.pkg, entry.msg.fullName) + '.' + entry.enum.name
      : kpRel(entry.pkg, (entry.pkg ? entry.pkg + '.' : '') + entry.enum.name))
    : kpRel(entry.pkg, entry.msg.fullName);
  if (entry.file === model.name) return rel;
  return entry.pkg === '' ? rel : entry.pkg + '.' + rel;
}































function kpMapHelperName(model, entry) {
  return kpRel(entry.pkg, entry.msg.fullName).split('.').join('');
}

function kpMapHelpers(model, entry, support) {
  return runSegments(SEGMENT_PROGRAMS.ktPbMapHelpers, entry, null, model, [support]);
}

function kpSupport(base, pkg, helpers) {
  const support = pascalName(base) + 'Pb';
  return '// @generated by protoc-gen-grpc-dc-kotlin. DO NOT EDIT.\n'
    + 'package ' + (pkg || 'proto') + '\n\n'
    + 'import grpcdc.Marshaler\nimport grpcdc.Unmarshaler\n\n'
    + 'object ' + support + ' {\n'
    + '    class Writer {\n'
    + '        private val out = java.io.ByteArrayOutputStream()\n'
    + '        fun varint(value: Long) { var v = value; while ((v and -0x80L) != 0L) { out.write(((v and 0x7f) or 0x80).toInt()); v = v ushr 7 }; out.write(v.toInt()) }\n'
    + '        fun varint(value: ULong) { varint(value.toLong()) }\n'
    + '        fun tag(field: Int, wire: Int) { varint(((field shl 3) or wire).toLong()) }\n'
    + '        fun bytesField(field: Int, payload: ByteArray) { tag(field, 2); varint(payload.size.toLong()); out.write(payload) }\n'
    + '        fun stringField(field: Int, value: String) { if (value.isEmpty()) return; bytesField(field, value.toByteArray(Charsets.UTF_8)) }\n'
    + '        fun fixedInt(value: Int) { for (i in 0 until 4) out.write((value shr (8 * i)) and 0xff) }\n'
    + '        fun fixedUInt(value: UInt) { fixedInt(value.toInt()) }\n'
    + '        fun fixedLong(value: Long) { for (i in 0 until 8) out.write(((value shr (8 * i)) and 0xff).toInt()) }\n'
    + '        fun fixedULong(value: ULong) { fixedLong(value.toLong()) }\n'
    + '        fun fixedFloat(value: Float) { fixedInt(value.toBits()) }\n'
    + '        fun fixedDouble(value: Double) { fixedLong(value.toBits()) }\n'
    + '        fun raw(payload: ByteArray) { out.write(payload) }\n'
    + '        fun toBytes(): ByteArray = out.toByteArray()\n'
    + '    }\n\n'
    + '    fun bitsToFloat(u: UInt): Float = Float.fromBits(u.toInt())\n'
    + '    fun bitsToDouble(u: ULong): Double = Double.fromBits(u.toLong())\n\n'
    + '    class Field(val number: Int, val wire: Int, val varintValue: Long, val bytesValue: ByteArray, val fixedValue: Long, val rawValue: ByteArray)\n\n'
    + '    class Reader(private val buf: ByteArray) {\n'
    + '        private var pos = 0\n'
    + '        fun done(): Boolean = pos >= buf.size\n'
    + '        fun varint(): Long { var result = 0L; var shift = 0; while (true) { if (pos >= buf.size) throw IllegalArgumentException("truncated varint"); val b = buf[pos++].toInt() and 0xff; result = result or ((b and 0x7f).toLong() shl shift); if ((b and 0x80) == 0) return result; shift += 7; if (shift >= 64) throw IllegalArgumentException("varint too long") } }\n'
    + '        fun take(n: Int): ByteArray { if (pos + n > buf.size) throw IllegalArgumentException("truncated field"); val v = buf.copyOfRange(pos, pos + n); pos += n; return v }\n'
    + '        fun fixed32(): UInt { val b = take(4); return (b[0].toInt() and 0xff).toUInt() or ((b[1].toInt() and 0xff).toUInt() shl 8) or ((b[2].toInt() and 0xff).toUInt() shl 16) or ((b[3].toInt() and 0xff).toUInt() shl 24) }\n'
    + '        fun fixed64(): ULong { val b = take(8); var v = 0UL; for (i in 0 until 8) v = v or ((b[i].toInt() and 0xff).toULong() shl (8 * i)); return v }\n'
    + '        fun next(): Field? {\n'
    + '            if (pos >= buf.size) return null\n'
    + '            val start = pos\n'
    + '            val tag = varint(); val number = (tag shr 3).toInt(); val wire = (tag and 7).toInt()\n'
    + '            return when (wire) {\n'
    + '                0 -> { val v = varint(); Field(number, wire, v, ByteArray(0), 0, buf.copyOfRange(start, pos)) }\n'
    + '                2 -> { val n = varint().toInt(); val b = take(n); Field(number, wire, 0, b, 0, buf.copyOfRange(start, pos)) }\n'
    + '                1 -> { val b = take(8); var v = 0L; for (i in 0 until 8) v = v or ((b[i].toInt() and 0xff).toLong() shl (8 * i)); Field(number, wire, 0, b, v, buf.copyOfRange(start, pos)) }\n'
    + '                5 -> { val b = take(4); val v = (b[0].toInt() and 0xff) or ((b[1].toInt() and 0xff) shl 8) or ((b[2].toInt() and 0xff) shl 16) or ((b[3].toInt() and 0xff) shl 24); Field(number, wire, 0, b, v.toLong(), buf.copyOfRange(start, pos)) }\n'
    + '                else -> throw IllegalArgumentException("bad wire type " + wire)\n'
    + '            }\n'
    + '        }\n'
    + '    }\n\n'
    + helpers
    + '}\n\n';
}

function kpEnumBody(e, indent) {
  return e.values.map((v) => indent + '    ' + v.name + '(' + v.number + ')').join(',\n')
    + ';\n'
    + indent + '    companion object {\n'
    + indent + '        fun fromNumber(number: Int): ' + e.name + ' =\n'
    + indent + '            when (number) {\n'
    + e.values.map((v) => indent + '                ' + v.number + ' -> ' + v.name + '\n').join('')
    + indent + '                else -> ' + e.values[0].name + '\n'
    + indent + '            }\n'
    + indent + '    }\n'
    + indent + '}\n';
}

function kpTopEnum(e) {
  return 'enum class ' + e.name + '(val number: Int) {\n'
    + kpEnumBody(e, '')
    + '\n';
}



function kpMessageClass(model, msg, support, indent, decl) {
  return runSegments(SEGMENT_PROGRAMS.ktPbMessage, msg, null, model, [support, indent, decl]);
}

function emitKotlinPbFile(model) {
  if (!model.messages.length && !model.enums.length) return null;
  const base = baseName(model.name);
  const pkg = model.package;
  const support = pascalName(base) + 'Pb';
  const seenMaps = new Set();
  const helpers = [];
  const collect = (msg) => {
    for (const f of msg.fields) {
      if (f.type === FT.MESSAGE) {
        const e = kpResolve(model, f.typeName);
        if (e.kind === 'map' && !seenMaps.has(e.msg.fullName)) {
          seenMaps.add(e.msg.fullName);
          helpers.push(kpMapHelpers(model, e, support));
        }
      }
    }
    for (const n of msg.nested) collect(n);
  };
  for (const m of model.messages) collect(m);
  const content = kpSupport(base, pkg, helpers.join(''))
    + model.enums.map(kpTopEnum).join('')
    + model.messages.filter((m) => !m.mapEntry).map((m) => kpMessageClass(model, m, support, '', '')).join('');
  return { name: pascalName(base) + 'Messages.kt', content };
}

function kotlinQualifyType(pkg, simple, full) {
  if (!full || !pkg || full.startsWith(pkg + '.')) return simple;
  return full;
}

function kotlinQualifyServices(pkg, services) {
  return services.map((svc) => ({
    ...svc,
    methods: svc.methods.map((m) => ({
      ...m,
      input: kotlinQualifyType(pkg, m.input, m.inputFull),
      output: kotlinQualifyType(pkg, m.output, m.outputFull),
    })),
  }));
}

function emitKotlinFile(model, params) {
  const base = baseName(model.name);
  const objectName = pascalName(base) + 'GrpcDc';
  const pkg = model.package || 'proto';
  const stub = {
    name: objectName + '.kt',
    content: '// @generated by protoc-gen-grpc-dc-kotlin. DO NOT EDIT.\n'
      + '// source: ' + model.name + '\n'
      + 'package ' + pkg + '\n\n'
      + 'import grpcdc.AsyncPump\nimport grpcdc.Channel\nimport grpcdc.Endpoint\nimport grpcdc.Server\nimport grpcdc.StatusException\nimport grpcdc.Wire\n'
      + 'import java.io.EOFException\nimport java.util.concurrent.CompletableFuture\n\n'
      + '/** Generated gRPC-over-DataChannels stubs for ' + model.name + '. */\n'
      + 'object ' + objectName + ' {\n'
      + kotlinQualifyServices(model.package, model.services).map(kotlinService).join('')
      + '}\n',
  };
  const pbFile = emitKotlinPbFile(model);
  return pbFile ? [stub, pbFile] : stub;
}

// Kotlin/Wasm native stubs: the same template in wasm mode
// (no CompletableFuture/async surface, timeouts as Long
// nanoseconds, EOF from grpcdc), with the native plugin's
// textual rewrites applied to the first file. Mirrors
// emit-wasm-kotlin-native-file in the native Kotlin template.
function emitKotlinNativeFile(model, params) {
  const saved = kotlinWasmMode;
  kotlinWasmMode = true;
  let result;
  try {
    result = emitKotlinFile(model, params);
  } finally {
    kotlinWasmMode = saved;
  }
  const files = Array.isArray(result) ? result : [result];
  const rewrites = [
    ['import grpcdc.AsyncPump\n', ''],
    ['import java.util.concurrent.CompletableFuture\n', ''],
    ['import java.io.EOFException\n', 'import grpcdc.EOFException\n'],
    ['java.time.Duration?', 'Long?'],
    ['protoc-gen-grpc-dc-kotlin', 'protoc-gen-grpc-dc-kotlin-native'],
  ];
  // Schemas without services legitimately lack the import and
  // Duration patterns; rewrite what is present.
  let content = files[0].content;
  for (const [from, to] of rewrites) {
    if (content.includes(from)) content = content.split(from).join(to);
  }
  return [{ name: files[0].name, content }, ...files.slice(1)];
}

JS
)

(define js-part-11 #<<JS
// ---------------------------------------------------------------------------
// Dart emitter (mirrors the native dart template).
// ---------------------------------------------------------------------------

function dartDeprecated(m, indent) {
  return runSegments(SEGMENT_PROGRAMS.dartDeprecated, m, '', null, [indent]);
}
function dartClientMethod(m) {
  return runSegments(SEGMENT_PROGRAMS.dartClientMethod, m, '');
}

function dartClientMethodRaw(m, svc) {
  return runSegments(SEGMENT_PROGRAMS.dartClientMethod, m, '');
}
function dartClientStreamClass(m, svc) {
  return runSegments(SEGMENT_PROGRAMS.dartClientStreamClass, m, svc);
}
function dartServerStreamIface(m, svc) {
  return runSegments(SEGMENT_PROGRAMS.dartServerStreamIface, m, svc);
}
function dartServerIfaceMethod(m, svc) {
  return runSegments(SEGMENT_PROGRAMS.dartServerIfaceMethod, m, svc);
}

function dartServerIfaceMethodRaw(m, svc) {
  return runSegments(SEGMENT_PROGRAMS.dartServerIfaceMethod, m, svc);
}
function dartStreamImpl(m, svc) {
  return runSegments(SEGMENT_PROGRAMS.dartStreamImpl, m, svc);
}
function dartRegisterMethod(m, svc) {
  return runSegments(SEGMENT_PROGRAMS.dartRegisterMethod, m, svc);
}
function dartService(svc) {
  return runSegments(SEGMENT_PROGRAMS.dartService, svc, svc.name);
}
function dartRegisterService(svc) {
  const sname = svc.name;
  return '  /// Register an implementation of ' + svc.fullName + ' on a Server.\n'
    + '  static void register' + sname + 'Server(Server server, ' + sname + 'Server impl) {\n'
    + '    server.registerService(ServiceDesc(' + q(svc.fullName) + ', [\n'
    + svc.methods.concat(aliasServerMethods(svc)).map((m) => dartRegisterMethod(m, sname)).join('')
    + '    ]));\n  }\n';
}


// ---------------------------------------------------------------------------
// Dart message types, mirroring the native dart template
// (the dart-pb-* functions): a single <base>_messages.dart per
// proto file with <Base>Pb wire-support classes and flattened
// message/enum classes. Byte-identical to the native
// protoc-gen-grpc-dc-dart plugin.
// ---------------------------------------------------------------------------

const DTP_VARINT = new Set(VARINT_TYPES);
const DTP_FIXED = FIXED_TABLES.dart;

function dtpCamel(s) {
  const parts = s.split('_');
  if (!parts.length) return s;
  return parts[0] + parts.slice(1).map((p) => (p ? p[0].toUpperCase() + p.slice(1) : '')).join('');
}

function dtpFieldName(f) {
  return f.jsonName ? f.jsonName : dtpCamel(f.name);
}

function dtpResolve(model, typeName) {
  const entry = model.types.get(typeName);
  if (!entry) throw new Error('unresolved type ' + typeName);
  return entry;
}

function dtpRel(pkg, full) {
  const rel = pkg && full.startsWith(pkg + '.') ? full.slice(pkg.length + 1) : full;
  return rel.split('.').join('_');
}

function dtpEntryRef(model, entry) {
  if (entry.kind === 'enum') return dtpRel(entry.pkg, entry.full);
  return dtpRel(entry.pkg, entry.msg.fullName);
}

function dtpTypeRef(model, entry) {
  return dtpEntryRef(model, entry).split('.').join('_');
}

function dtpScalar(f) {
  // Leaf payloads single-sourced from scalar-type-tables
  // in spec.rkt (SCALAR_TABLES), same table the native
  // template derives from.
  return SCALAR_TABLES.dart.types[f.type] ?? SCALAR_TABLES.dart.default;
}

function dtpType(model, f) {
  return runSegments(SEGMENT_PROGRAMS.dtPbType, f, '', model);
}
function dtpExplicitLiteral(model, f) {
  const lit = runSegments(SEGMENT_PROGRAMS.dtPbExplicitLiteral, f, '', model);
  return lit === '' ? null : lit;
}
function dtpDefault(model, f) {
  return runSegments(SEGMENT_PROGRAMS.dtPbDefault, f, '', model);
}
function dtpVarintExpr(f, v) {
  return runSegments(SEGMENT_PROGRAMS.dtPbVarintExpr, f, '', null, [v]);
}
function dtpVarintDecode(f, v) {
  return runSegments(SEGMENT_PROGRAMS.dtPbVarintDecode, f, '', null, [v]);
}
function dtpNonzero(f, v) {
  return runSegments(SEGMENT_PROGRAMS.dtPbNonzero, f, '', null, [v]);
}
function dtpEncodeSingular(model, f, v, indent, support) {
  return runSegments(SEGMENT_PROGRAMS.dtPbEncodeSingular, f, '', model, [v, indent]);
}
function dtpEncodeField(model, f, support) {
  return runSegments(SEGMENT_PROGRAMS.dtPbEncodeField, f, '', model, [support]);
}
function dtpDecodeSingular(model, f, target, src, indent, support) {
  return runSegments(SEGMENT_PROGRAMS.dtPbDecodeSingular, f, '', model, [target, src, indent, support]);
}
function dtpOneofClearing(model, f) {
  return runSegments(SEGMENT_PROGRAMS.dtPbOneofClearing, f, '', model);
}
function dtpSrc(f) {
  return DTP_VARINT.has(f.type) ? 'field.varintValue' : (DTP_FIXED[f.type] ? 'field.fixedValue' : 'field.bytesValue');
}

function dtpDecodeCase(model, f, support) {
  return runSegments(SEGMENT_PROGRAMS.dtPbDecodeCase, f, '', model, [support]);
}
function dtpMapHelpers(model, entry, support) {
  return runSegments(SEGMENT_PROGRAMS.dtPbMapHelpers, entry, '', model, [support]);
}
function dtpSupportHead(p) {
  return '// @generated by protoc-gen-grpc-dc-dart. DO NOT EDIT.\n'
    + "import 'dart:convert';\n"
    + "import 'dart:typed_data';\n\n"
    + "import '../grpcdc/transport.dart';\n\n"
    + 'class ' + p + 'Writer {\n'
    + '  final BytesBuilder _out = BytesBuilder();\n'
    + '  void varint(int value) { var v = BigInt.from(value) & ((BigInt.one << 64) - BigInt.one); final continuation = BigInt.from(0x80); while (v >= continuation) { _out.addByte(((v & BigInt.from(0x7f)) | continuation).toInt()); v = v >> 7; } _out.addByte(v.toInt()); }\n'
    + '  void tag(int field, int wire) { varint((field << 3) | wire); }\n'
    + '  void bytesField(int field, List<int> payload) { tag(field, 2); varint(payload.length); _out.add(payload); }\n'
    + '  void stringField(int field, String value) { if (value.isEmpty) return; bytesField(field, utf8.encode(value)); }\n'
    + '  void fixedUint32(int value) { final b = ByteData(4); b.setUint32(0, value, Endian.little); _out.add(b.buffer.asUint8List()); }\n'
    + '  void fixedInt32(int value) { final b = ByteData(4); b.setInt32(0, value, Endian.little); _out.add(b.buffer.asUint8List()); }\n'
    + '  void fixedUint64(int value) { final b = ByteData(8); b.setUint64(0, value, Endian.little); _out.add(b.buffer.asUint8List()); }\n'
    + '  void fixedInt64(int value) { final b = ByteData(8); b.setInt64(0, value, Endian.little); _out.add(b.buffer.asUint8List()); }\n'
    + '  void raw(List<int> payload) { _out.add(payload); }\n'
    + '  void fixedFloat32(double value) { final b = ByteData(4); b.setFloat32(0, value, Endian.little); _out.add(b.buffer.asUint8List()); }\n'
    + '  void fixedFloat64(double value) { final b = ByteData(8); b.setFloat64(0, value, Endian.little); _out.add(b.buffer.asUint8List()); }\n'
    + '  Uint8List toBytes() => _out.toBytes();\n'
    + '}\n\n'
    + 'double ' + p + 'BitsToFloat32(int bits) { final b = ByteData(4); b.setUint32(0, bits, Endian.little); return b.getFloat32(0, Endian.little); }\n'
    + 'double ' + p + 'BitsToFloat64(int bits) { final b = ByteData(8); b.setUint64(0, bits, Endian.little); return b.getFloat64(0, Endian.little); }\n\n'
    + 'class ' + p + 'Field {\n'
    + '  final int number; final int wire; final int varintValue; final Uint8List bytesValue; final int fixedValue; final Uint8List rawValue;\n'
    + '  ' + p + 'Field(this.number, this.wire, this.varintValue, this.bytesValue, this.fixedValue, this.rawValue);\n'
    + '}\n\n'
    + 'class ' + p + 'Reader {\n'
    + '  final Uint8List _buf; int _pos = 0;\n'
    + '  ' + p + 'Reader(this._buf);\n'
    + '  int _signed64(BigInt value) { final masked = value & ((BigInt.one << 64) - BigInt.one); return (masked >= (BigInt.one << 63) ? masked - (BigInt.one << 64) : masked).toInt(); }\n'
    + '  bool done() => _pos >= _buf.length;\n'
    + "  int varint() { var result = BigInt.zero; var shift = 0; while (true) { if (_pos >= _buf.length) throw StateError('truncated varint'); final b = _buf[_pos++]; result |= BigInt.from(b & 0x7f) << shift; if ((b & 0x80) == 0) return _signed64(result); shift += 7; if (shift >= 70) throw StateError('varint too long'); } }\n"
    + "  Uint8List take(int n) { if (_pos + n > _buf.length) throw StateError('truncated field'); final v = Uint8List.fromList(_buf.sublist(_pos, _pos + n)); _pos += n; return v; }\n"
    + '  int fixed32() { final b = take(4); return b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24); }\n'
    + '  int fixed64() { final b = take(8); var v = BigInt.zero; for (var i = 0; i < 8; i++) { v |= BigInt.from(b[i]) << (8 * i); } return _signed64(v); }\n'
    + '  ' + p + 'Field? next() {\n'
    + '    if (_pos >= _buf.length) return null;\n'
    + '    final start = _pos;\n'
    + '    final tag = varint(); final number = tag >> 3; final wire = tag & 7;\n'
    + '    switch (wire) {\n'
    + '      case 0: return ' + p + 'Field(number, wire, varint(), Uint8List(0), 0, Uint8List.fromList(_buf.sublist(start, _pos)));\n'
    + '      case 2: final n = varint(); return ' + p + 'Field(number, wire, 0, take(n), 0, Uint8List.fromList(_buf.sublist(start, _pos)));\n'
    + '      case 1: final b = take(8); var v = BigInt.zero; for (var i = 0; i < 8; i++) { v |= BigInt.from(b[i]) << (8 * i); } return ' + p + 'Field(number, wire, 0, b, _signed64(v), Uint8List.fromList(_buf.sublist(start, _pos)));\n'
    + '      case 5: final b = take(4); final v = b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24); return ' + p + 'Field(number, wire, 0, b, v, Uint8List.fromList(_buf.sublist(start, _pos)));\n'
    + "      default: throw StateError('bad wire type');\n"
    + '    }\n'
    + '  }\n'
    + '}\n\n';
}

function dtpClassName(model, msg) {
  return dtpRel(model.package, msg.fullName);
}

function dtpMessageClass(model, msg, support, indent) {
  return runSegments(SEGMENT_PROGRAMS.dtPbMessage, msg, '', model, [support, indent]);
}
function dtpEnumDecl(model, msg, e, indent) {
  return runSegments(SEGMENT_PROGRAMS.dtPbEnum, e, '', model, [indent, msg ? dtpClassName(model, msg) + '_' + e.name : e.name]);
}
function emitDartPbFile(model) {
  if (!model.messages.length && !model.enums.length) return null;
  const base = baseName(model.name);
  const support = pascalName(base) + 'Pb';
  const seenMaps = new Set();
  const helpers = [];
  const collect = (msg) => {
    for (const f of msg.fields) {
      if (f.type === FT.MESSAGE) {
        const e = dtpResolve(model, f.typeName);
        if (e.kind === 'map' && !seenMaps.has(e.msg.fullName)) {
          seenMaps.add(e.msg.fullName);
          helpers.push(dtpMapHelpers(model, e, support));
        }
      }
    }
    for (const n of msg.nested) collect(n);
  };
  for (const m of model.messages) collect(m);
  const deps = model.dependencies || [];
  const content = deps.map((d) => "import '" + baseName(d) + "_messages.dart';\n").join('')
    + dtpSupportHead(support)
    + helpers.join('')
    + model.enums.map((e) => dtpEnumDecl(model, null, e, '')).join('')
    + model.messages.filter((m) => !m.mapEntry).map((m) => dtpMessageClass(model, m, support, '')).join('');
  return { name: base + '_messages.dart', content };
}

function dartStubImports(model) {
  if (!model.types) return "import '" + baseName(model.name) + "_messages.dart';\n\n";
  const files = new Set();
  for (const svc of model.services) {
    for (const m of svc.methods) {
      files.add(dtpResolve(model, m.inputFull).file);
      files.add(dtpResolve(model, m.outputFull).file);
    }
  }
  return [...files].map((f) => "import '" + baseName(f) + "_messages.dart';\n").join('') + '\n';
}

function emitDartFile(model, params) {
  const base = baseName(model.name);
  const className = pascalName(base) + 'GrpcDc';
  const stub = {
    name: base + '_grpc_dc.dart',
    content: '// @generated by protoc-gen-grpc-dc-dart. DO NOT EDIT.\n'
      + '// source: ' + model.name + '\n\n'
      + "import 'dart:async';\n\n"
      + "import '../grpcdc/channel.dart';\nimport '../grpcdc/endpoint.dart';\nimport '../grpcdc/server.dart';\nimport '../grpcdc/status.dart';\nimport '../grpcdc/wire.dart';\n"
      + dartStubImports(model)
      + model.services.map(dartService).join('')
      + '/// Generated gRPC-over-DataChannels stubs for ' + model.name + '.\n'
      + 'class ' + className + ' {\n'
      + model.services.map(dartRegisterService).join('')
      + '}\n',
  };
  const pbFile = emitDartPbFile(model);
  return pbFile ? [stub, pbFile] : stub;
}

JS
)

(define js-part-12 #<<JS
// ---------------------------------------------------------------------------
// Zig emitter (mirrors the native zig template).
// ---------------------------------------------------------------------------

function zigSnake(s) {
  let out = '';
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (c >= 'A' && c <= 'Z') out += (i === 0 ? '' : '_') + c.toLowerCase();
    else out += c;
  }
  return out;
}













const ZIG_KIND_CONSTS = {
  unary: 'unary',
  'server-streaming': 'server_streaming',
  'client-streaming': 'client_streaming',
  bidi: 'bidi',
};

function zigRegisterMethod(m, svc) {
  return runSegments(SEGMENT_PROGRAMS.zigRegisterMethod, m, svc);
}

function zigService(svc) {
  return runSegments(SEGMENT_PROGRAMS.zigService, svc, svc.name);
}

function zigTypeOrigins(model) {
  const seen = [];
  for (const svc of model.services) {
    for (const m of svc.methods) {
      for (const [simple, full] of [[m.input, m.inputFull], [m.output, m.outputFull]]) {
        if (!seen.some(([n]) => n === simple)) {
          seen.push([simple, baseName(zgpResolve(model, full).file)]);
        }
      }
    }
  }
  return seen;
}

function zigStubImports(model) {
  if (!model.types) return 'const messages = @import("' + baseName(model.name) + '_messages.zig");\n\n';
  const bases = [...new Set(zigTypeOrigins(model).map(([, b]) => b))];
  return bases.map((b) => 'const ' + b + '_messages = @import("' + b + '_messages.zig");\n').join('') + '\n';
}

function zigMessageNames(model) {
  const seen = [];
  for (const svc of model.services) {
    for (const m of svc.methods) {
      for (const t of [m.input, m.output]) if (!seen.includes(t)) seen.push(t);
    }
  }
  return seen;
}

function zigRegisterService(svc) {
  const sname = svc.name;
  return '    /// Register an implementation of ' + svc.fullName + ' on a Server.\n'
    + '    pub fn register' + sname + 'Server(server: *Server, impl: *' + sname + 'Server) void {\n'
    + '        server.registerService(.{\n'
    + '            .name = ' + q(svc.fullName) + ',\n'
    + '            .methods = &.{\n'
    + svc.methods.concat(aliasServerMethods(svc)).map((m) => zigRegisterMethod(m, sname)).join('')
    + '            },\n        });\n    }\n';
}


// ---------------------------------------------------------------------------
// Zig message types, mirroring the native zig template
// (the zig-pb-* functions): a single <base>_messages.zig per proto
// file with Pb wire support, entry structs, enums and message
// structs. Byte-identical to the native protoc-gen-grpc-dc-zig
// plugin.
// ---------------------------------------------------------------------------

const ZGP_VARINT = new Set(VARINT_TYPES);
const ZGP_FIXED = FIXED_TABLES.zig;

function zgpResolve(model, typeName) {
  const entry = model.types.get(typeName);
  if (!entry) throw new Error('unresolved type ' + typeName);
  return entry;
}

function zgpRel(pkg, full) {
  return pkg && full.startsWith(pkg + '.') ? full.slice(pkg.length + 1) : full;
}

function zgpEntryRef(model, entry) {
  const rel = entry.kind === 'enum'
    ? (entry.msg
      ? zgpRel(entry.pkg, entry.msg.fullName) + '.' + entry.enum.name
      : zgpRel(entry.pkg, (entry.pkg ? entry.pkg + '.' : '') + entry.enum.name))
    : zgpRel(entry.pkg, entry.msg.fullName);
  if (entry.file === model.name) return rel;
  return baseName(entry.file) + '_messages.' + rel;
}



function zgpEntryStructName(model, entry) {
  return zgpEntryRef(model, entry).split('.').join('_');
}

function zgpType(model, f) {
  return runSegments(SEGMENT_PROGRAMS.zigPbType, f, null, model);
}



























function zgpMapHelpers(model, entry) {
  return runSegments(SEGMENT_PROGRAMS.zigPbMapHelpers, entry, null, model);
}

const ZGP_SUPPORT = '// @generated by protoc-gen-grpc-dc-zig. DO NOT EDIT.\n'
  + 'const std = @import("std");\n\n'
  + 'pub const PbWriter = struct {\n'
  + '    alloc: std.mem.Allocator,\n'
  + '    list: std.ArrayList(u8),\n'
  + '    pub fn init(alloc: std.mem.Allocator) PbWriter { return .{ .alloc = alloc, .list = std.ArrayList(u8).empty }; }\n'
  + '    pub fn deinit(self: *PbWriter) void { self.list.deinit(self.alloc); }\n'
  + '    pub fn varint(self: *PbWriter, value: u64) void { var v = value; while (v > 0x7f) { self.list.append(self.alloc, @as(u8, @truncate((v & 0x7f) | 0x80))) catch {}; v >>= 7; } self.list.append(self.alloc, @as(u8, @truncate(v))) catch {}; }\n'
  + '    pub fn tag(self: *PbWriter, field: u32, wire: u3) void { self.varint((@as(u64, field) << 3) | @as(u64, wire)); }\n'
  + '    pub fn bytesField(self: *PbWriter, field: u32, payload: []const u8) void { self.tag(field, 2); self.varint(payload.len); self.list.appendSlice(self.alloc, payload) catch {}; }\n'
  + '    pub fn stringField(self: *PbWriter, field: u32, value: []const u8) void { if (value.len == 0) return; self.bytesField(field, value); }\n'
  + '    pub fn raw(self: *PbWriter, payload: []const u8) void { self.list.appendSlice(self.alloc, payload) catch {}; }\n'
  + '    pub fn fixedf32(self: *PbWriter, value: f32) void { self.fixed32Bits(@bitCast(value)); }\n'
  + '    pub fn fixedf64(self: *PbWriter, value: f64) void { self.fixed64Bits(@bitCast(value)); }\n'
  + '    pub fn fixedu32(self: *PbWriter, value: u32) void { self.fixed32Bits(value); }\n'
  + '    pub fn fixedi32(self: *PbWriter, value: i32) void { self.fixed32Bits(@bitCast(value)); }\n'
  + '    pub fn fixedu64(self: *PbWriter, value: u64) void { self.fixed64Bits(value); }\n'
  + '    pub fn fixedi64(self: *PbWriter, value: i64) void { self.fixed64Bits(@bitCast(value)); }\n'
  + '    fn fixed32Bits(self: *PbWriter, value: u32) void { var b: [4]u8 = undefined; std.mem.writeInt(u32, &b, value, .little); self.list.appendSlice(self.alloc, &b) catch {}; }\n'
  + '    fn fixed64Bits(self: *PbWriter, value: u64) void { var b: [8]u8 = undefined; std.mem.writeInt(u64, &b, value, .little); self.list.appendSlice(self.alloc, &b) catch {}; }\n'
  + '    pub fn toBytes(self: *PbWriter) []u8 { return self.list.toOwnedSlice(self.alloc) catch &.{}; }\n'
  + '};\n\n'
  + 'pub const PbField = struct {\n'
  + '    number: u32,\n    wire: u3,\n    varint_value: u64 = 0,\n    bytes_value: []const u8 = &.{},\n    fixed_value: u64 = 0,\n    raw_value: []const u8 = &.{},\n'
  + '};\n\n'
  + 'pub const PbReader = struct {\n'
  + '    buf: []const u8,\n    pos: usize = 0,\n'
  + '    pub fn init(buf: []const u8) PbReader { return .{ .buf = buf }; }\n'
  + '    pub fn done(self: *PbReader) bool { return self.pos >= self.buf.len; }\n'
  + '    pub fn varint(self: *PbReader) u64 { var result: u64 = 0; var shift: u6 = 0; while (true) { if (self.pos >= self.buf.len) return result; const b = self.buf[self.pos]; self.pos += 1; result |= @as(u64, b & 0x7f) << shift; if ((b & 0x80) == 0) return result; shift += 7; if (shift >= 64) return result; } }\n'
  + '    pub fn take(self: *PbReader, n: usize) []const u8 { const end = @min(self.pos + n, self.buf.len); const v = self.buf[self.pos..end]; self.pos = end; return v; }\n'
  + '    pub fn fixed32Of(self: *PbReader, field: PbField) u32 { _ = self; return @as(u32, @truncate(field.fixed_value)); }\n'
  + '    pub fn fixed64Of(self: *PbReader, field: PbField) u64 { _ = self; return field.fixed_value; }\n'
  + '    pub fn next(self: *PbReader) ?PbField {\n'
  + '        if (self.pos >= self.buf.len) return null;\n'
  + '        const start = self.pos;\n'
  + '        const tagv = self.varint();\n'
  + '        var field = PbField{ .number = @as(u32, @truncate(tagv >> 3)), .wire = @as(u3, @truncate(tagv & 7)) };\n'
  + '        switch (field.wire) {\n'
  + '            0 => field.varint_value = self.varint(),\n'
  + '            2 => { const n = self.varint(); field.bytes_value = self.take(@as(usize, @truncate(n))); },\n'
  + '            1 => { field.bytes_value = self.take(8); field.fixed_value = std.mem.readInt(u64, field.bytes_value[0..8], .little); },\n'
  + '            5 => { field.bytes_value = self.take(4); field.fixed_value = std.mem.readInt(u32, field.bytes_value[0..4], .little); },\n'
  + '            else => return null,\n'
  + '        }\n'
  + '        field.raw_value = self.buf[start..self.pos];\n'
  + '        return field;\n'
  + '    }\n'
  + '};\n\n';





function zgpMessageStruct(model, msg, indent) {
  return runSegments(SEGMENT_PROGRAMS.zigPbMessage, msg, null, model, [indent]);
}

function emitZigPbFile(model) {
  if (!model.messages.length && !model.enums.length) return null;
  const base = baseName(model.name);
  const entryStructs = [];
  const seenStructs = new Set();
  const helpers = [];
  const collect = (msg) => {
    for (const f of msg.fields) {
      if (f.type === FT.MESSAGE) {
        const e = zgpResolve(model, f.typeName);
        if (e.kind === 'map') {
          const sname = zgpEntryStructName(model, e);
          if (!seenStructs.has(sname)) {
            seenStructs.add(sname);
            const em = e.msg;
            const kf = em.fields.find((x) => x.number === 1);
            const vf = em.fields.find((x) => x.number === 2);
            entryStructs.push('pub const ' + sname + ' = struct { key: ' + zgpType(model, { ...kf, label: 1 }) + ', value: '
              + (vf.type === FT.MESSAGE
                ? zgpEntryRef(model, zgpResolve(model, vf.typeName))
                : zgpType(model, { ...vf, label: 1 })) + ' };\n\n');
            helpers.push(zgpMapHelpers(model, e));
          }
        }
      }
    }
    for (const n of msg.nested) collect(n);
  };
  for (const m of model.messages) collect(m);
  const deps = model.dependencies || [];
  const content = ZGP_SUPPORT
    + deps.map((d) => 'const ' + baseName(d) + '_messages = @import("' + baseName(d) + '_messages.zig");\n').join('')
    + entryStructs.join('')
    + model.enums.map((e) => 'pub const ' + e.name + ' = enum(i32) {\n'
      + e.values.map((v) => '    ' + v.name + ' = ' + v.number).join(',\n')
      + ',\n};\n\n').join('')
    + model.messages.filter((m) => !m.mapEntry).map((m) => zgpMessageStruct(model, m, '')).join('')
    + helpers.join('');
  return { name: base + '_messages.zig', content };
}

function emitZigFile(model, params) {
  const base = baseName(model.name);
  const className = pascalName(base) + 'GrpcDc';
  const stub = {
    name: base + '_grpc_dc.zig',
    content: '// @generated by protoc-gen-grpc-dc-zig. DO NOT EDIT.\n'
      + '// source: ' + model.name + '\n\n'
      + 'const std = @import("std");\n'
      + 'const grpcdc = @import("grpcdc");\n'
      + 'const channel_mod = grpcdc.channel;\nconst endpoint_mod = grpcdc.endpoint;\nconst server_mod = grpcdc.server;\nconst status_mod = grpcdc.status;\nconst wire = grpcdc.wire;\n'
      + zigStubImports(model)
      + 'pub const Channel = channel_mod.Channel;\n'
      + 'pub const ClientStream = channel_mod.ClientStream;\n'
      + 'pub const CallContext = endpoint_mod.CallContext;\n'
      + 'pub const Server = server_mod.Server;\n'
      + 'pub const Status = status_mod.Status;\n'
      + 'pub const Metadata = channel_mod.Metadata;\n'
      + (model.types
        ? zigTypeOrigins(model).map(([n, b]) => 'pub const ' + n + ' = ' + b + '_messages.' + n + ';\n').join('')
        : zigMessageNames(model).map((msg) => 'pub const ' + msg + ' = messages.' + msg + ';\n').join(''))
      + '\n'
      + model.services.map(zigService).join('')
      + '/// Generated gRPC-over-DataChannels stubs for ' + model.name + '.\n'
      + 'pub const ' + className + ' = struct {\n'
      + model.services.map(zigRegisterService).join('')
      + '};\n',
  };
  const pbFile = emitZigPbFile(model);
  return pbFile ? [stub, pbFile] : stub;
}

JS
)

(define js-part-13 #<<JS
// ---------------------------------------------------------------------------
// Lua emitter (mirrors the native lua template).
// ---------------------------------------------------------------------------













const LUA_KIND_CONSTS = {
  unary: 'KIND_UNARY',
  'server-streaming': 'KIND_SERVER_STREAMING',
  'client-streaming': 'KIND_CLIENT_STREAMING',
  bidi: 'KIND_BIDI',
};

function luaRegisterMethod(m, svc) {
  return runSegments(SEGMENT_PROGRAMS.luaRegisterMethod, m, svc);
}

function luaService(svc) {
  return runSegments(SEGMENT_PROGRAMS.luaService, svc, svc.name);
}

function luaRegisterService(svc) {
  const sname = svc.name;
  return '--- Register an implementation of ' + svc.fullName + ' on a Server. The impl is\n'
    + '--- a table with unary/serverStream/clientStream/bidi functions\n'
    + '--- (duck-typed, mirroring the generated adapters below).\n'
    + 'local function register' + sname + 'Server(server, impl)\n'
    + '  server:registerService({\n'
    + '    name = ' + q(svc.fullName) + ',\n'
    + '    methods = {\n'
    + svc.methods.concat(aliasServerMethods(svc)).map((m) => luaRegisterMethod(m, sname)).join('')
    + '    },\n  })\nend\n\n';
}

function luaReturnEntry(svc) {
  const sname = svc.name;
  let out = '  ' + sname + 'Client = ' + sname + 'Client,\n'
    + '  ' + sname + 'ClientCoro = ' + sname + 'ClientCoro,\n';
  for (const m of svc.methods) {
    if (m.kind === 'server-streaming' || m.kind === 'bidi') out += '  ' + sname + m.name + 'CoroStream = ' + sname + m.name + 'CoroStream,\n';
  }
  for (const m of svc.methods) {
    if (m.kind === 'server-streaming' || m.kind === 'bidi') out += '  ' + sname + m.name + 'Stream = ' + sname + m.name + 'Stream,\n';
  }
  for (const m of svc.methods) {
    if (m.kind !== 'unary') out += '  ' + sname + m.name + 'Server = ' + sname + m.name + 'Server,\n';
  }
  return out + '  register' + sname + 'Server = register' + sname + 'Server,\n';
}


// ---------------------------------------------------------------------------
// Lua message types, mirroring the native lua template
// (the lua-pb-* functions): a single <base>_messages.lua per proto
// file with local Pb wire support, flattened message tables and
// map helpers. Byte-identical to the native
// protoc-gen-grpc-dc-lua plugin.
// ---------------------------------------------------------------------------

const LP_VARINT = new Set(VARINT_TYPES);
const LP_FIXED = FIXED_TABLES.lua;

function lpCamel(s) {
  const parts = s.split('_');
  if (!parts.length) return s;
  return parts[0] + parts.slice(1).map((p) => (p ? p[0].toUpperCase() + p.slice(1) : '')).join('');
}

function lpFieldName(f) {
  return f.jsonName ? f.jsonName : lpCamel(f.name);
}

function lpResolve(model, typeName) {
  const entry = model.types.get(typeName);
  if (!entry) throw new Error('unresolved type ' + typeName);
  return entry;
}

function lpFlat(pkg, full) {
  const rel = pkg && full.startsWith(pkg + '.') ? full.slice(pkg.length + 1) : full;
  return rel.split('.').join('_');
}

function lpEntryFlat(model, entry) {
  const local = lpFlat(entry.pkg, entry.kind === 'enum'
    ? (entry.msg ? entry.msg.fullName + '.' + entry.enum.name : (entry.pkg ? entry.pkg + '.' : '') + entry.enum.name)
    : entry.msg.fullName);
  if (entry.kind === 'map' || entry.file === model.name) return local;
  return baseName(entry.file) + '_messagesMessages.' + (entry.kind === 'enum' ? entry.enum.name : entry.msg.name);
}































function lpMapHelpers(model, entry) {
  return runSegments(SEGMENT_PROGRAMS.luaPbMapHelpers, entry, null, model);
}

const LP_SUPPORT = '-- @generated by protoc-gen-grpc-dc-lua. DO NOT EDIT.\n'
  + 'local Writer = {}\nWriter.__index = Writer\n\n'
  + 'local function bxor(a, b) return a ~ b end\n\n'
  + 'local function varintBytes(value)\n  local v = value\n  local parts = {}\n  if v < 0 then\n    for _ = 1, 9 do\n      parts[#parts + 1] = string.char((v & 0x7f) | 0x80)\n      v = v >> 7\n    end\n    parts[#parts + 1] = string.char(v & 0x7f)\n    return table.concat(parts)\n  end\n  while (v & ~0x7f) ~= 0 do\n    parts[#parts + 1] = string.char((v & 0x7f) | 0x80)\n    v = v >> 7\n  end\n  parts[#parts + 1] = string.char(v & 0x7f)\n  return table.concat(parts)\nend\n\n'
  + 'function Writer.new()\n  return setmetatable({ parts = {} }, Writer)\nend\n\n'
  + 'function Writer:varint(value)\n  self.parts[#self.parts + 1] = varintBytes(value)\nend\n\n'
  + 'function Writer:tag(field, wire)\n  self:varint((field << 3) | wire)\nend\n\n'
  + 'function Writer:bytesField(field, payload)\n  self:tag(field, 2)\n  self:varint(#payload)\n  self.parts[#self.parts + 1] = payload\nend\n\n'
  + 'function Writer:stringField(field, value)\n  if value == "" then return end\n  self:bytesField(field, value)\nend\n\n'
  + 'function Writer:fixed(fmt, value)\n  self.parts[#self.parts + 1] = string.pack(fmt, value)\nend\n\n'
  + 'function Writer:raw(payload)\n  self.parts[#self.parts + 1] = payload\nend\n\n'
  + 'function Writer:toBytes()\n  return table.concat(self.parts)\nend\n\n'
  + 'local Reader = {}\nReader.__index = Reader\n\n'
  + 'function Reader.new(buf)\n  return setmetatable({ buf = buf, pos = 1 }, Reader)\nend\n\n'
  + 'function Reader:done()\n  return self.pos > #self.buf\nend\n\n'
  + 'function Reader:varint()\n  local result = 0\n  local shift = 0\n  while true do\n    if self.pos > #self.buf then error("truncated varint") end\n    local b = self.buf:byte(self.pos)\n    self.pos = self.pos + 1\n    result = result | ((b & 0x7f) << shift)\n    if (b & 0x80) == 0 then return result end\n    shift = shift + 7\n    if shift >= 70 then error("varint too long") end\n  end\nend\n\n'
  + 'function Reader:take(n)\n  if self.pos + n - 1 > #self.buf then error("truncated field") end\n  local v = self.buf:sub(self.pos, self.pos + n - 1)\n  self.pos = self.pos + n\n  return v\nend\n\n'
  + 'function Reader:next()\n  if self.pos > #self.buf then return nil end\n  local start = self.pos\n  local tag = self:varint()\n  local number = tag >> 3\n  local wire = tag & 7\n  if wire == 0 then\n    local v = self:varint()\n    return { number = number, wire = wire, varintValue = v, bytesValue = "", fixedValue = "", rawValue = self.buf:sub(start, self.pos - 1) }\n  elseif wire == 2 then\n    local n = self:varint()\n    local b = self:take(n)\n    return { number = number, wire = wire, varintValue = 0, bytesValue = b, fixedValue = "", rawValue = self.buf:sub(start, self.pos - 1) }\n  elseif wire == 1 then\n    local b = self:take(8)\n    return { number = number, wire = wire, varintValue = 0, bytesValue = "", fixedValue = b, rawValue = self.buf:sub(start, self.pos - 1) }\n  elseif wire == 5 then\n    local b = self:take(4)\n    return { number = number, wire = wire, varintValue = 0, bytesValue = "", fixedValue = b, rawValue = self.buf:sub(start, self.pos - 1) }\n  end\n  error("bad wire type")\nend\n\n';

function lpMessageClass(model, msg) {
  return runSegments(SEGMENT_PROGRAMS.luaPbMessage, msg, null, model);
}

function lpEnumDecl(model, e) {
  return runSegments(SEGMENT_PROGRAMS.luaPbEnum, e, null, model);
}

function emitLuaPbFile(model) {
  if (!model.messages.length && !model.enums.length) return null;
  const base = baseName(model.name);
  const seenMaps = new Set();
  const helpers = [];
  let helperNames = [];
  const collect = (msg) => {
    for (const f of msg.fields) {
      if (f.type === FT.MESSAGE) {
        const e = lpResolve(model, f.typeName);
        if (e.kind === 'map' && !seenMaps.has(e.msg.fullName)) {
          seenMaps.add(e.msg.fullName);
          const b = lpEntryFlat(model, e);
          helperNames = [b + 'Encode', b + 'Decode', ...helperNames];
          helpers.unshift(lpMapHelpers(model, e));
        }
      }
    }
    for (const n of msg.nested) collect(n);
  };
  for (const m of model.messages) collect(m);
  const allMsgNames = (msg) => msg.mapEntry ? [] : [lpFlat(model.package, msg.fullName), ...msg.nested.flatMap(allMsgNames)];
  const deps = [...new Set((model.dependencies || []).map((d) => baseName(d)))];
  const depRequires = deps.map((d) => 'local ' + lpFlat('', d + '_messages') + 'Messages = require("examples.' + d + '_messages")\n').join('');
  const content = LP_SUPPORT
    + depRequires
    + (depRequires ? '\n' : '')
    + [...helperNames].reverse().map((n) => 'local ' + n + '\n').join('')
    + model.messages.flatMap(allMsgNames).map((n) => 'local ' + n + '\n').join('')
    + model.enums.map((e) => lpEnumDecl(model, e)).join('')
    + model.messages.filter((m) => !m.mapEntry).map((m) => lpMessageClass(model, m)).join('')
    + [...helpers].reverse().join('')
    + 'return {\n'
    + model.messages.filter((m) => !m.mapEntry).map((m) => '  ' + m.name + ' = ' + lpFlat(model.package, m.fullName) + ',\n').join('')
    + model.enums.map((e) => '  ' + e.name + ' = ' + lpFlat(model.package, model.package === '' ? e.name : model.package + '.' + e.name) + ',\n').join('')
    + '}\n';
  return { name: base + '_messages.lua', content };
}

function luaStubRequires(model) {
  if (!model.types) {
    return 'local messages = require("examples.' + baseName(model.name) + '_messages")\n\n'
      + zigMessageNames(model).map((msg) => 'local ' + msg + ' = messages.' + msg + '\n').join('')
      + '\n';
  }
  const origins = [];
  const seenNames = new Set();
  for (const svc of model.services) {
    for (const m of svc.methods) {
      for (const pair of [[m.input, m.inputFull], [m.output, m.outputFull]]) {
        if (seenNames.has(pair[0])) continue;
        seenNames.add(pair[0]);
        origins.push({ name: pair[0], file: lpResolve(model, pair[1]).file });
      }
    }
  }
  const files = [...new Set(origins.map((o) => o.file))];
  return files.map((fn) => {
      const b = baseName(fn);
      return 'local ' + lpFlat('', b) + 'Messages = require("examples.' + b + '_messages")\n';
    }).join('')
    + '\n'
    + origins.map((o) => 'local ' + o.name + ' = ' + lpFlat('', baseName(o.file)) + 'Messages.' + o.name + '\n').join('')
    + '\n';
}

function emitLuaFile(model, params) {
  const base = baseName(model.name);
  const stub = {
    name: base + '_grpc_dc.lua',
    content: '-- @generated by protoc-gen-grpc-dc-lua. DO NOT EDIT.\n'
      + '-- source: ' + model.name + '\n\n'
      + 'local channelModule = require("grpcdc.channel")\n'
      + 'local serverModule = require("grpcdc.server")\n'
      + 'local statusModule = require("grpcdc.status")\n'
      + 'local wire = require("grpcdc.wire")\n'
      + luaStubRequires(model)
      + 'local Channel = channelModule.Channel\n'
      + 'local Server = serverModule.Server\n'
      + 'local Status = statusModule.Status\n'
      + 'local EndOfStream = statusModule.EndOfStream\n\n'
      + model.services.map(luaService).join('')
      + model.services.map(luaRegisterService).join('')
      + 'return {\n'
      + model.services.map(luaReturnEntry).join('')
      + '}\n',
  };
  const pbFile = emitLuaPbFile(model);
  return pbFile ? [stub, pbFile] : stub;
}

JS
)

(define js-part-14 #<<JS
// ---------------------------------------------------------------------------
// Ruby emitter (mirrors the native ruby template).
// ---------------------------------------------------------------------------

function camelName(s) {
  return s.split('_').map((part) => (part ? part[0].toUpperCase() + part.slice(1) : part)).join('');
}

function rbDeprecated(m) {
  return runSegments(SEGMENT_PROGRAMS.rbDeprecated, m, '');
}
function rbStubRef(model, full) {
  const e = rbpResolve(model, full);
  return rbpModuleName(e) + '::' + rbpFlat(e.pkg, e.msg.fullName);
}

function rbStubRequires(model) {
  if (!model.types) return 'require_relative "' + baseName(model.name) + '_pb"\n';
  const files = new Set();
  for (const svc of model.services) {
    for (const m of svc.methods) {
      files.add(rbpResolve(model, m.inputFull).file);
      files.add(rbpResolve(model, m.outputFull).file);
    }
  }
  return [...files].map((fn) => 'require_relative "' + baseName(fn) + '_pb"\n').join('');
}

function rbClientMethodKind(model, m, fiber) {
  return runSegments(fiber ? SEGMENT_PROGRAMS.rbFiberClientMethod : SEGMENT_PROGRAMS.rbClientMethod, m, '', model);
}
function rbServerHandler(model, m) {
  return runSegments(SEGMENT_PROGRAMS.rbServerHandler, m, '', model);
}
function rbMethodEntry(m) {
  return runSegments(SEGMENT_PROGRAMS.rbMethodEntry, m, '');
}
function rbService(model, svc) {
  return runSegments(SEGMENT_PROGRAMS.rbService, svc, svc.name, model);
}
function rbpFlat(pkg, full) {
  const rel = pkg && full.startsWith(pkg + '.') ? full.slice(pkg.length + 1) : full;
  return rel.split('.').join('_');
}

function rbpResolve(model, typeName) {
  const entry = model.types.get(typeName);
  if (!entry) throw new Error('unresolved type ' + typeName);
  return entry;
}

function rbpModuleName(entry) {
  return camelName(baseName(entry.file)) + 'Pb';
}

function rbpEntryRef(model, entry) {
  const local = rbpFlat(entry.pkg, entry.kind === 'enum'
    ? (entry.msg ? entry.msg.fullName + '.' + entry.enum.name : (entry.pkg ? entry.pkg + '.' : '') + entry.enum.name)
    : entry.msg.fullName);
  if (entry.kind === 'map' || entry.file === model.name) return local;
  return rbpModuleName(entry) + '::' + (entry.kind === 'enum' ? entry.enum.name : rbpFlat(entry.pkg, entry.msg.fullName));
}

function rbpExplicitLiteral(model, f) {
  const lit = runSegments(SEGMENT_PROGRAMS.rbPbExplicitLiteral, f, '', model);
  return lit === '' ? null : lit;
}
function rbpDefault(model, f) {
  return runSegments(SEGMENT_PROGRAMS.rbPbDefault, f, '', model);
}
function rbpVarintExpr(f, v) {
  return runSegments(SEGMENT_PROGRAMS.rbPbVarintExpr, f, '', null, [v]);
}
function rbpVarintDecode(f, v) {
  return runSegments(SEGMENT_PROGRAMS.rbPbVarintDecode, f, '', null, [v]);
}
function rbpFixedFmt(f) {
  return FIXED_TABLES.ruby[f.type][1];
}
function rbpNonzero(f, v) {
  return runSegments(SEGMENT_PROGRAMS.rbPbNonzero, f, '', null, [v]);
}
function rbpEncodeSingular(model, pb, f, v, indent) {
  return runSegments(SEGMENT_PROGRAMS.rbPbEncodeSingular, f, '', model, [v, indent]);
}
function rbpEncodeField(model, pb, f) {
  return runSegments(SEGMENT_PROGRAMS.rbPbEncodeField, f, '', model, [pb]);
}
function rbpDecodeSingular(model, f, target, src, indent) {
  return runSegments(SEGMENT_PROGRAMS.rbPbDecodeSingular, f, '', model, [target, src, indent]);
}
function rbpOneofClearing(model, f) {
  return runSegments(SEGMENT_PROGRAMS.rbPbOneofClearing, f, '', model);
}
const RBP_FIXED = FIXED_TABLES.ruby;

const RBP_VARINT = new Set(VARINT_TYPES);

function rbpSrc(f) {
  return RBP_VARINT.has(f.type) ? 'varint_value' : (RBP_FIXED[f.type] ? 'fixed_value' : 'bytes_value');
}

function rbpDecodeCase(model, f) {
  return runSegments(SEGMENT_PROGRAMS.rbPbDecodeCase, f, '', model);
}
function rbpMapHelpers(model, pb, entry) {
  return runSegments(SEGMENT_PROGRAMS.rbPbMapHelpers, entry, '', model, [pb]);
}
function rbpSupport(pb) {
  return pb + 'PbVarint = lambda do |value|\n  out = +"".b\n  v = value & 0xffffffffffffffff\n  while v > 0x7f\n    out << ((v & 0x7f) | 0x80)\n    v >>= 7\n  end\n  out << v\n  out\nend\n\n'
    + '  class Writer\n'
    + '    def initialize\n      @out = String.new(encoding: Encoding::BINARY)\n    end\n\n'
    + '    def varint(value)\n      @out << ' + pb + 'PbVarint.call(value)\n    end\n\n'
    + '    def tag(field, wire)\n      varint((field << 3) | wire)\n    end\n\n'
    + '    def bytes_field(field, payload)\n      tag(field, 2)\n      varint(payload.bytesize)\n      @out << payload.b\n    end\n\n'
    + '    def string_field(field, value)\n      return if value.nil? || value.empty?\n\n      bytes_field(field, value.encode(Encoding::UTF_8).b)\n    end\n\n'
    + '    def fixed(fmt, value)\n      @out << [value].pack(fmt)\n    end\n\n'
    + '    def raw(payload)\n      @out << payload.b\n    end\n\n'
    + '    def to_bytes\n      @out\n    end\n  end\n\n'
    + '  class Reader\n'
    + '    def initialize(buf)\n      @buf = buf.b\n      @pos = 0\n    end\n\n'
    + '    def done?\n      @pos >= @buf.bytesize\n    end\n\n'
    + '    def varint\n      result = 0\n      shift = 0\n      loop do\n        raise ArgumentError, "truncated varint" if @pos >= @buf.bytesize\n\n        b = @buf.getbyte(@pos)\n        @pos += 1\n        result |= (b & 0x7f) << shift\n        return result if (b & 0x80).zero?\n\n        shift += 7\n        raise ArgumentError, "varint too long" if shift >= 70\n      end\n    end\n\n'
    + '    def take(n)\n      raise ArgumentError, "truncated field" if @pos + n > @buf.bytesize\n\n      value = @buf.byteslice(@pos, n)\n      @pos += n\n      value\n    end\n\n'
    + '    # [number, wire, varint_value, bytes_value, fixed_value] or nil.\n'
    + '    def field\n      return nil if done?\n\n      start = @pos\n      tag = varint\n      num = tag >> 3\n      wire = tag & 7\n      raw = -> { @buf.byteslice(start, @pos - start) }\n      case wire\n      when 0 then [num, wire, varint, "".b, "".b, raw.call]\n      when 2\n        n = varint\n        v = take(n)\n        [num, wire, 0, v, "".b, raw.call]\n      when 1\n        v = take(8)\n        [num, wire, 0, "".b, v, raw.call]\n      when 5\n        v = take(4)\n        [num, wire, 0, "".b, v, raw.call]\n      else raise ArgumentError, "bad wire type"\n      end\n    end\n  end\n\n';
}

function rbpMessageClass(model, pb, msg) {
  return runSegments(SEGMENT_PROGRAMS.rbPbMessage, msg, '', model, [pb]);
}
function rbpEnumDecl(model, e) {
  const full = model.package ? model.package + '.' + e.name : e.name;
  return runSegments(SEGMENT_PROGRAMS.rbPbEnum, e, '', model, [full]);
}
function emitRubyPbFile(model) {
  if (!model.messages.length && !model.enums.length) return null;
  const base = baseName(model.name);
  const pb = camelName(base);
  const seenMaps = new Set();
  const helpers = [];
  const collect = (msg) => {
    for (const f of msg.fields) {
      if (f.type === FT.MESSAGE) {
        const e = rbpResolve(model, f.typeName);
        if (e.kind === 'map' && !seenMaps.has(e.msg.fullName)) {
          seenMaps.add(e.msg.fullName);
          helpers.unshift(rbpMapHelpers(model, pb, e));
        }
      }
    }
    for (const n of msg.nested) collect(n);
  };
  for (const m of model.messages) collect(m);
  const deps = [...new Set((model.dependencies || []).map((d) => baseName(d)))];
  const content = deps.map((d) => 'require_relative "' + d + '_pb"\n').join('')
    + (deps.length ? '\n' : '')
    + 'module ' + pb + 'Pb\n'
    + rbpSupportBody(pb)
    + model.enums.map((e) => rbpEnumDecl(model, e)).join('')
    + model.messages.filter((m) => !m.mapEntry).map((m) => rbpMessageClass(model, pb, m)).join('')
    + [...helpers].reverse().join('')
    + 'end\n';
  return { name: base + '_pb.rb', content };
}

function rbpSupportBody(pb) {
  return '# @generated by protoc-gen-grpc-dc-ruby. DO NOT EDIT.\n'
    + rbpSupport(pb);
}

const RB_STREAM_HELPERS = `  # Client receiving stream: recv raises EOFError at end.
  class RecvStream
    include Enumerable

    def initialize(stream, resp_cls)
      @stream = stream
      @resp_cls = resp_cls
    end

    def recv
      @stream.recv(@resp_cls.new)
    end

    # Response initial metadata (after the first recv).
    def headers
      @stream.headers&.metadata
    end

    # Response trailing metadata (after the call ends).
    def trailers
      @stream.trailers
    end

    # Abandon the call early: RST so the server stops producing.
    def cancel
      @stream.cancel
    end

    def close
      @stream.cancel
    end

    def each
      return enum_for(:each) unless block_given?

      begin
        loop do
          begin
            yield recv
          rescue EOFError
            return
          end
        end
      ensure
        # Breaking out of the block abandons the call: RST so
        # the server stops producing (no-op once terminated).
        close
      end
    end
  end

  # Server-streaming sink passed to service implementations.
  class SendStream
    attr_reader :context

    def initialize(ctx, sink)
      @context = ctx
      @sink = sink
    end

    def send(resp)
      @sink.send(resp.marshal_dc)
    end
  end

  # Client-streaming stream passed to service implementations.
  class ClientStreamImpl
    attr_reader :context, :resp

    def initialize(ctx, reqs, req_cls)
      @context = ctx
      @reqs = reqs
      @req_cls = req_cls
      @resp = nil
    end

    def recv
      @reqs.recv_into(@req_cls.new)
    end

    def send_and_close(resp)
      @resp = resp
    end
  end

  # Bidi stream passed to service implementations.
  class BidiStream
    attr_reader :context

    def initialize(ctx, reqs, sink, req_cls)
      @context = ctx
      @reqs = reqs
      @sink = sink
      @req_cls = req_cls
    end

    def send(resp)
      @sink.send(resp.marshal_dc)
    end

    def recv
      @reqs.recv_into(@req_cls.new)
    end
  end

  # Fiber-based client receiving stream: a producer Fiber
  # yields each response; next_msg resumes it and raises
  # StopIteration when the call completes. cancel aborts
  # the underlying stream (RST).
  class FiberRecvStream
    include Enumerable

    DONE = Object.new

    def initialize(stream, resp_cls)
      @stream = stream
      @resp_cls = resp_cls
      @fiber = Fiber.new do
        begin
          loop { Fiber.yield(@stream.recv(@resp_cls.new)) }
        rescue EOFError
          DONE
        end
      end
    end

    def next_msg
      value = @fiber.resume
      raise StopIteration if value.equal?(DONE)

      value
    end

    # Response initial metadata (after the first recv).
    def headers
      @stream.headers&.metadata
    end

    # Response trailing metadata (after the call ends).
    def trailers
      @stream.trailers
    end

    def cancel
      @stream.cancel
    end

    def close
      @stream.cancel
    end

    def each
      return enum_for(:each) unless block_given?

      begin
        loop do
          begin
            yield next_msg
          rescue StopIteration
            return
          end
        end
      ensure
        # Breaking out of the block abandons the call: RST so
        # the server stops producing (no-op once terminated).
        close
      end
    end
  end

`;

function emitRubyFile(model, params) {
  const base = baseName(model.name);
  const pb = camelName(base) + 'Pb';
  const mod = camelName(base) + 'GrpcDc';
  const stub = {
    name: base + '_grpc_dc.rb',
    content: '# @generated by protoc-gen-grpc-dc-ruby. DO NOT EDIT.\n'
      + '# source: ' + model.name + '\n\n'
      + rbStubRequires(model)
      + 'require "grpcdc"\n\n'
      + 'module ' + mod + '\n'
      + RB_STREAM_HELPERS
      + model.services.map((svc) => rbService(model, svc)).join('')
      + 'end\n',
  };
  const pbFile = emitRubyPbFile(model);
  return pbFile ? [stub, pbFile] : stub;
}

JS
)

(define js-part-15 #<<JS
// ---------------------------------------------------------------------------
// PHP emitter (mirrors the native php template).
// ---------------------------------------------------------------------------

function phpDeprecated(m) {
  return runSegments(SEGMENT_PROGRAMS.phpDeprecated, m, '');
}
function phpStubRef(model, full) {
  const e = phpbResolve(model, full);
  return '\\' + phpbNamespace(e) + '\\' + phpbFlat(e.pkg, e.msg.fullName);
}

function phpStubRequires(model) {
  if (!model.types) return 'require_once __DIR__ . "/' + baseName(model.name) + '_pb.php";\n';
  const files = new Set();
  for (const svc of model.services) {
    for (const m of svc.methods) {
      files.add(phpbResolve(model, m.inputFull).file);
      files.add(phpbResolve(model, m.outputFull).file);
    }
  }
  return [...files].map((fn) => 'require_once __DIR__ . "/' + baseName(fn) + '_pb.php";\n').join('');
}

function phpClientMethodKind(model, m, fiber) {
  return runSegments(fiber ? SEGMENT_PROGRAMS.phpFiberClientMethod : SEGMENT_PROGRAMS.phpClientMethod, m, '', model);
}
function phpServerHandler(model, m) {
  return runSegments(SEGMENT_PROGRAMS.phpServerHandler, m, '', model);
}
function phpMethodEntry(m) {
  return runSegments(SEGMENT_PROGRAMS.phpMethodEntry, m, '');
}
function phpService(model, svc) {
  return runSegments(SEGMENT_PROGRAMS.phpService, svc, svc.name, model);
}
function phpbCamel(s) {
  const parts = s.split('_');
  if (!parts.length) return s;
  return parts[0] + parts.slice(1).map((p) => (p ? p[0].toUpperCase() + p.slice(1) : '')).join('');
}

function phpbFieldName(f) {
  return f.jsonName ? f.jsonName : phpbCamel(f.name);
}

const PHPB_RESERVED = new Set(('abstract and array as break callable case catch class clone const continue declare default do echo else elseif empty enddeclare endfor endforeach endif endswitch endwhile enum eval exit extends final finally fn for foreach function global goto if implements include include_once instanceof insteadof interface isset list match namespace new or parent print private protected public readonly require require_once return self static switch throw trait try unset use var while xor yield int float bool string true false null void iterable object mixed never resource numeric').split(' '));

function phpbFlat(pkg, full) {
  const rel = pkg && full.startsWith(pkg + '.') ? full.slice(pkg.length + 1) : full;
  const flat = rel.split('.').join('_');
  return PHPB_RESERVED.has(flat.toLowerCase()) ? flat + '_' : flat;
}

function phpbResolve(model, typeName) {
  const entry = model.types.get(typeName);
  if (!entry) throw new Error('unresolved type ' + typeName);
  return entry;
}

function phpbNamespace(entry) {
  return camelName(baseName(entry.file)) + 'Pb';
}

function phpbEntryRef(model, entry) {
  const local = phpbFlat(entry.pkg, entry.kind === 'enum'
    ? (entry.msg ? entry.msg.fullName + '.' + entry.enum.name : (entry.pkg ? entry.pkg + '.' : '') + entry.enum.name)
    : entry.msg.fullName);
  if (entry.kind === 'map' || entry.file === model.name) return local;
  return '\\' + phpbNamespace(entry) + '\\' + (entry.kind === 'enum' ? entry.enum.name : phpbFlat(entry.pkg, entry.msg.fullName));
}

function phpbType(model, f) {
  return runSegments(SEGMENT_PROGRAMS.phpPbType, f, '', model);
}
function phpbExplicitLiteral(model, f) {
  const lit = runSegments(SEGMENT_PROGRAMS.phpPbExplicitLiteral, f, '', model);
  return lit === '' ? null : lit;
}
function phpbDefault(model, f) {
  return runSegments(SEGMENT_PROGRAMS.phpPbDefault, f, '', model);
}
function phpbVarintExpr(f, v) {
  return runSegments(SEGMENT_PROGRAMS.phpPbVarintExpr, f, '', null, [v]);
}
function phpbVarintDecode(f, v) {
  return runSegments(SEGMENT_PROGRAMS.phpPbVarintDecode, f, '', null, [v]);
}
function phpbFixedFmt(f) {
  return FIXED_TABLES.php[f.type][1];
}
function phpbNonzero(f, v) {
  return runSegments(SEGMENT_PROGRAMS.phpPbNonzero, f, '', null, [v]);
}
function phpbFixedDecode(f, src) {
  return runSegments(SEGMENT_PROGRAMS.phpPbFixedDecode, f, '', null, [src]);
}
function phpbEncodeSingular(model, f, v, indent) {
  return runSegments(SEGMENT_PROGRAMS.phpPbEncodeSingular, f, '', model, [v, indent]);
}
function phpbEncodeField(model, f) {
  return runSegments(SEGMENT_PROGRAMS.phpPbEncodeField, f, '', model);
}
function phpbDecodeSingular(model, f, target, src, indent) {
  return runSegments(SEGMENT_PROGRAMS.phpPbDecodeSingular, f, '', model, [target, src, indent]);
}
function phpbOneofClearing(model, f) {
  return runSegments(SEGMENT_PROGRAMS.phpPbOneofClearing, f, '', model);
}
const PHPB_FIXED = FIXED_TABLES.php;

const PHPB_VARINT = new Set(VARINT_TYPES);

function phpbSrc(f) {
  return PHPB_VARINT.has(f.type) ? '$varintValue' : (PHPB_FIXED[f.type] ? '$fixedValue' : '$bytesValue');
}

function phpbDecodeCase(model, f) {
  return runSegments(SEGMENT_PROGRAMS.phpPbDecodeCase, f, '', model);
}
function phpbMapHelpers(model, entry) {
  return runSegments(SEGMENT_PROGRAMS.phpPbMapHelpers, entry, '', model);
}
function phpbMessageClass(model, msg) {
  return runSegments(SEGMENT_PROGRAMS.phpPbMessage, msg, '', model);
}
function phpbEnumDecl(model, e) {
  const full = model.package ? model.package + '.' + e.name : e.name;
  return runSegments(SEGMENT_PROGRAMS.phpPbEnum, e, '', model, [full]);
}
const PHPB_SUPPORT = 'function pbVarintBytes(int $value): string\n{\n    $out = "";\n    $v = $value;\n    while (true) {\n        $b = $v & 0x7f;\n        $v = ($v >> 7) & 0x01ffffffffffffff;\n        if ($v === 0) {\n            return $out . chr($b);\n        }\n        $out .= chr($b | 0x80);\n    }\n}\n\n'
  + 'final class Writer\n{\n    private string $out = "";\n\n'
  + '    public function varint(int $value): void\n    {\n        $this->out .= pbVarintBytes($value);\n    }\n\n'
  + '    public function tag(int $field, int $wire): void\n    {\n        $this->varint(($field << 3) | $wire);\n    }\n\n'
  + '    public function bytesField(int $field, string $payload): void\n    {\n        $this->tag($field, 2);\n        $this->varint(strlen($payload));\n        $this->out .= $payload;\n    }\n\n'
  + '    public function stringField(int $field, string $value): void\n    {\n        if ($value === "") {\n            return;\n        }\n        $this->bytesField($field, $value);\n    }\n\n'
  + '    public function fixed(string $fmt, $value): void\n    {\n        $this->out .= pack($fmt, $value);\n    }\n\n'
  + '    public function raw(string $payload): void\n    {\n        $this->out .= $payload;\n    }\n\n'
  + '    public function toBytes(): string\n    {\n        return $this->out;\n    }\n}\n\n'
  + 'final class Reader\n{\n    private string $buf;\n    private int $pos = 0;\n\n'
  + '    public function __construct(string $buf)\n    {\n        $this->buf = $buf;\n    }\n\n'
  + '    public function done(): bool\n    {\n        return $this->pos >= strlen($this->buf);\n    }\n\n'
  + '    public function varint(): int\n    {\n        $result = 0;\n        $shift = 0;\n        while (true) {\n            if ($this->pos >= strlen($this->buf)) {\n                throw new \\InvalidArgumentException("truncated varint");\n            }\n            $b = ord($this->buf[$this->pos]);\n            $this->pos++;\n            if ($shift < 63) {\n                $result |= ($b & 0x7f) << $shift;\n            } elseif (($b & 1) !== 0) {\n                $result |= PHP_INT_MIN;\n            }\n            if (($b & 0x80) === 0) {\n                return $result;\n            }\n            $shift += 7;\n            if ($shift >= 70) {\n                throw new \\InvalidArgumentException("varint too long");\n            }\n        }\n    }\n\n'
  + '    public function take(int $n): string\n    {\n        if ($this->pos + $n > strlen($this->buf)) {\n            throw new \\InvalidArgumentException("truncated field");\n        }\n        $value = substr($this->buf, $this->pos, $n);\n        $this->pos += $n;\n        return $value;\n    }\n\n'
  + '    /** [number, wire, varint_value, bytes_value, fixed_value] or null. */\n'
  + '    public function field(): ?array\n    {\n        if ($this->done()) {\n            return null;\n        }\n        $start = $this->pos;\n        $tag = $this->varint();\n        $num = $tag >> 3;\n        $wire = $tag & 7;\n        switch ($wire) {\n            case 0:\n                $v = $this->varint();\n                return [$num, $wire, $v, "", "", substr($this->buf, $start, $this->pos - $start)];\n            case 2:\n                $n = $this->varint();\n                $b = $this->take($n);\n                return [$num, $wire, 0, $b, "", substr($this->buf, $start, $this->pos - $start)];\n            case 1:\n                $b = $this->take(8);\n                return [$num, $wire, 0, "", $b, substr($this->buf, $start, $this->pos - $start)];\n            case 5:\n                $b = $this->take(4);\n                return [$num, $wire, 0, "", $b, substr($this->buf, $start, $this->pos - $start)];\n            default:\n                throw new \\InvalidArgumentException("bad wire type");\n        }\n    }\n}\n\n';

function emitPhpPbFile(model) {
  if (!model.messages.length && !model.enums.length) return null;
  const base = baseName(model.name);
  const seenMaps = new Set();
  const helpers = [];
  const collect = (msg) => {
    for (const f of msg.fields) {
      if (f.type === FT.MESSAGE) {
        const e = phpbResolve(model, f.typeName);
        if (e.kind === 'map' && !seenMaps.has(e.msg.fullName)) {
          seenMaps.add(e.msg.fullName);
          helpers.unshift(phpbMapHelpers(model, e));
        }
      }
    }
    for (const n of msg.nested) collect(n);
  };
  for (const m of model.messages) collect(m);
  const deps = [...new Set((model.dependencies || []).map((d) => baseName(d)))];
  const content = '<?php\n// @generated by protoc-gen-grpc-dc-php. DO NOT EDIT.\n\n'
    + 'namespace ' + camelName(base) + 'Pb;\n\n'
    + deps.map((d) => 'require_once __DIR__ . "/' + d + '_pb.php";\n').join('')
    + (deps.length ? '\n' : '')
    + PHPB_SUPPORT
    + model.enums.map((e) => phpbEnumDecl(model, e)).join('')
    + model.messages.filter((m) => !m.mapEntry).map((m) => phpbMessageClass(model, m)).join('')
    + [...helpers].reverse().join('');
  return { name: base + '_pb.php', content };
}

const PHP_STREAM_HELPERS = `// Client receiving stream: recv throws CallClosed at end.
class RecvStream
{
    private \\Grpcdc\\ClientStream $stream;
    private string $respClass;

    public function __construct(\\Grpcdc\\ClientStream $stream, string $respClass)
    {
        $this->stream = $stream;
        $this->respClass = $respClass;
    }

    public function recv(): object
    {
        $cls = $this->respClass;
        return $this->stream->recv(new $cls());
    }

    /** Response initial metadata (after the first recv). */
    public function headers(): ?array
    {
        return $this->stream->headers?->metadata;
    }

    /** Response trailing metadata (after the call ends). */
    public function trailers(): ?array
    {
        return $this->stream->trailers;
    }

    /** Abandon the call early: RST so the server stops producing. */
    public function cancel(): void
    {
        $this->stream->cancel();
    }

    public function close(): void
    {
        $this->stream->cancel();
    }

    public function __destruct()
    {
        $this->close();
    }

    /** @return \\Generator<int, object> */
    public function iterate(): \\Generator
    {
        $completed = false;
        try {
            while (true) {
                yield $this->recv();
            }
        } catch (\\Grpcdc\\CallClosed $e) {
            $completed = true;
            return;
        } finally {
            if (!$completed) {
                $this->close();
            }
        }
    }
}

// Server-streaming sink passed to service implementations.
class SendStream
{
    public \\Grpcdc\\CallContext $context;
    private \\Grpcdc\\ResponseSink $sink;

    public function __construct(\\Grpcdc\\CallContext $ctx, \\Grpcdc\\ResponseSink $sink)
    {
        $this->context = $ctx;
        $this->sink = $sink;
    }

    public function send(object $resp): void
    {
        $this->sink->send($resp->marshalDc());
    }
}

// Client-streaming stream passed to service implementations.
class ClientStreamImpl
{
    public \\Grpcdc\\CallContext $context;
    public ?object $resp = null;
    private \\Grpcdc\\RequestStream $reqs;
    private string $reqClass;

    public function __construct(\\Grpcdc\\CallContext $ctx, \\Grpcdc\\RequestStream $reqs, string $reqClass)
    {
        $this->context = $ctx;
        $this->reqs = $reqs;
        $this->reqClass = $reqClass;
    }

    public function recv(): object
    {
        $cls = $this->reqClass;
        return $this->reqs->recvInto(new $cls());
    }

    public function sendAndClose(object $resp): void
    {
        $this->resp = $resp;
    }
}

// Bidi stream passed to service implementations.
class BidiStream
{
    public \\Grpcdc\\CallContext $context;
    private \\Grpcdc\\RequestStream $reqs;
    private \\Grpcdc\\ResponseSink $sink;
    private string $reqClass;

    public function __construct(\\Grpcdc\\CallContext $ctx, \\Grpcdc\\RequestStream $reqs, \\Grpcdc\\ResponseSink $sink, string $reqClass)
    {
        $this->context = $ctx;
        $this->reqs = $reqs;
        $this->sink = $sink;
        $this->reqClass = $reqClass;
    }

    public function send(object $resp): void
    {
        $this->sink->send($resp->marshalDc());
    }

    public function recv(): object
    {
        $cls = $this->reqClass;
        return $this->reqs->recvInto(new $cls());
    }
}

// Fiber-based client receiving stream: a producer Fiber suspends
// per response; next() resumes it and throws CallClosed when the
// call completes. cancel aborts the underlying stream (RST).
class FiberRecvStream
{
    /** @var \\Grpcdc\\ClientStream|\\Grpcdc\\FiberClientStream */
    private $stream;
    private string $respClass;
    private ?\\Fiber $fiber = null;
    private bool $started = false;
    private bool $done = false;

    public function __construct($stream, string $respClass)
    {
        $this->stream = $stream;
        $this->respClass = $respClass;
    }

    public function next(): object
    {
        if ($this->done) {
            throw new \\Grpcdc\\CallClosed("stream exhausted");
        }
        if (!$this->started) {
            $this->started = true;
            $cls = $this->respClass;
            $stream = $this->stream;
            $this->fiber = new \\Fiber(function () use ($stream, $cls) {
                try {
                    while (true) {
                        \\Fiber::suspend($stream->recv(new $cls()));
                    }
                } catch (\\Grpcdc\\CallClosed $e) {
                    return;
                }
            });
            $value = $this->fiber->start();
        } else {
            $value = $this->fiber->resume();
        }
        if ($this->fiber->isTerminated()) {
            $this->done = true;
            throw new \\Grpcdc\\CallClosed("stream exhausted");
        }
        return $value;
    }

    /** @return \\Generator<int, object> */
    public function iterate(): \\Generator
    {
        $completed = false;
        try {
            while (true) {
                yield $this->next();
            }
        } catch (\\Grpcdc\\CallClosed $e) {
            $completed = true;
            return;
        } finally {
            if (!$completed) {
                $this->close();
            }
        }
    }

    /** Response initial metadata (after the first recv). */
    public function headers(): ?array
    {
        return $this->stream->headers?->metadata;
    }

    /** Response trailing metadata (after the call ends). */
    public function trailers(): ?array
    {
        return $this->stream->trailers;
    }

    public function cancel(): void
    {
        $this->stream->cancel();
    }

    public function close(): void
    {
        $this->stream->cancel();
    }

    public function __destruct()
    {
        $this->close();
    }
}

`;

function emitPhpFile(model, params) {
  const base = baseName(model.name);
  const pb = camelName(base) + 'Pb';
  const ns = camelName(base) + 'GrpcDc';
  const stub = {
    name: base + '_grpc_dc.php',
    content: '<?php\n// @generated by protoc-gen-grpc-dc-php. DO NOT EDIT.\n'
      + '// source: ' + model.name + '\n\n'
      + 'namespace ' + ns + ';\n\n'
      + phpStubRequires(model)
      + 'require_once __DIR__ . "/../grpcdc.php";\n\n'
      + PHP_STREAM_HELPERS
      + model.services.map((svc) => phpService(model, svc)).join(''),
  };
  const pbFile = emitPhpPbFile(model);
  return pbFile ? [stub, pbFile] : stub;
}

JS
)

(define js-part-16 #<<JS
// ---------------------------------------------------------------------------
// Scala emitter (mirrors the native scala template). Note: the
// template has no deprecated marker; stream helper classes use
// the service's FIRST method's request/response types.
// ---------------------------------------------------------------------------

function scalaKindOutputs(svc, kind) {
  return [...new Set(svc.methods.filter((m) => m.kind === kind).map((m) => m.output))];
}

function scalaKindPairs(svc, kind) {
  const seen = new Set();
  const out = [];
  for (const m of svc.methods.filter((x) => x.kind === kind)) {
    const key = m.input + "/" + m.output;
    if (!seen.has(key)) { seen.add(key); out.push([m.input, m.output]); }
  }
  return out;
}

function scalaSsTraitName(svc, out) {
  return scalaKindOutputs(svc, 'server-streaming').length <= 1 ? svc.name + 'ServerStreamServer' : svc.name + out + 'ServerStreamServer';
}

function scalaPairTraitName(svc, kind, inp, out, suffix) {
  return scalaKindPairs(svc, kind).length <= 1 ? svc.name + suffix : svc.name + inp + out + suffix;
}

function scalaClientStreamName(svc, kind, out) {
  const suffix = kind === 'server-streaming' ? 'ServerStreamStream' : 'BidiStream';
  return scalaKindOutputs(svc, kind).length <= 1 ? svc.name + suffix : svc.name + out + suffix;
}

function scalaClientMethod(m, svc) {
  return runSegments(SEGMENT_PROGRAMS.scalaClientMethod, m, '', null, [scalaClientStreamName(svc, 'server-streaming', m.output), scalaClientStreamName(svc, 'bidi', m.output)]);
}
function scalaFutureMethod(m) {
  return runSegments(SEGMENT_PROGRAMS.scalaFutureMethod, m, '');
}
function scalaServerIfaceMethod(m, svc) {
  return runSegments(SEGMENT_PROGRAMS.scalaServerIfaceMethod, m, '', null, [scalaSsTraitName(svc, m.output), scalaPairTraitName(svc, 'client-streaming', m.input, m.output, 'ClientStreamServer'), scalaPairTraitName(svc, 'bidi', m.input, m.output, 'BidiServer')]);
}
function scalaRegisterMethod(m, svc) {
  return runSegments(SEGMENT_PROGRAMS.scalaRegisterMethod, m, '', null, [scalaSsTraitName(svc, m.output), scalaPairTraitName(svc, 'client-streaming', m.input, m.output, 'ClientStreamServer'), scalaPairTraitName(svc, 'bidi', m.input, m.output, 'BidiServer')]);
}
function scalaServerAsyncIfaceMethod(m, svc) {
  return runSegments(SEGMENT_PROGRAMS.scalaServerAsyncIfaceMethod, m, '', null, [scalaSsTraitName(svc, m.output), scalaPairTraitName(svc, 'client-streaming', m.input, m.output, 'ClientStreamServer'), scalaPairTraitName(svc, 'bidi', m.input, m.output, 'BidiServer')]);
}
function scalaServerAsyncAdapterMethod(m, svc) {
  return runSegments(SEGMENT_PROGRAMS.scalaServerAsyncAdapterMethod, m, '', null, [scalaSsTraitName(svc, m.output), scalaPairTraitName(svc, 'client-streaming', m.input, m.output, 'ClientStreamServer'), scalaPairTraitName(svc, 'bidi', m.input, m.output, 'BidiServer')]);
}
function scalaService(svc) {
  return runSegments(SEGMENT_PROGRAMS.scalaService, svc, svc.name);
}
function scpCamel(s) {
  const parts = s.split('_');
  if (!parts.length) return s;
  return parts[0] + parts.slice(1).map((p) => (p ? p[0].toUpperCase() + p.slice(1) : '')).join('');
}

const SCP_KEYWORDS = new Set([
  'abstract', 'case', 'catch', 'class', 'def', 'do', 'else', 'extends',
  'false', 'final', 'finally', 'for', 'forSome', 'if', 'implicit',
  'import', 'lazy', 'match', 'new', 'null', 'object', 'override',
  'package', 'private', 'protected', 'return', 'sealed', 'super',
  'this', 'throw', 'trait', 'try', 'true', 'type', 'val', 'var',
  'while', 'with', 'yield',
]);

function scpFieldName(f) {
  const n = f.jsonName ? f.jsonName : scpCamel(f.name);
  return SCP_KEYWORDS.has(n) ? '`' + n + '`' : n;
}

function scpFlat(pkg, full) {
  const rel = pkg && full.startsWith(pkg + '.') ? full.slice(pkg.length + 1) : full;
  return rel.split('.').join('_');
}

function scpResolve(model, typeName) {
  const entry = model.types.get(typeName);
  if (!entry) throw new Error('unresolved type ' + typeName);
  return entry;
}

function scpEntryRef(model, entry) {
  const flat = scpFlat(entry.pkg, entry.kind === 'enum'
    ? (entry.msg ? entry.msg.fullName + '.' + entry.enum.name : (entry.pkg ? entry.pkg + '.' : '') + entry.enum.name)
    : entry.msg.fullName);
  const simple = entry.kind === 'enum' ? entry.enum.name : flat;
  if (entry.kind === 'map' || entry.file === model.name) {
    if (entry.kind === 'enum') {
      return scpFlat(entry.pkg, entry.msg
        ? entry.msg.fullName + '.' + simple
        : (entry.pkg ? entry.pkg + '.' : '') + simple);
    }
    return flat;
  }
  return entry.pkg + '.' + simple;
}

function scpScalarType(f) {
  // Leaf payloads single-sourced from scalar-type-tables
  // in spec.rkt (SCALAR_TABLES), same table the native
  // template derives from.
  return SCALAR_TABLES.scala.types[f.type] ?? SCALAR_TABLES.scala.default;
}

function scpElemType(model, f) {
  return runSegments(SEGMENT_PROGRAMS.scPbElemType, f, '', model);
}
function scpType(model, f) {
  return runSegments(SEGMENT_PROGRAMS.scPbType, f, '', model);
}
function scpExplicitLiteral(model, f) {
  const lit = runSegments(SEGMENT_PROGRAMS.scPbExplicitLiteral, f, '', model);
  return lit === '' ? null : lit;
}
function scpDefault(model, f) {
  return runSegments(SEGMENT_PROGRAMS.scPbDefault, f, '', model);
}
function scpVarintExpr(f, v) {
  return runSegments(SEGMENT_PROGRAMS.scPbVarintExpr, f, '', null, [v]);
}
function scpVarintDecode(f, v) {
  return runSegments(SEGMENT_PROGRAMS.scPbVarintDecode, f, '', null, [v]);
}
function scpFixedEncodeExpr(f, v, obj) {
  return runSegments(SEGMENT_PROGRAMS.scPbFixedEncode, f, '', null, [obj, v]);
}
function scpFixedDecodeExpr(f, src, obj) {
  return runSegments(SEGMENT_PROGRAMS.scPbFixedDecode, f, '', null, [obj, src]);
}
function scpNonzero(f, v) {
  return runSegments(SEGMENT_PROGRAMS.scPbNonzero, f, '', null, [v]);
}
function scpEncodeSingular(model, f, v, indent, obj) {
  return runSegments(SEGMENT_PROGRAMS.scPbEncodeSingular, f, '', model, [obj, v, indent]);
}
function scpEncodeField(model, f, obj) {
  return runSegments(SEGMENT_PROGRAMS.scPbEncodeField, f, '', model, [obj]);
}
function scpDecodeSingular(model, f, target, src, indent, obj) {
  return runSegments(SEGMENT_PROGRAMS.scPbDecodeSingular, f, '', model, [obj, target, src, indent]);
}
function scpOneofClearing(model, f) {
  return runSegments(SEGMENT_PROGRAMS.scPbOneofClearing, f, '', model);
}
const SCP_FIXED = FIXED_TABLES.scala;

const SCP_VARINT = new Set(VARINT_TYPES);

function scpSrc(f) {
  return SCP_VARINT.has(f.type) ? 'field.varintValue' : (SCP_FIXED[f.type] ? 'field.fixedValue' : 'field.bytesValue');
}

function scpDecodeCase(model, f, obj) {
  return runSegments(SEGMENT_PROGRAMS.scPbDecodeCase, f, '', model, [obj]);
}
function scpMapHelpers(model, entry, obj) {
  return runSegments(SEGMENT_PROGRAMS.scPbMapHelpers, entry, '', model, [obj]);
}
function scpSupportHead(obj) {
  return 'object ' + obj + ' {\n'
    + '  class Writer {\n'
    + '    private val out = new java.io.ByteArrayOutputStream()\n\n'
    + '    def varint(value: Long): Unit = {\n      var v = value\n      while ((v & -0x80L) != 0L) {\n        out.write(((v & 0x7f) | 0x80).toInt)\n        v = v >>> 7\n      }\n      out.write(v.toInt)\n    }\n\n'
    + '    def tag(field: Int, wire: Int): Unit = {\n      varint(((field << 3) | wire).toLong)\n    }\n\n'
    + '    def bytesField(field: Int, payload: Array[Byte]): Unit = {\n      tag(field, 2)\n      varint(payload.length.toLong)\n      out.write(payload)\n    }\n\n'
    + '    def stringField(field: Int, value: String): Unit = {\n      if (value.nonEmpty) {\n        bytesField(field, value.getBytes(java.nio.charset.StandardCharsets.UTF_8))\n      }\n    }\n\n'
    + '    def fixed(field: Int, wire: Int, payload: Array[Byte]): Unit = {\n      tag(field, wire)\n      out.write(payload)\n    }\n\n'
    + '    def raw(payload: Array[Byte]): Unit = {\n      out.write(payload)\n    }\n\n'
    + '    def toBytes: Array[Byte] = out.toByteArray\n  }\n\n'
    + '  def varintBytes(value: Long): Array[Byte] = {\n    val w = new Writer()\n    w.varint(value)\n    w.toBytes\n  }\n\n'
    + '  def int32BytesLE(value: Int): Array[Byte] = {\n    Array((value & 0xff).toByte, ((value >> 8) & 0xff).toByte, ((value >> 16) & 0xff).toByte, ((value >> 24) & 0xff).toByte)\n  }\n\n'
    + '  def int64BytesLE(value: Long): Array[Byte] = {\n    val out = new Array[Byte](8)\n    var i = 0\n    while (i < 8) {\n      out(i) = ((value >> (8 * i)) & 0xffL).toByte\n      i += 1\n    }\n    out\n  }\n\n'
    + '  def toInt32LE(bytes: Array[Byte], off: Int): Int = {\n    (bytes(off) & 0xff) | ((bytes(off + 1) & 0xff) << 8) | ((bytes(off + 2) & 0xff) << 16) | ((bytes(off + 3) & 0xff) << 24)\n  }\n\n'
    + '  def toInt64LE(bytes: Array[Byte], off: Int): Long = {\n    var result = 0L\n    var i = 0\n    while (i < 8) {\n      result |= (bytes(off + i) & 0xffL) << (8 * i)\n      i += 1\n    }\n    result\n  }\n\n'
    + '  class Field(val number: Int, val wire: Int, val varintValue: Long, val bytesValue: Array[Byte], val fixedValue: Array[Byte], val rawValue: Array[Byte])\n\n'
    + '  class Reader(private val buf: Array[Byte]) {\n'
    + '    private var pos = 0\n\n'
    + '    def done: Boolean = pos >= buf.length\n\n'
    + '    def varint(): Long = {\n      var result = 0L\n      var shift = 0\n      while (true) {\n        if (pos >= buf.length) {\n          throw new IllegalArgumentException("truncated varint")\n        }\n        val b = buf(pos).toInt & 0xff\n        pos += 1\n        result = result | ((b & 0x7f).toLong << shift)\n        if ((b & 0x80) == 0) {\n          return result\n        }\n        shift += 7\n        if (shift >= 70) {\n          throw new IllegalArgumentException("varint too long")\n        }\n      }\n      0L\n    }\n\n'
    + '    def take(n: Int): Array[Byte] = {\n      if (pos + n > buf.length) {\n        throw new IllegalArgumentException("truncated field")\n      }\n      val value = buf.slice(pos, pos + n)\n      pos += n\n      value\n    }\n\n'
    + '    def next(): Field = {\n      if (done) {\n        return null\n      }\n      val start = pos\n      val tag = varint()\n      val number = (tag >>> 3).toInt\n      val wire = (tag & 7).toInt\n      wire match {\n        case 0 =>\n          val v = varint()\n          new Field(number, wire, v, Array.empty[Byte], Array.empty[Byte], buf.slice(start, pos))\n        case 2 =>\n          val n = varint().toInt\n          new Field(number, wire, 0L, take(n), Array.empty[Byte], buf.slice(start, pos))\n        case 1 => new Field(number, wire, 0L, Array.empty[Byte], take(8), buf.slice(start, pos))\n        case 5 => new Field(number, wire, 0L, Array.empty[Byte], take(4), buf.slice(start, pos))\n        case _ => throw new IllegalArgumentException("bad wire type")\n      }\n    }\n  }\n';
}

function scpMessageClass(model, msg, obj) {
  return runSegments(SEGMENT_PROGRAMS.scPbMessage, msg, '', model, [obj]);
}
function scpEnumDecl(model, e) {
  const full = model.package ? model.package + '.' + e.name : e.name;
  return runSegments(SEGMENT_PROGRAMS.scPbEnum, e, '', model, [full]);
}
function emitScalaPbFile(model) {
  if (!model.messages.length && !model.enums.length) return null;
  const base = baseName(model.name);
  const obj = pascalName(base) + 'Pb';
  const seenMaps = new Set();
  const helpers = [];
  const collect = (msg) => {
    for (const f of msg.fields) {
      if (f.type === FT.MESSAGE) {
        const e = scpResolve(model, f.typeName);
        if (e.kind === 'map' && !seenMaps.has(e.msg.fullName)) {
          seenMaps.add(e.msg.fullName);
          helpers.unshift(scpMapHelpers(model, e, obj));
        }
      }
    }
    for (const n of msg.nested) collect(n);
  };
  for (const m of model.messages) collect(m);
  const content = '// @generated by protoc-gen-grpc-dc-scala. DO NOT EDIT.\n'
    + (model.package ? 'package ' + model.package + '\n\n' : '')
    + scpSupportHead(obj)
    + helpers.join('')
    + '}\n\n'
    + model.enums.map((e) => scpEnumDecl(model, e)).join('')
    + model.messages.filter((m) => !m.mapEntry).map((m) => scpMessageClass(model, m, obj)).join('');
  return { name: pascalName(base) + 'Messages.scala', content };
}

function scalaQualifyType(pkg, simple, full) {
  if (!full || !pkg || full.startsWith(pkg + '.')) return simple;
  return full;
}

function scalaQualifyServices(pkg, services) {
  return services.map((svc) => ({
    ...svc,
    methods: svc.methods.map((m) => ({
      ...m,
      input: scalaQualifyType(pkg, m.input, m.inputFull),
      output: scalaQualifyType(pkg, m.output, m.outputFull),
    })),
  }));
}

function emitScalaFile(model, params) {
  const base = baseName(model.name);
  const objName = camelName(base) + 'GrpcDc';
  const stub = {
    name: objName + '.scala',
    content: '// @generated by protoc-gen-grpc-dc-scala. DO NOT EDIT.\n'
      + '// source: ' + model.name + '\n'
      + 'package ' + model.package + '\n\n'
      + '/** Generated gRPC-over-DataChannels stubs. */\n'
      + 'object ' + objName + ' {\n'
      + scalaQualifyServices(model.package, model.services).map(scalaService).join('')
      + '}\n',
  };
  const pbFile = emitScalaPbFile(model);
  return pbFile ? [stub, pbFile] : stub;
}

JS
)

(define js-part-17 #<<JS
// ---------------------------------------------------------------------------
// WASM facade emitters for the supported wasm languages. These
// generate typed facades over the JS implementation's bridge
// (js/src/wasm_bridge.js); message types keep the templates'
// literal package prefixes.
// ---------------------------------------------------------------------------

function wasmGoClientMethod(m, svc) {
  return runSegments(SEGMENT_PROGRAMS.wasmGoClientMethod, m, svc);
}
function wasmGoSinkName(svc, out) {
  const outs = [...new Set(svc.methods.map((m) => m.output))];
  return outs.length === 1 ? svc.name + 'ServerSink' : svc.name + out + 'ServerSink';
}

function wasmGoServerIfaceMethod(m, svc) {
  return runSegments(SEGMENT_PROGRAMS.wasmGoServerIfaceMethod, m, svc.name, null, [wasmGoSinkName(svc, m.output)]);
}
function wasmGoRegisterMethod(m, svc) {
  return runSegments(SEGMENT_PROGRAMS.wasmGoRegisterMethod, m, svc.name, null, [wasmGoSinkName(svc, m.output)]);
}
function wasmGoStreamIfaceMethod(m, svc) {
  return runSegments(SEGMENT_PROGRAMS.wasmGoStreamIfaceMethod, m, svc.name, null, [wasmGoSinkName(svc, m.output)]);
}
function wasmGoStreamRegisterMethod(m, svc) {
  return runSegments(SEGMENT_PROGRAMS.wasmGoStreamRegisterMethod, m, svc.name, null, [wasmGoSinkName(svc, m.output)]);
}
function wasmGoService(svc) {
  return runSegments(SEGMENT_PROGRAMS.wasmGoService, svc, svc.name);
}
function emitWasmGoFile(model, params) {
  const base = baseName(model.name);
  const pkg = params.go_package || 'echowasm';
  const messagesImport = params.messages_import || 'grpcdc/examples';
  return {
    name: base + '_wasm_dc.go',
    content: '// @generated by protoc-gen-grpc-dc-wasm-go. DO NOT EDIT.\n'
      + '// source: ' + model.name + '\n\n'
      + '//go:build js && wasm\n\n'
      + 'package ' + pkg + '\n\n'
      + 'import (\n\t"syscall/js"\n\n\techo ' + q(messagesImport) + '\n)\n\n'
      + model.services.map(wasmGoService).join(''),
  };
}

JS
)

(define js-part-18 #<<JS
function wasmZigClientMethod(m, svc) {
  return runSegments(SEGMENT_PROGRAMS.wasmZigClientMethod, m, svc);
}
function wasmZigPendingStructs(m) {
  return runSegments(SEGMENT_PROGRAMS.wasmZigPendingStructs, m, '');
}
function wasmZigServeExport(m) {
  return runSegments(SEGMENT_PROGRAMS.wasmZigServerServeExport, m, '');
}
function wasmZigServerIfaceField(m) {
  return runSegments(SEGMENT_PROGRAMS.wasmZigServerIfaceField, m, '');
}
function wasmZigStreamIfaceField(m) {
  return runSegments(SEGMENT_PROGRAMS.wasmZigStreamIfaceField, m, '');
}
function wasmZigStreamFeedExport(m) {
  return runSegments(SEGMENT_PROGRAMS.wasmZigStreamFeedExport, m, '');
}
function wasmZigService(svc) {
  return runSegments(SEGMENT_PROGRAMS.wasmZigService, svc, svc.name);
}
function emitWasmZigFile(model, params) {
  const base = baseName(model.name);
  const messagesImport = params.messages_import || 'echo_messages';
  const statusImport = params.status_import || 'grpcdc_status';
  return {
    name: base + '_wasm_dc.zig',
    content: '// @generated by protoc-gen-grpc-dc-wasm-zig. DO NOT EDIT.\n'
      + '// source: ' + model.name + '\n\n'
      + 'const std = @import("std");\n'
      + 'const bridge_mod = @import("bridge.zig");\n'
      + 'const status_mod = @import(' + q(statusImport) + ');\n'
      + 'const messages = @import(' + q(messagesImport) + ');\n\n'
      + 'pub const Status = status_mod.Status;\n'
      + 'pub const CallResult = status_mod.CallResult;\n'
      + zigMessageNames(model).map((msg) => 'pub const ' + msg + ' = messages.' + msg + ';\n').join('')
      + '\n'
      + 'fn oomStatus() Status {\n    // gRPC INTERNAL (13): a request could not be marshaled.\n    return Status.init(13, "out of memory");\n}\n\n'
      + 'fn marshalAll(comptime T: type, reqs: []const T, alloc: std.mem.Allocator) [][]u8 {\n'
      + '    const out = alloc.alloc([]u8, reqs.len) catch return &.{};\n'
      + '    for (reqs, 0..) |*req, i| out[i] = req.marshalDc(alloc);\n'
      + '    return out;\n}\n\n'
      + 'fn freeAll(payloads: [][]u8, alloc: std.mem.Allocator) void {\n'
      + '    for (payloads) |p| alloc.free(p);\n'
      + '    if (payloads.len > 0) alloc.free(payloads);\n}\n\n'
      + model.services.map(wasmZigService).join(''),
  };
}

JS
)

(define js-part-19 #<<JS
function wasmCppServerExport(m, structName, svc) {
  return runSegments(SEGMENT_PROGRAMS.wasmCppServerExport, m, svc, null, [structName]);
}
function wasmCppServerIfaceMethod(m, svc) {
  return runSegments(SEGMENT_PROGRAMS.wasmCppServerIfaceMethod, m, svc);
}
function wasmCppStreamIfaceMethod(m, svc) {
  return runSegments(SEGMENT_PROGRAMS.wasmCppStreamIfaceMethod, m, svc);
}
function wasmCppStreamFeedExport(m, structName, svc) {
  return runSegments(SEGMENT_PROGRAMS.wasmCppStreamFeedExport, m, svc, null, [structName]);
}
function wasmCppService(svc, structName) {
  return runSegments(SEGMENT_PROGRAMS.wasmCppService, svc, svc.name, null, [structName]);
}
function emitWasmCppFile(model, params) {
  const base = baseName(model.name);
  const structName = pascalName(base) + 'WasmGrpcDc';
  const ns = model.package || 'proto';
  const messagesInclude = params.messages_include || base + '_messages.hpp';
  const bridgeInclude = params.bridge_include || 'bridge.hpp';
  return {
    name: base + '_wasm_dc.hpp',
    content: '// @generated by protoc-gen-grpc-dc-wasm-cpp. DO NOT EDIT.\n'
      + '// source: ' + model.name + '\n'
      + '#pragma once\n\n'
      + '#include <functional>\n#include <memory>\n#include <optional>\n#include <utility>\n#include <vector>\n\n'
      + '#include ' + q(bridgeInclude) + '\n'
      + '#include ' + q(messagesInclude) + '\n\n'
      + 'namespace ' + ns + ' {\n\n'
      + '/// Generated WASM facade stubs for ' + model.name + '.\n'
      + 'struct ' + structName + ' {\n'
      + model.services.map((svc) => wasmCppService(svc, structName)).join('')
      + '}  // namespace ' + ns + '\n',
  };
}

JS
)

(define js-part-20 #<<JS
function wasmSwiftClientMethod(m) {
  return runSegments(SEGMENT_PROGRAMS.wasmSwiftClientMethod, m, '');
}
function wasmSwiftServerIfaceMethod(m, svc) {
  return runSegments(SEGMENT_PROGRAMS.wasmSwiftServerIfaceMethod, m, svc);
}
function wasmSwiftServeExport(enumName, m, svc) {
  return runSegments(SEGMENT_PROGRAMS.wasmSwiftServeExport, m, svc, null, [enumName]);
}
function wasmSwiftStreamIfaceMethod(m, svc) {
  return runSegments(SEGMENT_PROGRAMS.wasmSwiftStreamIfaceMethod, m, svc);
}
function wasmSwiftStreamFeedExport(enumName, m, svc) {
  return runSegments(SEGMENT_PROGRAMS.wasmSwiftStreamFeedExport, m, svc, null, [enumName]);
}
function wasmSwiftService(svc) {
  return runSegments(SEGMENT_PROGRAMS.wasmSwiftService, svc, svc.name);
}
function emitWasmSwiftFile(model, params) {
  const base = baseName(model.name);
  const enumName = pascalName(base) + 'WasmGrpcDc';
  return {
    name: enumName + '.swift',
    content: '// @generated by protoc-gen-grpc-dc-wasm-swift. DO NOT EDIT.\n'
      + '// source: ' + model.name + '\n\n'
      + '/// Generated WASM facade stubs for ' + model.name + '.\n'
      + 'enum ' + enumName + ' {\n'
      + model.services.map(wasmSwiftService).join('')
      + '}\n\n'
      + model.services.map((svc) => svc.methods.map((m) => wasmSwiftServeExport(enumName, m, svc.name)).join('') + svc.methods.map((m) => wasmSwiftStreamFeedExport(enumName, m, svc.name)).join('')).join(''),
  };
}

JS
)

(define js-part-21 #<<JS
function wasmKotlinClientMethod(m) {
  return runSegments(SEGMENT_PROGRAMS.wasmKotlinClientMethod, m, '');
}
function wasmKotlinServerIfaceMethod(m) {
  return runSegments(SEGMENT_PROGRAMS.wasmKotlinServerIfaceMethod, m, '');
}
function wasmKotlinRegisterMethod(m) {
  return runSegments(SEGMENT_PROGRAMS.wasmKotlinRegisterMethod, m, '');
}
function wasmKotlinStreamIfaceMethod(m) {
  return runSegments(SEGMENT_PROGRAMS.wasmKotlinStreamIfaceMethod, m, '');
}
function wasmKotlinStreamRegisterMethod(m) {
  return runSegments(SEGMENT_PROGRAMS.wasmKotlinStreamRegisterMethod, m, '');
}
function wasmKotlinService(svc) {
  return runSegments(SEGMENT_PROGRAMS.wasmKotlinService, svc, svc.name);
}
function emitWasmKotlinFile(model, params) {
  const base = baseName(model.name);
  const objectName = pascalName(base) + 'WasmGrpcDc';
  const pkg = model.package || 'proto';
  const bridgePackage = params.bridge_package || 'grpcdcwasm';
  return {
    name: objectName + '.kt',
    content: '// @generated by protoc-gen-grpc-dc-wasm-kotlin. DO NOT EDIT.\n'
      + '// source: ' + model.name + '\n'
      + 'package ' + pkg + '\n\n'
      + 'import ' + bridgePackage + '.GrpcdcWasmBridge\n'
      + 'import ' + bridgePackage + '.GrpcdcWasmServerBridge\n'
      + 'import ' + bridgePackage + '.GrpcdcRequestSource\n'
      + 'import ' + bridgePackage + '.StatusException\n\n'
      + '/** Generated WASM facade stubs for ' + model.name + '. */\n'
      + 'object ' + objectName + ' {\n'
      + model.services.map(wasmKotlinService).join('')
      + '}\n',
  };
}

JS
)

(define js-part-22 #<<JS
function wasmScalaKindOutputs(svc, kind) {
  return [...new Set(svc.methods.filter((m) => m.kind === kind).map((m) => m.output))];
}

function wasmScalaStreamOutputs(svc) {
  return [...new Set(svc.methods.filter((m) => m.kind === 'server-streaming' || m.kind === 'bidi').map((m) => m.output))];
}

function wasmScalaRecvName(svc, out) {
  return wasmScalaStreamOutputs(svc).length <= 1 ? svc.name + 'RecvStream' : svc.name + out + 'RecvStream';
}

function wasmScalaSinkName(svc, out) {
  return wasmScalaStreamOutputs(svc).length <= 1 ? svc.name + 'ServerSink' : svc.name + out + 'ServerSink';
}

function wasmScalaClientStreamName(svc, kind, out) {
  const suffix = kind === 'server-streaming' ? 'ServerStreamStream' : 'BidiStream';
  return wasmScalaKindOutputs(svc, kind).length <= 1 ? svc.name + suffix : svc.name + out + suffix;
}

function wasmScalaClientMethod(m, svc) {
  return runSegments(SEGMENT_PROGRAMS.wasmScalaClientMethod, m, '', null, [wasmScalaClientStreamName(svc, 'server-streaming', m.output), wasmScalaClientStreamName(svc, 'bidi', m.output)]);
}
function wasmScalaServerIfaceMethod(m, svc) {
  return runSegments(SEGMENT_PROGRAMS.wasmScalaServerIfaceMethod, m, '', null, [wasmScalaSinkName(svc, m.output)]);
}
function wasmScalaRegisterMethod(m) {
  return runSegments(SEGMENT_PROGRAMS.wasmScalaRegisterMethod, m, '');
}
function wasmScalaStreamIfaceMethod(m) {
  return runSegments(SEGMENT_PROGRAMS.wasmScalaStreamIfaceMethod, m, '');
}
function wasmScalaStreamRegisterMethod(m) {
  return runSegments(SEGMENT_PROGRAMS.wasmScalaStreamRegisterMethod, m, '');
}
function wasmScalaRecvStream(svc, out) {
  return runSegments(SEGMENT_PROGRAMS.wasmScalaRecvStream, svc, svc.name, null, [out, wasmScalaRecvName(svc, out)]);
}
function wasmScalaSource(typ) {
  return runSegments(SEGMENT_PROGRAMS.wasmScalaSource, {}, '', null, [typ]);
}
function wasmScalaService(svc) {
  return runSegments(SEGMENT_PROGRAMS.wasmScalaService, svc, svc.name);
}
function emitWasmScalaFile(model, params) {
  const base = baseName(model.name);
  const objName = camelName(base) + 'ScalaJsGrpcDc';
  return {
    name: objName + '.scala',
    content: '// @generated by protoc-gen-grpc-dc-wasm-scala. DO NOT EDIT.\n'
      + '// source: ' + model.name + '\n'
      + 'package ' + model.package + '\n\n'
      + 'import scala.concurrent.ExecutionContext.Implicits.global\n\n'
      + '/** Generated Scala.js facade stubs (wrap the JS runtime). */\n'
      + 'object ' + objName + ' {\n'
      + model.services.map(wasmScalaService).join('')
      + '}\n',
  };
}

JS
)

(define (emit-web-generators)
  (cons "generators.js"
        (string-append js-part-1 (alias-table-json) js-part-2
                       "const FIXED_TABLES = " (fixed-tables-json) ";\n"
                       "const VARINT_TYPES = " (varint-types-json) ";\n"
                       "const SCALAR_TABLES = " (scalar-tables-json) ";\n"
                       "const SEGMENT_PROGRAMS = " (segment-programs-json) ";\n\n"
                       "function runSegments(program, node, svc, model, args, errStmt) {\n"
                       "  const env = { model: model ?? null, node, svc, args: args ?? [], err: errStmt ?? 'return err', root: node, index: 0, parent: node };\n  return runEnv(program, env);\n}\n\n"
                       "function runEnv(program, env) {\n  let out = '';\n  for (const seg of program) out += runSegment(seg, env);\n  return out;\n}\n\n"
                       "function envWith(env, over) { const next = Object.assign({}, env, over); if (next.node !== env.node && over.parent === undefined) next.parent = env.node; return next; }\n\n"
                       "function segTruthy(v) { return !(v === false || v === null || v === undefined || v === '' || v === 0); }\n\n"
                       "function segKey(k) {\n  return k.replace(/-([a-z])/g, (_, c) => c.toUpperCase());\n}\n\n"
                       "function segCategory(model, node) {\n  const t = node.type;\n  if (t === 11 && gpResolve(model, node.typeName).kind === 'map') return 'map';\n  if (t === 11) return 'message';\n  if (VARINT_TYPES.includes(t)) return 'varint';\n  if (FIXED_TABLES.go[t]) return 'fixed';\n  if (t === 9) return 'string';\n  if (t === 12) return 'bytes';\n  return 'other';\n}\n\n"
                       "function segEval(seg, env) {\n  const node = env.node; const model = env.model;\n  if (typeof seg === 'string') return seg;\n  if (typeof seg === 'number') return seg;\n  switch (seg[0]) {\n    case 'fmt': {\n      let i = 1;\n      const tmpl = Array.isArray(seg[1]) ? segEval(seg[1], env) : seg[1];\n      return tmpl.replace(/~~|~[as]/g, (tok) => {\n        if (tok === '~~') return '~';\n        const v = segEval(seg[++i], env);\n        return tok === '~s' ? JSON.stringify(String(v)) : String(v);\n      });\n    }\n    case 'ref': {\n      if (seg.length === 2) return seg[1] === 'impl-name' ? (node.implName ?? node.name) : node[segKey(seg[1])];\n      let acc = node;\n      for (let i = 1; i < seg.length; i++) acc = acc[segKey(seg[i])];\n      return acc;\n    }\n    case 'svc': return env.svc;\n    case 'arg': return env.args[seg[1]];\n    case 'err-stmt': return env.err;\n    case 'self': return node;\n    case 'root': return env.root;\n    case 'distinct-count': { const kindsPart = Array.isArray(seg[3]) && seg[3][0] === 'kinds' ? seg[3].slice(1) : null; const els = segEval(seg[1], env).filter((el) => !kindsPart || kindsPart.includes(el.kind)); return new Set(els.map((el) => el[segKey(seg[2])])).size; }\n    case 'if': case 'case-on': case 'when': case 'guarded': case 'trim-suffix': case 'kind-case': case 'each': case 'each+': case 'each-siblings': case 'each-sep': case 'each-unique': case 'each-unique-pair': case 'each-where': case 'each-sep-where': case 'guarded-indent':\n      return runSegment(seg, env);\n    case 'pascal': return gpPascal(segEval(seg[1], env));\n    case 'lower-first': return lowerFirst(segEval(seg[1], env));\n    case 'js-name': return pbJsName(node);\n    case 'js-fixed-size': return FIXED_TABLES.js[node.type][0];\n    case 'js-fixed-name': return FIXED_TABLES.js[node.type][1];\n    case 'bigint-type': return PB_BIGINT.has(node.type);\n    case 'entry-flat': return node.kind === 'enum' ? pbFlatName(node.pkg, node.full) : pbFlatName(node.pkg, node.msg.fullName);\n    case 'resolved-flat': { const e = pbResolve(model, node.typeName); return pbFlatName(e.pkg, e.msg.fullName); }\n    case 'index': return env.index;\n    case 'parent': return env.parent;\n    case 'and': return seg.slice(1).every((e) => segTruthy(segEval(e, env)));\n    case 'or': return seg.slice(1).some((e) => segTruthy(segEval(e, env)));\n    case 'not': return !segTruthy(segEval(seg[1], env));\n    case 'any-where': { const keys = Array.isArray(seg[1]) ? seg[1] : [seg[1]]; let items = node; for (const k of keys) items = items[segKey(k)]; return items.some((el) => segTruthy(segEval(seg[2], envWith(env, { node: el })))); }\n    case 'snake-case': return snakeCase(segEval(seg[1], env));\n    case 'rs-camel': return rpCamel(segEval(seg[1], env));\n    case 'rs-field-name': return rpFieldName(node);\n    case 'rs-map-type': return rpMapType();\n    case 'rs-entry-ref': { const e = node.typeName !== undefined ? rpResolve(model, node.typeName) : node; return rpEntryRef(model, e); }\n    case 'rs-scalar-type': return SCALAR_TABLES.rust.types[node.type] ?? SCALAR_TABLES.rust.default;\n    case 'rs-fixed-size': return FIXED_TABLES.rust[node.type][0];\n    case 'rs-fixed-name': return FIXED_TABLES.rust[node.type][1];\n    case 'flat-of': return rpFlat(model.package, segEval(seg[1], env));\n    case 'rust-enum-fragment': return RP_ENUM_SHAPE[seg[1]];\n    case 'enum-first-value-name': return rpResolve(model, node.typeName).enum.values[0].name;\n    case 'enum-first-value-num': return rpResolve(model, node.typeName).enum.values[0].number;\n    case 'rb-snake': return String(segEval(seg[1], env)).replace(/[A-Z]/g, (c, i) => (i > 0 ? '_' : '') + c.toLowerCase());\n    case 'stub-ref': return rbStubRef(model, node[segKey(seg[1])]);\n    case 'rb-entry-ref': { const n = seg.length > 1 ? segEval(seg[1], env) : node; const e = n.typeName !== undefined ? rbpResolve(model, n.typeName) : n; return rbpEntryRef(model, e); }\n    case 'rb-model-module': return rbpModuleName({ file: model.name });\n    case 'rb-fixed-size': return FIXED_TABLES.ruby[node.type][0];\n    case 'rb-fixed-fmt': return FIXED_TABLES.ruby[node.type][1];\n    case 'php-camel': return phpbCamel(segEval(seg[1], env));\n    case 'php-field-name': return phpbFieldName(node);\n    case 'php-flat-of': return phpbFlat(model.package, segEval(seg[1], env));\n    case 'php-stub-ref': return phpStubRef(model, node[segKey(seg[1])]);\n    case 'php-entry-ref': { const n = seg.length > 1 ? segEval(seg[1], env) : node; const e = n.typeName !== undefined ? phpbResolve(model, n.typeName) : n; return phpbEntryRef(model, e); }\n    case 'php-fixed-size': return FIXED_TABLES.php[node.type][0];\n    case 'php-fixed-fmt': return FIXED_TABLES.php[node.type][1];\n    case 'py-ref': { const e = node.typeName !== undefined ? pyPbResolve(model, node.typeName) : node; return pyPbRef(model, e); }\n    case 'py-fixed-size': return FIXED_TABLES.python[node.type][0];\n    case 'py-fixed-fmt': return FIXED_TABLES.python[node.type][1];\n    case 'with-type': return Object.assign({}, segEval(seg[1], env), { type: seg[2] });\n    case 'trim-end': return String(segEval(seg[1], env)).replace(/\\n+$/, '');\n    case 'c-entry-ref': { const n = seg.length > 1 ? segEval(seg[1], env) : node; const e = n.typeName !== undefined ? cbResolve(model, n.typeName) : n; return cbEntryRef(model, e); }\n    case 'c-entry-support': { const n = seg.length > 1 ? segEval(seg[1], env) : node; const e = n.typeName !== undefined ? cbResolve(model, n.typeName) : n; return cbEntrySupport(e); }\n    case 'c-type-ref': return cbTypeRef(model, node[segKey(seg[1])]);\n    case 'c-support-of': return cbEntrySupport(cbResolve(model, node[segKey(seg[1])]));\n    case 'c-scalar-type': return SCALAR_TABLES.c.types[node.type][0];\n    case 'c-scalar-zero': return SCALAR_TABLES.c.types[node.type][1];\n    case 'c-fixed-size': return FIXED_TABLES.c[node.type][0];\n    case 'c-fixed-name': return FIXED_TABLES.c[node.type][1];\n    case 'distinct-pair-count': { const kindsPart = Array.isArray(seg[2]) && seg[2][0] === 'kinds' ? seg[2].slice(1) : null; const els = segEval(seg[1], env).filter((el) => !kindsPart || kindsPart.includes(el.kind)); return new Set(els.map((el) => el.input + '\u0000' + el.output)).size; }\n    case 'sc-field-name': return scpFieldName(node);\n    case 'sc-entry-ref': { const n = seg.length > 1 ? segEval(seg[1], env) : node; const e = n.typeName !== undefined ? scpResolve(model, n.typeName) : n; return scpEntryRef(model, e); }\n    case 'sc-scalar-type': return SCALAR_TABLES.scala.types[node.type] ?? SCALAR_TABLES.scala.default;\n    case 'sc-fixed-size': return FIXED_TABLES.scala[node.type][0];\n    case 'sc-fixed-kind': return FIXED_TABLES.scala[node.type][1];\n    case 'dart-field-name': return dtpFieldName(node);\n    case 'dart-entry-ref': { const n = seg.length > 1 ? segEval(seg[1], env) : node; const e = n.typeName !== undefined ? dtpResolve(model, n.typeName) : n; return dtpEntryRef(model, e); }\n    case 'dart-type-ref': { const n = seg.length > 1 ? segEval(seg[1], env) : node; const e = n.typeName !== undefined ? dtpResolve(model, n.typeName) : n; return dtpTypeRef(model, e); }\n    case 'dart-scalar-type': return SCALAR_TABLES.dart.types[node.type][0];\n    case 'dart-scalar-zero': return SCALAR_TABLES.dart.types[node.type][1];\n    case 'dart-fixed-size': return FIXED_TABLES.dart[node.type][0];\n    case 'dart-fixed-name': return FIXED_TABLES.dart[node.type][1];\n    case 'swift-field-name': return swpFieldName(node);\n    case 'swift-entry-ref': { const n = seg.length > 1 ? segEval(seg[1], env) : node; const e = n.typeName !== undefined ? swpResolve(model, n.typeName) : n; return swpEntryRef(model, e); }\n    case 'swift-map-name': { const n = seg.length > 1 ? segEval(seg[1], env) : node; const e = n.typeName !== undefined ? swpResolve(model, n.typeName) : n; return swpMapHelperName(model, e); }\n    case 'swift-scalar-type': return SCALAR_TABLES.swift.types[node.type][0];\n    case 'swift-scalar-zero': return SCALAR_TABLES.swift.types[node.type][1];\n    case 'swift-fixed-size': return FIXED_TABLES.swift[node.type][0];\n    case 'swift-fixed-name': return FIXED_TABLES.swift[node.type][1];\n    case 'lua-field-name': return lpFieldName(node);\n    case 'cs-field-name': return cspFieldName(model, node);\n    case 'cs-entry-ref': { const n = seg.length > 1 ? segEval(seg[1], env) : node; const e = n.typeName !== undefined ? cspResolve(model, n.typeName) : n; return cspEntryRef(model, e); }\n    case 'cs-map-name': { const n = seg.length > 1 ? segEval(seg[1], env) : node; const e = n.typeName !== undefined ? cspResolve(model, n.typeName) : n; return cspMapHelperName(model, e); }\n    case 'cs-scalar-type': return SCALAR_TABLES.csharp.types[node.type][0];\n    case 'cs-scalar-zero': return SCALAR_TABLES.csharp.types[node.type][1];\n    case 'cs-fixed-size': return FIXED_TABLES.csharp[node.type][0];\n    case 'cs-fixed-name': return FIXED_TABLES.csharp[node.type][1];\n    case 'kotlin-wasm-mode': return kotlinWasmMode;\n    case 'first-value-name': return node.values[0].name;\n    case 'kt-field-name': return kpFieldName(node);\n    case 'kt-entry-ref': { const n = seg.length > 1 ? segEval(seg[1], env) : node; const e = n.typeName !== undefined ? kpResolve(model, n.typeName) : n; return kpEntryRef(model, e); }\n    case 'kt-map-name': { const n = seg.length > 1 ? segEval(seg[1], env) : node; const e = n.typeName !== undefined ? kpResolve(model, n.typeName) : n; return kpMapHelperName(model, e); }\n    case 'kt-scalar-type': return SCALAR_TABLES.kotlin.types[node.type][0];\n    case 'kt-scalar-zero': return SCALAR_TABLES.kotlin.types[node.type][1];\n    case 'kt-fixed-size': return FIXED_TABLES.kotlin[node.type][0];\n    case 'kt-fixed-name': return FIXED_TABLES.kotlin[node.type][1];\n    case 'zig-entry-ref': { const n = seg.length > 1 ? segEval(seg[1], env) : node; const e = n.typeName !== undefined ? zgpResolve(model, n.typeName) : n; return zgpEntryRef(model, e); }\n    case 'zig-struct-name': { const n = seg.length > 1 ? segEval(seg[1], env) : node; const e = n.typeName !== undefined ? zgpResolve(model, n.typeName) : n; return zgpEntryRef(model, e).replace(/\\./g, '_'); }\n    case 'zig-scalar-type': return SCALAR_TABLES.zig.types[node.type][0];\n    case 'zig-scalar-zero': return SCALAR_TABLES.zig.types[node.type][1];\n    case 'zig-fixed-size': return FIXED_TABLES.zig[node.type][0];\n    case 'zig-fixed-name': return FIXED_TABLES.zig[node.type][1];\n    case 'lua-entry-flat': { const n = seg.length > 1 ? segEval(seg[1], env) : node; const e = n.typeName !== undefined ? lpResolve(model, n.typeName) : n; return lpEntryFlat(model, e); }\n    case 'lua-enum-flat': return lpFlat(model.package, model.package === '' ? node.name : model.package + '.' + node.name);\n    case 'lua-fixed-fmt': return '<' + FIXED_TABLES.lua[node.type][1];\n    case 'lua-fixed-size': return FIXED_TABLES.lua[node.type][0];\n    case 'lua-fixed-wire': return FIXED_TABLES.lua[node.type][0] === 8 ? 1 : 5;\n    case 'flat': return gpFlat(model.package, node.fullName);\n    case 'entry-type': return node.typeName !== undefined ? gpEntryType(gpResolve(model, node.typeName)) : gpEntryType(node);\n    case 'field-type': return gpFieldType(model, node);\n    case 'field-type-of': return gpFieldType(model, segEval(seg[1], env));\n    case 'resolved-entry': return gpResolve(model, node.typeName);\n    case 'key-field': { const e = seg.length > 1 ? segEval(seg[1], env) : node; return e.msg.fields.find((x) => x.number === 1); }\n    case 'val-field': { const e = seg.length > 1 ? segEval(seg[1], env) : node; return e.msg.fields.find((x) => x.number === 2); }\n    case 'with-label': return Object.assign({}, segEval(seg[1], env), { label: seg[2] });\n    case 'get': return segEval(seg[1], env)[segKey(seg[2])];\n    case 'fixed-name': return FIXED_TABLES.go[node.type][1];\n    case 'fixed-size': return FIXED_TABLES.go[node.type][0];\n    case 'fixed-wire': return FIXED_TABLES.go[node.type][0] === 8 ? 1 : 5;\n    case 'type': return node.type;\n    case 'category': return segCategory(model, node);\n    case 'category-of': return segCategory(model, segEval(seg[1], env));\n    case 'proto2': return model.syntax === 'proto2';\n    case 'type-is': return node.type === seg[1];\n    case 'is-varint': return VARINT_TYPES.includes(node.type);\n    case 'is-fixed': return FIXED_TABLES.go[node.type] !== undefined;\n    case 'is-map': return node.type === 11 && gpResolve(model, node.typeName).kind === 'map';\n    case 'repeated': return node.label === 3;\n    case 'has-default': return fieldExplicitDefault(node) != null;\n    case 'any-default': return node.fields.some((f) => fieldExplicitDefault(f) != null);\n    case 'no-fields': return node.fields.length === 0;\n    case 'default-raw': return fieldExplicitDefault(node);\n    case 'enum-default-num': return enumDefaultNumber(model, node);\n    case 'oneof-clearing': return gpOneofClearing(model, node);\n    case 'later-oneof-cond': return oneofLaterSiblings(model, node).map(gpSetExpr).join(' || ');\n    case 'call': return runEnv(SEGMENT_PROGRAMS[seg[1]], envWith(env, { args: seg.slice(2).map((e) => segEval(e, env)) }));\n    case 'call-on': return runEnv(SEGMENT_PROGRAMS[seg[2]], envWith(env, { node: segEval(seg[1], env), args: seg.slice(3).map((e) => segEval(e, env)) }));\n    default: throw new Error('bad expression: ' + JSON.stringify(seg));\n  }\n}\n\n"
                       "function runSegment(seg, env) {\n  const node = env.node;\n  if (typeof seg === 'string') return seg;\n  switch (seg[0]) {\n    case 'if': {\n      const thenPart = seg.slice(2).find((g) => g[0] === 'then');\n      const elsePart = seg.slice(2).find((g) => g[0] === 'else');\n      if (segTruthy(segEval(seg[1], env))) return runEnv(thenPart.slice(1), env);\n      return elsePart ? runEnv(elsePart.slice(1), env) : '';\n    }\n    case 'kind-case': {\n      const branch = seg.slice(1).find((b) => b[0] === node.kind || (Array.isArray(b[0]) && b[0].includes(node.kind))) || seg.slice(1).find((b) => b[0] === 'else');\n      if (!branch) throw new Error('no kind branch for ' + node.kind);\n      return runEnv(branch.slice(1), env);\n    }\n    case 'case-on': {\n      const val = segEval(seg[1], env);\n      const raw = seg.slice(2);\n      const isKey = (b) => Array.isArray(b) && (Array.isArray(b[0]) || typeof b[0] === 'number' || typeof b[0] === 'string');\n      let branches;\n      if (raw.length === 1 && Array.isArray(raw[0]) && raw[0].every(isKey)) branches = raw[0];\n      else branches = raw.map((b) => (Array.isArray(b) && b.length === 1 && Array.isArray(b[0])) ? b[0] : b);\n      const keysOf = (b) => (Array.isArray(b[0]) ? b[0] : [b[0]]);\n      const branch = branches.find((b) => keysOf(b).includes('else') || keysOf(b).map(String).includes(String(val)));\n      return branch ? runEnv(branch.slice(1), env) : '';\n    }\n    case 'when':\n      return segTruthy(segEval(seg[1], env)) ? runEnv(seg.slice(2), env) : '';\n    case 'trim-suffix': {\n      const text = runEnv(seg.slice(3), env);\n      return text.endsWith(seg[1]) ? text.slice(0, text.length - seg[1].length) + seg[2] : text;\n    }\n    case 'guarded': {\n      const hasJoin = Array.isArray(seg[4]) && seg[4][0] === 'join';\n      const joiner = hasJoin ? seg[4][1] : ' || ';\n      const text = runEnv(seg.slice(hasJoin ? 5 : 4), env);\n      const cond = oneofLaterSiblings(env.model, node).map((sib) => runEnv(SEGMENT_PROGRAMS[seg[1]], envWith(env, { node: sib }))).join(joiner);\n      if (!cond) return text;\n      return seg[2].split('~a').join(cond) + (text.endsWith('\\n') ? text : text + '\\n') + seg[3];\n    }\n    case 'fail':\n      throw new Error('unsupported field type ' + node.type);\n    case 'each': {\n      let i = 1; const keys = [];\n      while (typeof seg[i] === 'string') { keys.push(seg[i]); i++; }\n      let items = node;\n      for (const k of keys) items = items[segKey(k)];\n      let out = '';\n      items.forEach((el, ix) => { out += runEnv(seg.slice(i), envWith(env, { node: el, index: ix })); });\n      return out;\n    }\n    case 'each+': {\n      const all = node.methods.concat(seg[2] === 'client' ? aliasClientMethods(node) : aliasServerMethods(node));\n      let out = '';\n      all.forEach((el, ix) => { out += runEnv(seg.slice(3), envWith(env, { node: el, index: ix })); });\n      return out;\n    }\n    case 'guarded-indent': {
      const text = runEnv(seg.slice(4), env);
      const cond = oneofLaterSiblings(env.model, node).map((sib) => runEnv(SEGMENT_PROGRAMS[seg[1]], envWith(env, { node: sib }))).join(' or ');
      if (!cond) return text;
      return seg[2].split('~a').join(cond) + text.split('\\n').map((l) => (l === '' ? l : seg[3] + l)).join('\\n') + '\\n';
    }
    case 'each-unique-pair': {
      let idx = 2; let kindsPart = null; let orFirst = false;
      if (Array.isArray(seg[idx]) && seg[idx][0] === 'kinds') { kindsPart = seg[idx].slice(1); idx++; }
      if (Array.isArray(seg[idx]) && seg[idx][0] === 'or-first') { orFirst = true; idx++; }
      const body = seg.slice(idx);
      const seen = new Set(); const uniq = [];
      for (const el of node[segKey(seg[1])]) { if (kindsPart && !kindsPart.includes(el.kind)) continue; const v = el.input + '\u0000' + el.output; if (seen.has(v)) continue; seen.add(v); uniq.push(el); }
      const items = orFirst && uniq.length === 0 ? [node[segKey(seg[1])][0]] : uniq;
      let out = '';
      items.forEach((el, ix) => { out += runEnv(body, envWith(env, { node: { input: el.input, output: el.output }, index: ix })); });
      return out;
    }
    case 'each-where': {
      let i = 1; const keys = [];
      while (typeof seg[i] === 'string') { keys.push(seg[i]); i++; }
      const pred = seg[i]; const body = seg.slice(i + 1);
      let items = node;
      for (const k of keys) items = items[segKey(k)];
      let out = '';
      items.forEach((el, ix) => { if (segTruthy(segEval(pred, envWith(env, { node: el })))) out += runEnv(body, envWith(env, { node: el, index: ix })); });
      return out;
    }
    case 'each-sep-where': {
      let i = 2; const keys = [];
      while (typeof seg[i] === 'string') { keys.push(seg[i]); i++; }
      const pred = seg[i]; const body = seg.slice(i + 1);
      let items = node;
      for (const k of keys) items = items[segKey(k)];
      const parts = [];
      items.forEach((el, ix) => { if (segTruthy(segEval(pred, envWith(env, { node: el })))) parts.push(runEnv(body, envWith(env, { node: el, index: ix }))); });
      return parts.join(seg[1]);
    }
    case 'each-siblings': {\n      let out = '';\n      oneofSiblings(env.model, node).forEach((sib, ix) => { out += runEnv(seg.slice(1), envWith(env, { node: sib, index: ix })); });\n      return out;\n    }\n    case 'each-sep': {\n      let i = 2; const keys = [];\n      while (typeof seg[i] === 'string') { keys.push(seg[i]); i++; }\n      let items = node;\n      for (const k of keys) items = items[segKey(k)];\n      return items.map((el, ix) => runEnv(seg.slice(i), envWith(env, { node: el, index: ix }))).join(seg[1]);\n    }\n    case 'each-unique': {\n      let idx = 3; let kindsPart = null; let orFirst = false;\n      if (Array.isArray(seg[idx]) && seg[idx][0] === 'kinds') { kindsPart = seg[idx].slice(1); idx++; }\n      if (Array.isArray(seg[idx]) && seg[idx][0] === 'or-first') { orFirst = true; idx++; }\n      const body = seg.slice(idx);\n      const seen = new Set(); const uniq = [];\n      for (const el of node[segKey(seg[1])]) { if (kindsPart && !kindsPart.includes(el.kind)) continue; const v = el[segKey(seg[2])]; if (seen.has(v)) continue; seen.add(v); uniq.push(el); }\n      const items = orFirst && uniq.length === 0 ? [node[segKey(seg[1])][0]] : uniq;\n      let out = '';\n      items.forEach((el, ix) => { out += runEnv(body, envWith(env, { node: el, index: ix })); });\n      return out;\n    }\n    default:\n      return segEval(seg, env);\n  }\n}\n\n"
                       js-part-3 js-part-4
                       "const RP_ENUM_SHAPE = " (rust-enum-shape-json) ";\n"
                       "const GO_MODULE_PATH = " (go-module-path-json) ";\n\n"
                       "function rpFmt(template, ...args) {\n  let i = 0;\n  return template.replace(/~a/g, () => String(args[i++]));\n}\n\n"
                       js-part-5 js-part-6 js-part-7 js-part-8 js-part-9 js-part-10 js-part-11 js-part-12 js-part-13 js-part-14 js-part-15 js-part-16 js-part-17 js-part-18 js-part-19 js-part-20 js-part-21 js-part-22)))


