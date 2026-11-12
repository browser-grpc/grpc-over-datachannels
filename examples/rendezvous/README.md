# Rendezvous example: browser → fixed server, no signaling

The smallest browser on-ramp when the server's address is
fixed: the server pre-publishes a rendezvous descriptor
(host, port, ICE credentials, DTLS fingerprint), the page
synthesizes the server's WebRTC description locally, and the
Echo calls run over the `grpc` DataChannel. No signaling
server, no signaling POST, no WebSocket — nothing is
exchanged after the descriptor is published.

Run it:

```sh
node examples/rendezvous/server.mjs
# open http://localhost:8080/ in your browser
```

The page runs a unary Echo (`echo: hello`) and a
server-streaming Echo (indexes 0, 1, 2) and prints
`rendezvous example OK`.

Pieces:

| File | What |
|---|---|
| [server.mjs](server.mjs) | HTTP server for the page + descriptor JSON, and `serveRendezvous` (generated, `js/src/rendezvous_server.js`) + generated Echo service on the fixed listener |
| [client.html](client.html) | Page using generated `rendezvousChannel(descriptor)` and the generated Echo client |

Notes:

- The descriptor here is fetched from `/rendezvous.json`
  purely so the example works unedited; hardcoding it in the
  page is equally valid. Serving it over HTTPS from a
  well-known URL with a short cache lifetime is the rotation
  story — see the Rendezvous section of
  [SPEC-WEBRTC.md](../../SPEC-WEBRTC.md).
- The listener's ICE credentials and certificate here are
  ephemeral (they rotate each restart, and the fetched
  descriptor always matches). Fix them via
  `serveRendezvous` options and the published descriptor
  stays stable across restarts.
- Limits: fixed address only (dynamic address → the
  one-POST signaling shape in [../signaling](../signaling));
  the descriptor host is an IP literal, not a DNS name; no
  ICE restart (redial instead). Details in
  [SPEC-WEBRTC.md](../../SPEC-WEBRTC.md).
