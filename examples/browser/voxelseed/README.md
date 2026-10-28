# VoxelSeed (multiplayer voxel demo, browser-hosted)

A tiny Minecraft-style voxel world. The session host's browser runs
the generated `demo.game.Game` service (`createGameService` via grpc-dc's
`Server`); guests run the generated `GameClient`. Both speak gRPC
over one WebRTC `RTCDataChannel` labelled `grpc`
(`js/index.js` `createPeer`). No game server, no signaling server.

Play it: <https://voxelseed.lunchgamer.com/>

## World types (procgen modes)

The host picks a world type in the lobby; it travels with the
seed in `JoinResponse.mode`, so every guest generates the
identical world locally:

- **Easy (0)** — gentle plains (heights 3–5, rare trees):
  effortless to walk across and build on.
- **Complex (1, default)** — Mojang-style voxel procgen:
  multi-octave mountains with ridged crests (heights 1–12),
  exposed stone on steep faces, sand lowlands, caves carved by
  3D value noise below the surface, and denser forests.

## How joining works (manual WebRTC signaling)

1. Host clicks **Host a session** → the page creates an
   `RTCPeerConnection`, gathers ICE, and shows an **invite link**:
   the page URL plus `#i=<base64url(JSON{type,sdp})>`.
2. A guest opens the link → the page builds the matching answer and
   shows an **answer link** (`#a=…`) to send back (chat, email, …).
3. Host pastes the answer → ICE connects, the DataChannel opens,
   and the guest calls `Join` (gets its player id, the terrain
   seed, and the host's block-edit log) then opens the `Play`
   bidi stream: positions up, player states + edits down.
   The host is authoritative for block edits; positions are
   relayed through it. More guests: **Invite another player**
   mints a fresh invite (one peer connection per guest).

## NATs, STUN, TURN

Browser-to-browser ICE does the traversal; the page defaults to
Google's public STUN server. Most residential NAT pairs connect
directly (cone NATs, UPnP-less home routers included). A pair of
symmetric NATs cannot hole-punch — for those, paste a TURN server
(your own coturn) into *Connection options*: traffic then relays
through it and always connects, at the cost of relay bandwidth.
TURN needs credentials because relay bandwidth is abusable; the
demo deliberately ships none. The grpc-dc native stacks implement
the same model (`SPEC-WEBRTC.md`: STUN srflx + RFC 5766 TURN
relay candidates, allocation refresh, `direct_dial_turn`), and
the browser relay-only path is covered by
`browser-test/direct_turn.test.mjs`.

If the host's tab closes, the session ends — the host *is* the
server.

## Files

- `game.proto` — the service/messages; stubs in `gen/` come from
  `bin/protoc-gen-grpc-dc-js` (do not edit; regenerate with
  `protoc --plugin=protoc-gen-grpc-dc-js=bin/protoc-gen-grpc-dc-js --grpc-dc-js_out=examples/browser/voxelseed/gen -I examples/browser/voxelseed game.proto`).
- `game.js` — voxel world (three.js), AABB physics, DDA block
  raycast, host/guest netcode, manual-signaling UI.
- `index.html` — page + lobby; Auto ads is injected after page
  load on the public lunchgamer host only (same pattern as the
  generator SPA), so ad latency can never stall the game.

## Deploy (Cloudflare Pages, lunchgamer)

Staged bundle (game files + `js/` runtime copied to `grpcdc/`,
import rewritten) deployed with:

```
wrangler pages deploy <stage-dir> --project-name lunchgamer-minecraft
```

Custom domain `voxelseed.lunchgamer.com` (CNAME to
`lunchgamer-minecraft.pages.dev`) is attached to that project.
The old `minecraft.lunchgamer.com` subdomain 301-redirects to it
(zone-level proxied AAAA `100::` + Single Redirect rule).
