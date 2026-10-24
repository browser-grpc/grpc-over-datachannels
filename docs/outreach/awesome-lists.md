# Awesome-list submission text

One-line entry (awesome-grpc / awesome-webrtc style):

- [grpc-over-datachannels](https://github.com/browser-grpc/grpc-over-datachannels) — gRPC wire protocol over WebRTC DataChannels: browser clients on native RTCDataChannel plus dependency-free generated runtimes for 16 languages, an in-browser protoc generator, protoc plugins via release zip / npm / container, and a proxy bridging browsers to stock HTTP/2 gRPC backends.

Longer blurb (resource pages, newsletters):

> grpc-over-datachannels speaks gRPC directly over WebRTC
> DataChannels, so a browser tab can call native services
> peer-to-peer with no grpc-web proxy. Stubs and runtimes are
> generated from your .proto for JavaScript/TypeScript, Go, Rust,
> Python, and 12 more languages — all dependency-free — and the
> live site generates code in the browser. Includes a one-command
> browser<->Node starter with signaling included.

Targets: awesome-grpc, awesome-webrtc, awesome-protobuf,
awesome-wasm (Wasm facades), awesome-typescript (typed JS client).
Submission checklist (in a publish window, after the latest
release verifies): fork the list, add the one-line entry in
its alphabetical slot with the list's exact format, open the
PR from the fork with `gh pr create`, link the latest release
(not master), and record the PR URL here after submission.
