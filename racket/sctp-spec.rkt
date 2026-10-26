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

(provide sctp-scenarios sctp-sack-scenarios)

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

;; Phase 3 scenarios for the SACK/gap/retransmit machine
;; (sctp-dsl.rkt). Scenario: (name initial-cum steps)
;;   step (recv tsn gaps): noteReceived(tsn); gapBlocks() == gaps
;;   step (sack cum blocks unacked acked retransmit):
;;        noteSack(cum, blocks, unacked) == (acked, retransmit)
;;     gaps/blocks are (start end) offset pairs; tsn lists are
;;     absolute TSNs in serial order.
(define sctp-sack-scenarios
  '(;; Out-of-order arrivals open and close gap blocks; the
    ;; cumulative TSN jumps the filled run.
    (gap-open-close 100
      ((recv 102 ((2 2)))
       (recv 103 ((2 3)))
       (recv 105 ((2 3) (5 5)))
       (recv 101 ((2 2)))
       (recv 104 ())))
    ;; A gap block acks its TSNs; TSNs below the first block
    ;; start miss once per SACK and fast-retransmit at 3.
    (fast-retransmit 200
      ((sack 200 ((10 10)) (201 202 203 210) (210) ())
       (sack 200 ((10 10)) (201 202 203) () ())
       (sack 200 ((10 10)) (201 202 203) () (201 202 203))))
    ;; Cumulative advance retires everything at/below cum.
    (sack-cum-advance 200
      ((sack 202 () (201 202 203) (201 202) ())))
    ;; Serial arithmetic at the wrap point: cum = 2^32-2.
    (wrap-around 4294967294
      ((recv 0 ((2 2)))
       (recv 4294967295 ())))))
