#lang racket

;;; mux-spec.rkt — the shared-socket (PeerMux) parity scenario
;;; as data. One table, three generated tests (Rust, Go, JS
;;; Node) stamped by mux-gen.rkt and run natively in each
;;; stack, so the single-port server topology is specified
;;; once and cannot drift between stacks.
;;;
;;; Scenario: one PeerMux binds a loopback UDP port; it hosts
;;; `pairs` peers, each cross-connected to an ordinary
;;; single-socket client. All pairs connect concurrently,
;;; echo on the same channel `label`, and must hear only
;;; their own payload (`payload-prefix` + pair index, answered
;;; with `reply-prefix` + payload). The mux peers must also
;;; advertise the shared port in their host candidates.

(provide mux-scenario mux-spec)

(define mux-scenario
  '((pairs . 2)
    (label . "echo")
    (payload-prefix . "hello-from-pair-")
    (reply-prefix . "re:")
    (bind-ip . "127.0.0.1")))

(define (mux-spec key)
  (cdr (assoc key mux-scenario)))
