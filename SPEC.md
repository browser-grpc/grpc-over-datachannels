# gRPC over WebRTC DataChannels — Wire Protocol v1

A single ordered, reliable `RTCDataChannel` carries many concurrent gRPC
calls (streams). Signaling, ICE, and peer connection setup are out of scope:
the caller hands an already-open channel to this library (Rust:
`grpc_dc::channel_pair` / any `DcTransport`; JS: any object with the
`RTCDataChannel` message interface — browser `RTCDataChannel`, `werift`,
`node-datachannel`, or the bundled memory loopback).

## Frame format

Every DataChannel binary message is exactly one frame. DataChannels preserve
message boundaries, so no length-prefixed message framing (gRPC LPM) and no
reassembly layer are needed:

```
 byte 0      : frame type (see table)
 bytes 1..5  : stream id, uint32 big-endian
 bytes 5..9  : payload length, uint32 big-endian
 bytes 9..   : payload
```

| Type | Name       | Direction       | Payload |
|------|------------|-----------------|---------|
| 0x01 | HEADERS    | both, first     | UTF-8 JSON: `{"path":"/pkg.Service/Method","metadata":{"k":"v"}}` (client→server); `{}` for server initial metadata |
| 0x02 | DATA       | both            | exactly one serialized protobuf message, raw bytes |
| 0x03 | TRAILERS   | server→client   | UTF-8 JSON: `{"code":0,"message":""}` — terminal, carries the gRPC status |
| 0x04 | HALF_CLOSE | client→server   | empty — client will send no more DATA |
| 0x05 | RST        | both            | UTF-8 JSON: `{"code":1,"message":"..."}` — aborts the stream |

Status codes are the standard gRPC codes 0–16 (`OK` … `UNAUTHENTICATED`);
the canonical table lives in `racket/spec.rkt` and is generated into the
Rust, JavaScript, and Racket codecs from that one source.

## Stream lifecycle

- The initiating peer allocates stream ids: odd ids (1, 3, 5, …) when it
  created the channel, even ids when it answered — so two peers that both
  act as client never collide. A `Channel`/`Server` pair over one channel
  therefore supports bidirectional calling (`DcPeer` in Rust).
- A call is: HEADERS (client) → HEADERS (server, initial metadata) →
  DATA* → HALF_CLOSE (client) → DATA* → TRAILERS (server, terminal).
  Unary is the degenerate case of one DATA frame in each direction.
- Either side may send RST at any time to abort; unknown stream ids,
  malformed frames, and calls to unregistered methods close with
  `UNIMPLEMENTED` / `INTERNAL` trailers instead of crashing the endpoint.
- Unknown frame types are ignored for forward compatibility. A DATA payload
  over 16 MiB is rejected with `RESOURCE_EXHAUSTED`.

## Deadlines

Deadlines propagate as the `grpc-timeout` HEADERS metadata key, using
the standard gRPC timeout grammar (`<digits><unit>`, units `H`/`M`/`S`/
`m`/`u`/`n`, at most 8 digits). The value is the time *remaining* when
the HEADERS frame is sent, so each hop that forwards a call recomputes
it. Clients enforce the deadline while waiting for responses: on
expiry they abort the stream with RST and surface `DEADLINE_EXCEEDED`.
Servers expose the received budget on the call context (remaining
time / deadline instant) and may check it in handlers; the wire has
no separate deadline frame. Runtimes are adopting this incrementally
(Python first; others currently pass `grpc-timeout` through as opaque
metadata, which stays wire-compatible).

## Backpressure

SCTP applies its own flow control per channel. Senders must still respect
the channel queue: the JS runtime pauses on `bufferedAmount` above a
threshold and resumes on `bufferedAmountlow`; the Rust runtime applies
backpressure through its transport trait (the loopback transport uses
bounded queues). Per-stream flow-control windows are a v2 concern.

## Deliberate divergence from gRPC-over-HTTP/2

No HTTP/2, no HPACK, no LPM: one DataChannel message == one protobuf
message. HEADERS/TRAILERS payloads are JSON rather than HTTP header blocks
so both runtimes stay dependency-light and debuggable; every other gRPC
concept (paths, methods, streaming shapes, status codes, metadata,
deadlines via RST) maps one-to-one.
