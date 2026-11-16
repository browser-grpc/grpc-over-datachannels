# tcp-sidecar: userspace TCP leg (smoltcp) for the native wrapper

The native wrapper contract is `dc <-> http2 <-> stock gRPC server`
(see `racket/proxy-spec.rkt`, mode `smoltcp-sidecar`). The TCP leg
between the generated HTTP/2 side and the stock server is selectable:
an OS socket, or this sidecar — two [smoltcp](https://github.com/smoltcp-rs/smoltcp)
stacks joined by a virtual Ethernet pair, driven by one poll thread,
exposing Tokio `AsyncRead`/`AsyncWrite` streams.

Why a userspace leg: packet-loss instrumentation a kernel socket
cannot report. Every frame crosses the pair in-process, so
`Sidecar::stats()` returns wire-level frame/byte counts and TCP
retransmissions (bridge-level sequence tracking), and
`Sidecar::link_stats()` fills the TCP leg of the unified
`grpc_dc::link_stats::LinkStats` snapshot (SCTP + TCP + HTTP/2).

`dc-webrtc` stays zero-dependency; smoltcp lives only in this crate.

```sh
cargo test   # echo, stats, and loss-injection (drop every Nth frame) tests
```

Limits: IPv4, one listener (port 50051), virtual loopback-style link.
This is a test/embedding leg, not a general network stack.
