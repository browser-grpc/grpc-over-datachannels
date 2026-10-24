# Starter: browser client <-> Node server in one command

Run it:

    node examples/starter/server.mjs
    # open http://localhost:8080/ and press "Run Echo calls"

No `npm install`: the runtime, WebRTC stack, and the minimal
WebSocket signaling shim are all in this repository and use only
Node builtins (Node >= 18). The page and the server exchange SDP
as text over WebSocket; the actual gRPC calls run peer-to-peer
over the `grpc` RTCDataChannel.

Files:

- `server.mjs` — HTTP page server + WebSocket signaling + the
  generated Echo service on the in-repo Node WebRTC stack.
- `signal.mjs` — tiny RFC 6455 server subset (SDP text only).
- `client.html` — browser client; edit, reload, re-run.

Next steps: replace the Echo handlers in `server.mjs` with your
service (regenerate stubs with `bin/protoc-gen-grpc-dc-js`), or
swap WebSocket signaling for fetch/QR/manual paste — SDP is
just text. For a native-to-native pair, see `js/examples/`.