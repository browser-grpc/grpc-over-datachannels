# grpc-dc (Rust)

gRPC over WebRTC DataChannels — a dependency-free generated
Rust runtime: client and server, all four call shapes
(unary, server/client streaming, bidi), deadlines, metadata,
and status over a single `RTCDataChannel`. Stub code is
generated from your `.proto` by the grpc-dc protoc plugins;
this crate is the runtime those stubs call.

```toml
[dependencies]
grpc-dc = "0.41.0"
```

Features: `prost` (prost messages implement the runtime's
`Message` trait automatically) and `kafka-tls` (TLS to a
Kafka broker for the proxy examples). The in-repo crate's
`webrtc` feature (the reimplemented WebRTC stack) is not in
the crates.io build because it is a path dependency; use
the repository checkout by path if you need it. Kafka
stubs ship separately in the `kafka-grpc` crate, which
depends on this one.
