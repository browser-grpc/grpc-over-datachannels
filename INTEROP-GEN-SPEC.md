# Spec: generating the interop TestService implementations

Status: draft for review. No code changes yet. Decision needed
before implementation (see Open questions).

## Problem

The grpc interop `TestService` behavior is hand-implemented nine
times, once per language that runs a server in the interop matrix:

| File | Lines |
|---|---|
| [js/test/interop_service.js](js/test/interop_service.js) | 191 |
| [python/tests/interop_service.py](python/tests/interop_service.py) | 205 |
| [c/examples/interop/interop_service_impl.h](c/examples/interop/interop_service_impl.h) | 425 |
| [cpp/examples/interop_service_impl.hpp](cpp/examples/interop_service_impl.hpp) | 240 |
| [dart/examples/interop_service_impl.dart](dart/examples/interop_service_impl.dart) | 198 |
| [zig/examples/interop_service_impl.zig](zig/examples/interop_service_impl.zig) | 287 |
| [lua/examples/interop_service_impl.lua](lua/examples/interop_service_impl.lua) | 211 |
| [ruby/examples/interop_service_impl.rb](ruby/examples/interop_service_impl.rb) | 162 |
| [php/examples/interop_service_impl.php](php/examples/interop_service_impl.php) | 196 |

~2,100 lines re-implementing the same contract: empty/unary echo
with payload sizing, status echo (code + message), streaming
shapes (server/client/bidi with per-message sizes), metadata echo,
and ORCA per-query / out-of-band metrics. Every behavior change
(e.g. the C one-shot ORCA close) must be mirrored by hand in up to
nine places, and drift is only caught late by the matrix.

Everywhere else in this repo the same shape of problem is already
solved by a spec in `racket/` plus per-language emitters. This is
the largest remaining hand-mirrored surface.

## Proposed design

### Source of truth

A new `racket/interop-spec.rkt`, sibling to `eventbus-spec.rkt`,
declaring behavior as data, not per-language code:

- The method table: name, cardinality, request/response fields the
  behavior reads (`response_size`, `response_status`, payload
  type), in proto order.
- Behavior rules per method, expressed once:
  - `EmptyCall` → empty response.
  - `UnaryCall` → payload of `response_size` zero bytes; honor
    `response_status`; ORCA per-query report when requested.
  - `CacheableUnaryCall` → same as unary (see hook H1).
  - Streaming methods → one response per requested
    `response_parameters` entry, sizes in request order; bidi
    echoes one response per request message.
  - `UnimplementedCall` → deliberately absent from the service
    descriptor so the runtime returns UNIMPLEMENTED.
  - ORCA out-of-band: test name → report, served until close
    (see hook H3).
- Constants: maximum payload, ORCA field defaults.

### Generator

`racket/interop-gen.rkt`, driven from `metagen.rkt` like the
event-bus generator: one emitter per server-capable language
stamping the behavior onto that language's already-generated
`TestService` stubs and runtime idioms (async model, error type,
stream writer). Output keeps the current file paths, so the
interop matrix, Makefile targets, and corpus export do not move.

Generated output must be byte-stable: `make generate` followed by
`make check-generated` is the gate, as for all other generated
modules.

### Per-language hooks (the part that must not be generated away)

The nine files are not pure duplication; several encode
language-specific workarounds that are themselves coverage:

- H1 Ruby: `CacheableUnaryCall` payload echo quirk (the matrix's
  Ruby leg depends on the current response shape).
- H2 PHP: Fiber scheduling — long-lived streaming handlers must
  yield through the runtime pump, not block.
- H3 C: ORCA out-of-band is one-shot (metrics close per report);
  this fixed a matrix flake and must stay expressible.
- H4 Lua: coroutine pump for streaming handlers.
- H5 Zig/C: manual memory ownership for payload buffers; the
  generator emits through the runtime's allocator helpers, it
  does not invent ownership.

Design rule: the spec declares hooks as named slots with a
declared default behavior. A language emitter either uses the
default or supplies the slot. Hooks are listed in the generated
file header so a reader sees exactly where a language deviates.
If a behavior cannot be expressed as spec rule + hook slot, it
does not get generated — it stays hand-written and the file drops
out of this scheme (better one honest exception than a leaky
abstraction).

### What generation must preserve

- Wire behavior byte-for-byte, proven by the existing matrix:
  the full interop matrix (all language pairs) must pass with
  generated implementations, at the same case coverage as today.
- The generated tests that drive these services do not change.
- One risk to name plainly: these files double as idiomatic
  server examples in each language's examples tree. Generated
  code is stamped from shared templates and reads less like
  hand-written idiom. Mitigation: keep the per-language example
  wrappers (startup, options) hand-written; generate only the
  service implementation body.

## Rollout

1. Spec + generator for JS and Python first (the two reference
   implementations), matrix legs green against all clients.
2. One language at a time after that, ordered by current drift
   risk: C (largest file), Zig, PHP, Lua, Dart, C++, Ruby last
   (H1 needs care).
3. Each step: replace the hand-written file with generated output
   at the same path, run that language's interop legs, then the
   full matrix before moving on.
4. Update `racket/README` inventory and this spec's status.

Estimated effort: 1–2 days for step 1, ~half a day per language
after, most of it matrix time.

## Alternatives considered

- Leave as-is: zero work, but every interop behavior change keeps
  costing nine manual mirrors, and drift stays likely.
- Shared test vectors only: describe expected payloads/status as
  data and keep hand implementations. Cheaper, but asserts outputs
  without removing the duplication.
- Generate only a conformance checker that diffs each hand
  implementation's behavior against the spec via the matrix:
  catches drift, keeps examples idiomatic, but the nine
  implementations remain.

## Open questions

1. Generate the implementations (this spec), or stop at the
   conformance-checker alternative?
2. Are the examples-tree copies (`*/examples/interop_service*`)
   in scope, or only the test-tree services (JS/Python)? The
   corpus export copies follow either way.
3. Hook H1 (Ruby cacheable): keep the quirk as a hook, or align
   Ruby to the common behavior and change the matrix expectation?
