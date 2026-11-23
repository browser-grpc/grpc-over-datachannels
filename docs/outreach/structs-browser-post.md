# Structs in the browser post — prepared for the v0.46.0 release

Status: READY. Publish with the v0.46.0 release; links below
verified live at publication. Never mention generator
internals in public copy.

Links (verify at publication):
- Release: https://github.com/browser-grpc/grpc-over-datachannels/releases/tag/v0.46.0
- Repo: https://github.com/browser-grpc/grpc-over-datachannels
- Live stub generator: https://browser-grpc.github.io/grpc-over-datachannels/app/

---

## dev.to article (primary, long form)

Title: **Packed structs on the wire, now in the browser: Cap'n-Proto-style gRPC without giving up protobuf**

Tags: grpc, webrtc, webdev, performance

Body:

v0.46.0 of grpc-over-datachannels closes the last gap in the
struct codec story: the packed, Cap'n-Proto-style wire format
that native languages got in v0.45 now works in every
browser-tier language too — JavaScript, Python, Lua, PHP, and
Ruby — and in the Wasm builds of Swift, Dart, C++, Zig,
Kotlin, and Scala.

Quick refresher on the design. Protobuf is, and remains, the
default wire format and the interop format. But on
low-latency internal paths — kernel-bypass adapters,
latency-sensitive fan-outs, hot loops where protobuf's
varint/tag walk is the cost — you can opt a message into a
second codec at generation time:

```proto
// protoc --grpc-dc-js_opt=struct_codec=true ...
```

Generated messages gain `marshalStruct()` / `unmarshalStruct()`
companions emitting the packed DCS1 layout: a small header
(magic, length, schema fingerprint, presence bitmap), one
fixed slot per field in field-number order, then a variable
area for strings, nested messages, repeated elements, and
sorted map entries. No tags, no varints on the hot path; field
access is offset arithmetic.

Opt-in is per endpoint, never silent:

```js
channel.setStructCodec(true); // client
server.setStructCodec(true);  // server
```

The client marks the call with `dc-codec: struct-v1` HEADERS;
a server that hasn't enabled it answers UNIMPLEMENTED rather
than quietly falling back. Protobuf servers and clients that
never heard of any of this keep working untouched — that's
the point of negotiating at the edges: structs inside,
protobuf at the boundary, transcode where they meet.

The browser implementations are pure, descriptor-driven
transcoders over each language's existing dynamic protobuf
model — no native bridge, which is exactly why they also work
in Wasm, where there is no cdylib to call into. Every
implementation is proven byte-identical against a Go golden:
the conformance corpus (`scripts/test-struct-corpus.py`) now
admits 21 drivers, all passing, and v0.46 extends it with a
second, proto2 shape covering explicit defaults, unpacked
repeated fields, and extensions (which ride the
unknown-fields tail verbatim).

Also in this release: a third Google interop peer. After
grpc-java and grpc-go, `oracle/dart-interop` runs the
canonical gRPC interop cases over google's grpc-dart runtime
in both directions, and every language suite now exercises
grpc-java, grpc-go, and grpc-dart clients against its
generated server, plus its generated client against all three
servers.

If you generate stubs in the browser playground, struct
generation is available there too — the pure transcoders ship
in the bundled runtimes, so what you download runs as-is.

Release notes and packages (npm, PyPI, pub.dev, crates.io,
NuGet, Maven, RubyGems, LuaRocks, JSR):
https://github.com/browser-grpc/grpc-over-datachannels/releases/tag/v0.46.0

---

## Blogger version (c100k.blogspot.com)

Same body, title: **Packed structs on the wire, now in the browser (grpc-over-datachannels v0.46.0)**

---

## YouTube description (structs video + Short)

Packed structs (DCS1) for gRPC over WebRTC DataChannels —
now in JavaScript, Python, Lua, PHP, Ruby, and the Wasm
builds of Swift, Dart, C++, Zig, Kotlin, and Scala. Protobuf
stays the default; structs are opt-in per endpoint with
`dc-codec: struct-v1` negotiation.

Code: https://github.com/browser-grpc/grpc-over-datachannels
Release: https://github.com/browser-grpc/grpc-over-datachannels/releases/tag/v0.46.0
In-browser stub generator: https://browser-grpc.github.io/grpc-over-datachannels/app/
