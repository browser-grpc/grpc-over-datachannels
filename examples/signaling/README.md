# Signaling example: browser → server with one POST

The smallest browser on-ramp: one Node process serves the page
and the generated HTTP/POST signaling endpoint. There is no
signaling server and no WebSocket — the page POSTs its
ICE-complete WebRTC offer to `/grpc-dc/signal`, the server
answers from its shared PeerMux (one UDP socket for every
browser session), and the Echo calls run over the `grpc`
DataChannel.

Run it:

```sh
node examples/signaling/server.mjs
# open http://localhost:8080/ in your browser
```

The page runs a unary Echo (`echo: hello`) and a
server-streaming Echo (indexes 0, 1, 2) and prints
`signaling example OK`.

Pieces:

| File | What |
|---|---|
| [server.mjs](server.mjs) | HTTP server: static page + `signalingHandler` (generated, `js/src/signaling_server.js`) + generated Echo service |
| [client.html](client.html) | Page using generated `httpSignalingChannel("/grpc-dc/signal")` and the generated Echo client |

Notes:

- Non-trickle by design: the browser waits for ICE gathering
  to complete so one POST carries every candidate. Server
  peers can also trickle and restart — see the signaling
  contract in [SPEC-WEBRTC.md](../../SPEC-WEBRTC.md).
- Auth and CORS belong to your application: mount
  `signalingHandler` behind them, or front the standalone
  server. Same-origin serving (as here) needs no CORS at all.
- Browsers still cannot dial WebRTC-Direct multiaddrs (no UDP
  sockets); this full-ICE POST shape is the browser path. The
  Direct examples are in [../direct](../direct).
