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
the canonical table lives in the generator's protocol specification and
is generated into every language's codec from that one source.

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
no separate deadline frame. All 15 runtimes implement this (in each
language's idiom: Python `timeout=`, JS `{timeout}`, Go
`context.Context`, Rust `CallOptions`, Java/Kotlin `Duration`, C#
`TimeSpan`, C++ `std::chrono::milliseconds`, Swift/Dart
`Duration`/`TimeInterval`, Ruby and PHP `timeout:`, Scala `Duration`, Lua seconds argument,
Zig `timeout_ms`). On wasm32, Rust enforces deadlines through
the host JavaScript `setTimeout`, and the native Zig runtime
through a host monotonic-clock hook installed by its browser
transport (`performance.now()` in the worker). The native C++
wasm32 runtime enforces through `std::chrono::steady_clock`,
backed by the worker's WASI `clock_time_get` (monotonic), with
the endpoint in inline pump mode: Transports may offer a
bounded `TryRecv`, in which case no read/dispatch threads are
spawned and stream waits pump the transport. The native Swift
(Embedded Swift, `wasm32-unknown-none-wasm`) and Kotlin
(Kotlin/Wasm) runtimes — like the native Zig and C++ wasm
runtimes — use the same inline pump mode in both client and
server roles (a server-only worker drives its endpoint with
PollOnce/pollOnce); the Lua WASM runtime serves the same
way, and the async Dart/Rust WASM runtimes serve
event-driven on the page thread: Swift
deadlines run on a monotonic `Double` millisecond clock
(`GrpcTime.NowMs()`, `performance.now()` in the worker via
`js_now_ms`, Foundation wall clock natively), and Kotlin/Wasm
deadlines run on `performance.now()` through the generated
`grpcdcNowNanos()`, with stub timeouts as `Long` nanoseconds
(the JVM keeps `java.time.Duration`). One caveat is an
implementation limit, not a wire difference: in cooperative
pump runtimes (Lua single-threaded, Zig, C++, Swift, and
Kotlin/Wasm inline mode) a handler already running inline
cannot be preempted — the deadline is checked between
messages.

## Tracing (homegrown, opt-in)

Runtimes carry W3C Trace Context propagation without any
dependency: when the application registers a span observer
(`set_tracer`/`setTracer`/`SetTracer`/`grpcdc_set_tracer`,
depending on language), the client writes a `traceparent`
metadata entry (`00-<trace-id>-<span-id>-01`) into HEADERS —
continuing an incoming `traceparent` from call metadata when
present — and the server parents its span to it. Observers
receive `on_start`/`on_end` callbacks with kind (`client` /
`server`), method path, trace/span ids, and the terminal status
name. With no observer registered the wire is unchanged: no
header is written and no ids are minted. Sampling, batching,
and export (OTLP or otherwise) are deliberately out of scope —
this is propagation plus hooks, not an OpenTelemetry SDK.

The protoc plugins accept `trace=off|hooks` (default `off`).
`hooks` additionally wires the registrar into generated stubs
where the generator supports it (currently the Python stub
re-exports `grpcdc.set_tracer`); any other value is a plugin
error. The runtime API itself is always present and dormant.

`set_trace_filter(patterns)` restricts which methods produce
spans: `;`-separated method paths, a trailing `*` meaning
prefix match (`/echo.Echo/*`); empty traces everything. The
plugin parameter `trace_methods=<patterns>` (requires
`trace=hooks`) bakes the filter into generated stubs;
malformed patterns are a plugin error. Two stub exceptions:
JS stubs never import the runtime (its location is a
deployment choice), so JS applications import `setTracer` /
`setTraceFilter` from the runtime entry point; the Wasm
wrapper stubs likewise use the JS runtime they wrap.

Examples live outside the runtimes: `tracing_demo` (Python and
JS) prints one parented trace per call, and `otlp_tracer`
(Python and JS) is an observer that batches ended spans and
POSTs OTLP/JSON to a collector with only the standard library /
platform fetch — proof the hooks suffice for a real backend,
with export failures swallowed by design. The browser
generator offers a per-language `trace` select that feeds the
same plugin parameter.

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
