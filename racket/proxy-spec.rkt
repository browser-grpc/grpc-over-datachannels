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

;; Scope: exactly the official gRPC transport set (grpc-java
;; and peers) — HTTP/2 over TCP, plaintext or TLS. No HTTP/3,
;; no custom framed-TCP ingress: grpc-java supports neither.
;; (id title status implementation client-facing-note)
(define proxy-mode-table
  '((http2-ingress
     "HTTP/2 over TCP ingress -> grpc-dc server"
     shipped
     "proxy/grpc-dc-proxy.mjs --http2 [--tls-cert/--tls-key] (Node, stdlib only)"
     "Stock grpc-java / grpc-go / grpc-node clients (h2c or TLS) call a grpc-dc server; compression terminated in the proxy")))

;; How each surface reaches the other through the proxy.
(define proxy-client-notes
  '((official-clients
     "Official gRPC clients (grpc-java, grpc-go, grpc-node, ...)"
     "HTTP/2 over TCP (h2c or TLS) to the proxy; the proxy is the only DataChannel speaker")
    (grpc-dc-server
     "grpc-dc server (any generated language)"
     "Serves over WebRTC-Direct; the proxy dials its certhash multiaddr, no signaling server")))
