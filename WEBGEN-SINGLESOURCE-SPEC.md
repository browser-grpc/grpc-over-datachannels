# Spec: single-sourcing the browser (webgen) emitters

Status: first step implemented. The Rust enum emission shape
now lives once as the `rust-enum-shape` table in
`racket/spec.rkt`, consumed by `template-rust.rkt` directly
and serialized by `webgen.rkt` into the browser generators as
`RP_ENUM_SHAPE` (the same mechanism as `METHOD_ALIASES`).
`browser-test/webapp_parity.test.mjs` gained an enum-corpus
case (kitchen + features protos through the built-in
generators, message files byte-compared for every language),
which is the case that would have caught the Rust enum drift.
Scalar/wire tables (option 2) implemented: `varint-scalar-types`
and `fixed-scalar-tables` now live once in `racket/spec.rkt`.
All sixteen templates derive their `<lang>-pb-varint-types` /
`<lang>-pb-fixed` from them (Rust/Scala re-symbolize the type
name for case dispatch; Python derives its formats/sizes
alists), and webgen.rkt serializes both tables into the
browser generators (`VARINT_TYPES`, `FIXED_TABLES`), replacing
31 hand-mirrored JS constants. Native output is byte-identical
(check-generated); parity is green in Chromium/Firefox/WebKit.
Parity growth (option 3) also continued: the corpus case runs
legacy.proto (proto2 required/optional presence, explicit
defaults including enum and double, extensions) through the
built-in generators with per-language byte comparison.
Scalar type maps (option 2) also implemented: `scalar-type-tables`
in `racket/spec.rkt` holds each typed language's scalar leaf
(default plus type-number -> payload, tuples included); the
eleven typed templates derive `<lang>-pb-scalar` from it and
webgen serializes it as `SCALAR_TABLES`. Dynamic languages
(JS, Python, Lua, Ruby, PHP) have no scalar type names and
are not listed. Native output byte-identical; parity green
in all three engines. Remaining: the composite type/layout
emission (repeated/map/optional wrapping, struct layout) —
that logic is the descriptor walk plus per-language code
shape, not data; single-sourcing it is option 1. Do not
start casually (see Risks).

## Problem

`racket/webgen.rkt` re-implements the language emitters in
JavaScript so stubs can be generated in the browser (the
webapp's paste-a-proto playground). It mirrors
`racket/template-{js,go,python,rust,...}.rkt` by hand. Every
template fix must be made twice — this session's Rust
unknown-enum fix (`Unknown(i32)`, `#[repr(i32)]`, `to_i32()`)
landed in both `template-rust.rkt` and `webgen.rkt`.

## Current safety net

Byte-parity tests: the webapp generates stubs in Chromium /
Firefox / WebKit and diffs them against the native plugins
(`browser-test/webapp_parity.test.mjs`, plugin-parity suites).
Drift is caught, but only after the fact, and only for the
shapes the parity corpus covers.

## Options

1. **Derive webgen from the templates.** Teach the Racket
   templates to emit a JS twin (each template function gains a
   JS rendering of itself). Principled end state: one source.
   Cost: high — the templates are ~29k lines across languages,
   use Racket macros and string surgery that have no direct JS
   twin, and the browser runtime cannot load Racket.
2. **Generate webgen's JS from a shared data model.** Move the
   parts that are data (wire tables, enum/type mappings,
   scalar encodings) into `racket/spec.rkt`-style tables both
   sides consume; keep code shape per emitter hand-written.
   Cost: medium; removes the most drift-prone duplication
   (this session's enum bug was data-shaped).
3. **Expand parity coverage instead.** Grow the parity corpus
   (more protos: enums with unknown values, oneofs, maps,
   streaming shapes) so hand-mirroring fails fast in CI.
   Cost: low; keeps two sources forever.

## Recommendation

Option 2 for the data-shaped surfaces first (enum handling,
scalar/wire tables, message layout), option 3 in parallel for
everything else. Option 1 only if the webapp becomes a
primary distribution channel.

## First concrete step

Inventory the data-shaped duplications: grep `webgen.rkt`
for tables that also exist in `template-*.rkt` / `spec.rkt`
(enum mappings, wire-type tables, scalar defaults), move one
(table stakes: enum generation, the site of the last double
fix) behind a shared spec table consumed by both emitters,
and add a parity case that would have caught the Rust enum
drift (unknown enum value round-trip through the browser
generator).

## Risks

- The webapp must stay dependency-free and synchronous in a
  browser tab; any shared model must serialize to plain JS
  data at generation time (no Racket runtime in the page).
- Parity is byte-level: refactors that change whitespace in
  either emitter fail the whole matrix until both sides move.
