# Spec: a pkg.go.dev-indexable Go module path

Status: scoped, not implemented. Breaking change; needs a
dedicated session and a major/minor version decision.

## Problem

The Go module is literally named `grpcdc`:

```
module grpcdc
require dcwebrtc v0.0.0
replace dcwebrtc => ../webrtc/go
```

pkg.go.dev only indexes modules whose path is a resolvable
repository path (e.g. `github.com/browser-grpc/...`). Short
names also mean user code imports read as `grpcdc "grpcdc"`,
`echo "grpcdc/examples"` — no provenance, and the `replace`
for the WebRTC stack only resolves inside this repo layout.

## What a rename touches

- `go/go.mod` (module line; drop or vendor the `dcwebrtc`
  replace — the WebRTC stack needs its own module path too,
  e.g. `github.com/browser-grpc/grpc-over-datachannels/webrtc/go`,
  or a multi-module repo layout).
- Every generated Go file's imports: the Go template and
  runtime emitters (`racket/template-go.rkt`,
  `racket/runtime-go.rkt`, Go parts of `racket/webgen.rkt`,
  eventbus/bdd/http2 generators) emit `"grpcdc/..."` strings;
  all become the new prefix. Regeneration restamps the tree,
  but corpus exports and docs snippets change too.
- Hand-written Go: tests, `go/cmd/*`, `go/internal`-adjacent
  harnesses, oracle drivers, examples.
- Public surface: the release zip / GitHub export layout
  (users copy the `go/` tree or `go get` the new path),
  README examples, docs/llms.txt snippets.
- Existing users: any external code importing `grpcdc/...`
  breaks at the rename. Mitigation is a major version bump
  and a CHANGELOG migration note; there is no alias mechanism
  for renamed modules.

## Proposed end state

```
module github.com/browser-grpc/grpc-over-datachannels/go
```

with the WebRTC stack as a sibling module

```
module github.com/browser-grpc/grpc-over-datachannels/webrtc/go
```

required by version (no `replace`) in the published export,
and `replace` kept only in the private monorepo layout if
needed for local development.

## Rollout

1. Rename in the generators first; `make generate` +
   `make check-generated` restamp the tree.
2. Fix hand-written Go imports (mechanical prefix swap).
3. `make test-go` + the Go browser harnesses + oracle legs.
4. Update export layout and docs; verify a clean external
   consumer can `go get` the module and build the echo demo
   against pkg.go.dev's proxy (GOFLAGS=-mod=mod, GOPROXY on).
5. Ship in a minor bump with a CHANGELOG migration note.

Estimated effort: half a day, most of it verification.

## Risks

- The repo's folder-local layout (module at `go/`, WebRTC at
  `webrtc/go/`) means the repository path and the module path
  diverge by one segment; pkg.go.dev handles that, but the
  export tooling must preserve it.
- `dcwebrtc` has the same short-name problem; renaming only
  `grpcdc` leaves the replace in place for external users,
  which defeats the purpose. Both move together or not at all.
