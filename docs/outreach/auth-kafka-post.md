# Rendezvous auth + kafka-native post — prepared 2026-11-16 for publication

Covers v0.42.0 (rendezvous auth, WebAuthn issuer, share
groups everywhere) and v0.41.0 (kafka-native). Both
releases are live and verified on the registries below.

Links:
- Releases: https://github.com/browser-grpc/grpc-over-datachannels/releases/tag/v0.42.0
  and https://github.com/browser-grpc/grpc-over-datachannels/releases/tag/v0.41.0
- kafka-native repo: https://github.com/browser-grpc/kafka-native
- Repo: https://github.com/browser-grpc/grpc-over-datachannels
- crates.io: https://crates.io/crates/grpc-dc (kafka-native)
- PyPI: https://pypi.org/project/grpc-dc/ (kafka-native wheel
  ships from the kafka-native repo)
- SPEC-WEBRTC.md documents the token wire format.
- Videos: Kafka https://youtu.be/KJ98a4ApZ4E, Event Bus https://youtu.be/PujUnQyxKWg, channel https://www.youtube.com/@JohnDavis-jf3on

---

## dev.to article (primary, long form)

Title: **Authenticating a rendezvous server with passkeys, and a Kafka client in every language**

Tags: grpc, webrtc, security, kafka

Body:

Two releases of grpc-over-datachannels landed together
this month, and they share a theme: closing the "yes, but
in production?" gaps. 0.42.0 adds authentication and
authorization to the rendezvous server. 0.41.0 extracts
the Kafka client into its own native library with wrappers
in every language we generate for.

### Who is allowed to open a channel?

The rendezvous server brokers peer introductions, and
until now it trusted any caller who could reach it. It can
now require an HMAC-SHA256 bearer token on every call:

```
base64url(protobuf claims) + "." + base64url(HMAC-SHA256)
```

The claims are `sub/iss/aud/exp/nbf/iat/scopes[]/jti` —
one wire layout, implemented identically in the generated
JS, Go, and Rust servers and pinned by a single shared
test vector, so a token minted for one stack validates on
the other two. Verification happens before dispatch: bad,
missing, or expired tokens fail `UNAUTHENTICATED`; a valid
token without the scope a method needs fails
`PERMISSION_DENIED`. Required scopes are a per-method-path
map in the serve options, and verified claims reach the
handler (`ctx.claims` in JS, `ClaimsFromContext` in Go,
`CallCtx.claims` in Rust). Clients attach tokens per call
with `rendezvousChannel(descriptor, { token | getToken })`,
so token refresh is a callback, not a rebuild. Auth is
rendezvous-only by design — there is no protoc option,
because the DataChannel itself is the authenticated
channel once the introduction is made.

Where do tokens come from? `examples/rendezvous-auth/` is
a stdlib-only WebAuthn issuer in Node: it verifies passkey
registration and login over HTTPS and mints rendezvous
tokens. The rendezvous server never sees WebAuthn data —
it checks HMACs, the issuer checks passkeys, and the two
meet only at the shared secret. A browser-free synthetic
credential test covers the ceremony end to end.

### One Kafka client, every language

`browser-grpc/kafka-native` is the in-process Kafka
protocol client extracted from the kafka-proxy sidecar,
published as a Rust crate and a Python wheel via Trusted
Publishing. Every native wrapper binds the same C ABI
(`kafka_native_new_v2`, with SASL PLAIN/SCRAM and TLS):
Python, Ruby (Fiddle), Dart (dart:ffi), C# (P/Invoke),
Java (JNI), PHP (FFI), JavaScript (N-API), and Go (cgo).
The generated `kafka-grpc` clients and the in-process form
factor cross-check each other record-for-record in a
differential gate — all compression codecs, consumer
groups, offsets — and since 0.42.0 the KIP-932 share-group
session RPCs (`OpenShareGroup`, `SharePoll`, `ShareAck`,
`CloseShareGroup`) dispatch through the FFI too, matching
the proxy surface in every generated wrapper. KIP-848
next-generation consumer groups (server-side assignment,
epoch fencing) are in, with the classic protocol as
automatic fallback.

The pattern worth stealing: generate the protocol once,
bind it everywhere, and make the form factors grade each
other's homework in CI. Two independent paths to the same
broker leave very few places for a bug to hide.

Both releases are live on npm, PyPI, pub.dev, crates.io,
NuGet, Maven Central, RubyGems, LuaRocks, and JSR. If you
put rendezvous auth in front of a real deployment, we'd
like to hear which scopes you ended up needing — the
per-method map is deliberately boring, and boring is what
you want from an authorization surface.

---

## Blogger version (c100k.blogspot.com)

Title: Authenticating a rendezvous server with passkeys, and a Kafka client in every language

Reuse the dev.to body with HTML formatting; canonical links
to the GitHub releases and package pages above.
