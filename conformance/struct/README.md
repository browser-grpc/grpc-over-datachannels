# Struct-codec conformance corpus

Two shapes: one wide proto3 shape (`msgs.proto`: nested message, enum,
packed repeated scalars, both maps, oneof, bytes, fixed32/fixed64,
sint) and one proto2 shape (`msgs2.proto`: required/optional presence,
explicit defaults, unpacked repeated, an extension field), each with a
golden byte string (`golden.hex` / `golden2.hex`, produced by the Go
generated codec) that every language's struct codec must reproduce
byte-for-byte, in both directions. The proto2 shape locks the
presence semantics documented in SPEC.md (proto3-style presence;
extension bytes ride the unknown-fields tail). A language joins the
struct-codec rollout only by passing
`scripts/test-struct-corpus.py <lang>` (run by the `Makefile`
`test-struct-corpus` target, part of `make test`).

## Admitted languages

go (reference), rust, java, kotlin, scala, swift, dart, csharp, c,
cpp, zig — each reproduces `golden.hex` byte-for-byte, both
directions, via `scripts/test-struct-corpus.py`. The shared
descriptor-driven Rust implementation (`grpc_dc::structdc`) is
gated the same way as the `rust-shared` entry.

## Adding a language

1. Emit the struct codec from the language's Racket template behind
   the `struct_codec=true` proto-plugin option.
2. Add a driver under `drivers/<lang>/` that decodes `golden.hex`,
   re-encodes it, and exits nonzero unless the re-encoded bytes equal
   the golden bytes (self-consistency through the golden input also
   covers decode).
3. Register the language in `scripts/test-struct-corpus.py` and in
   the `STRUCT_LANGS` list in the `Makefile`.
