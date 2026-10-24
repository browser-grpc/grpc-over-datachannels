# grpc-dc-proxy

A supported TCP <-> DataChannel proxy process. grpc-dc clients
(browser tabs, native peers) connect over WebRTC DataChannels;
every call is translated into a real HTTP/2 gRPC stream against
a stock backend, so unmodified grpc-go / grpc-java / grpc-node
servers become reachable from a browser — no grpc-web proxy in
the page path, no backend changes, and gRPC compression is
terminated in the proxy (the DataChannel wire stays
uncompressed).

This generalizes the interop-test oracle bridge
(`oracle/bridge.mjs`, the hand-written kernel) into a runnable
service with WebSocket signaling compatible with the starter
demo.

## Run

    node proxy/grpc-dc-proxy.mjs --backend 127.0.0.1:50051 [--port 8090]

- `--backend host:port` — the stock HTTP/2 gRPC server (h2c).
- Clients signal through `ws://<proxy>/` with the starter
  offer/answer exchange (`{kind:"offer",sdp}` ->
  `{kind:"answer",sdp}`), then open the `grpc` DataChannel.
- `GET /healthz` returns `ok`.
- For remote browsers, put the proxy behind any HTTPS tunnel
  (e.g. `cloudflared tunnel --url http://localhost:8090`), as
  with the starter demo; pages must then use `wss://`.

## Test

    node --test proxy/proxy.test.mjs     # or: make test-proxy

Spins up a minimal HTTP/2 Echo backend and drives a generated
JS client over a real DataChannel through the proxy: unary,
server-streaming, and an INVALID_ARGUMENT trailers-only case.

## Roadmap (not in this spike)

- TCP listener mode via a userspace TCP stack (smoltcp) in a
  Rust sidecar, for languages that prefer plain sockets.
- HTTP/3 (QUIC) termination in the proxy for QUIC backends.
- Generated per-language proxy examples/docs from the
  transport spec (today: this README + the JS-path test).
