# Troubleshooting

## The page cannot create a DataChannel / crypto is unavailable

WebRTC requires a secure context: `https://`, `http://localhost`, or a
`trycloudflare.com` tunnel URL all qualify; a plain `http://` LAN address
does not. Use the live site, `make webapp-serve`, or
`docker compose --profile tunnel up`.

## Which signaling should I use?

Any channel that moves text: WebSocket, fetch POST, a message broker,
or manual copy-paste. Only the SDP offer/answer crosses it (a few KB);
gRPC traffic never does. The starter in `examples/starter/` shows the
smallest WebSocket version. Swap the transport, keep the SDP handling.

## Peers connect on localhost but not across machines

That is NAT, not gRPC: ICE needs a TURN relay when both sides are
behind symmetric NATs. Point the peer at a TURN server (the repo's
WebRTC stacks accept TURN URLs/credentials), or test through the
Cloudflare tunnel profile. DataChannel traffic stays peer-to-peer;
the tunnel only serves the page and signaling.

## WebKit shows the fallback generators

Expected in some WebKit builds: the full plugin runtime cannot mount
its filesystem there, so the app uses the built-in generators. Output
is byte-identical either way (the parity suite pins this). For the
full plugin path, use Chromium or Firefox, or generate with the
`bin/protoc-gen-grpc-dc-*` wrappers locally.

## What plugs into `Channel` / `Server.serve`?

Anything with the DataChannel shape: a browser `RTCDataChannel`, the
in-repo Node/Rust/Go stack channel, an in-memory pair
(`memoryDataChannelPair` in JS), or a sidecar-bridged channel in the
other languages. The generated client and server do not change when
the transport does.

## A call hangs with no error

Check, in order: (1) both peers agree on the channel label (the gRPC
convention here is `grpc`); (2) the server actually called `serve`
on the accepted channel; (3) odd/even stream-id parity is not shared
by two clients on one channel; (4) deadlines — a streaming call
returns an async iterable, so `await` it before iterating.
