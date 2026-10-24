# gRPC in the browser, without grpc-web: a DataChannel tutorial

**Pitch (dev.to / Hashnode, ~1200 words).** Audience: web developers who
hit grpc-web's proxy requirement and gave up on gRPC in the browser.

## Outline

1. The problem: browsers cannot open TCP sockets, so gRPC needed a
   translating proxy (grpc-web + Envoy). That proxy is ops, latency,
   and a streaming compromise.
2. The alternative: WebRTC DataChannels are ordered, reliable,
   encrypted (DTLS) byte streams the browser already ships. Run the
   gRPC wire protocol (frames, trailers, status codes) directly
   over one.
3. Live demo: open the generator, press "Run your first RPC", watch
   a generated client call a server in the same page. Then the
   browser-to-native step: `node examples/starter/server.mjs`, open
   localhost, real RTCDataChannel to a Node server.
4. Code walk: the ~10 lines (Channel over RTCDataChannel, generated
   EchoClient), what signaling is (SDP text over anything), what it
   is not (no traffic through the signaling channel).
5. Generating your own service: paste a .proto in the browser or
   use protoc wrappers; 16 languages, dependency-free runtimes,
   TypeScript types for JS.
6. Honest limits: NAT needs TURN, WebKit uses fallback generators
   (byte-identical output), no compression on the DataChannel wire
   (terminate it in the TCP<->DataChannel oracle proxy if needed).
7. Try it: links to live app, QUICKSTART, gallery, starter.

## Assets

- docs/first-run.gif (guided first run)
- docs/social-preview.png
- Code snippets from QUICKSTART.md steps 1-2 (keep in sync manually)
