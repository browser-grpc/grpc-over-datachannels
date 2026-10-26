#lang racket

;;; sctp-spec.rkt — cross-stack SCTP conformance scenarios as
;;; data. Emitters (sctp-gen.rkt) stamp these as JSON consumed by
;;; the Go/JS/Rust SCTP test suites, so all three stacks prove
;;; the same wire behaviours on the same inputs — the drift class
;;; behind the v0.32.12 reassembly wedge. The reassembly machine
;;; itself is generated from sctp-dsl.rkt.
;;;
;;; Scenario: (name stream messages deliver expect)
;;;   messages: ((fill-char size) ...) sent in order on `stream`
;;;   deliver:  permutation of the concatenated fragment-packet
;;;             indices (fragments are 1000-byte chunks, the
;;;             MAX_DATA_PAYLOAD of every stack)
;;;   expect:   indices of messages in expected delivery order

(provide sctp-scenarios)

(define sctp-scenarios
  '(;; B's BEGIN fragment lands before A's END fragment: the two
    ;; messages must not merge across the boundary (v0.32.12).
    (interleaved-fragments 0 ((a 1500) (b 1500) (c 5)) (0 2 1 3 4) (0 1 2))
    ;; All fragments of one message in reverse order: BEGIN last.
    (reverse-fragments 0 ((x 2500)) (2 1 0) (0))
    ;; Retransmitted duplicates must deliver exactly once.
    (duplicate-fragments 0 ((d 1500)) (0 0 1 1) (0))
    ;; B completes reassembly first but ordered delivery holds it
    ;; behind A (SSN order), then releases both.
    (ordered-waits-for-gap 0 ((a 1500) (b 10)) (2 0 1) (0 1))
    ;; Middle fragment first, then BEGIN, then END.
    (middle-fragment-first 0 ((m 2500) (n 7)) (1 0 2 3) (0 1))))
