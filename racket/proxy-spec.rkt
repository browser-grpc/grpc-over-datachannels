#lang racket

;;; proxy-spec.rkt — the proxy mode table, written ONCE.
;;;
;;; proxy-gen.rkt stamps it into proxy/proxy_modes.generated.json
;;; (consumed by proxy/proxy.test.mjs as a spec<->code parity
;;; check) and into proxy/README.md (the supported-proxy doc).
;;; Status vocabulary: shipped = proven end-to-end in `make test`
;;; today; spike = standalone proof in its own crate/suite, not
;;; yet in the release gate; planned = designed, not built.

(provide proxy-mode-table proxy-client-notes)

;; (id title status implementation client-facing-note)
(define proxy-mode-table
  '((http2-bridge
     "HTTP/2 backend (h2c)"
     shipped
     "proxy/grpc-dc-proxy.mjs (Node, stdlib only)"
     "Stock grpc-go / grpc-java / grpc-node server, unmodified; compression terminated in the proxy")
    (tcp-smoltcp
     "Plain TCP via userspace stack (smoltcp)"
     spike
     "proxy/tcp-sidecar (Rust, smoltcp)"
     "Userspace TCP termination over a packet transport; zero OS sockets in the proof")
    (http3-terminator
     "HTTP/3 (QUIC) backend"
     spike
     "proxy/h3-terminator (Rust, quinn)"
     "QUIC terminated in the proxy; streams bridged to a TCP backend")))

;; How each client surface reaches a backend through the proxy.
(define proxy-client-notes
  '((browser
     "Browser (JS + all Wasm languages)"
     "Signaling over WebSocket to the proxy, then the `grpc` DataChannel; the proxy is the only HTTP/2 speaker")
    (native
     "Native (all generated languages)"
     "Same exchange via the native WebRTC stacks, or file-based SDP in tests; identical proxy protocol")))
