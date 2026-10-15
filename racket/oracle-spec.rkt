#lang racket

;;; oracle-spec.rkt — the oracle scenario table, written ONCE.
;;;
;;; metagen.rkt stamps it into fixtures/oracle_scenarios.txt (consumed
;;; by the hand-written official grpc-java client, the independent
;;; oracle), and oracle-gen.rkt stamps it into generated scenario
;;; drivers for JS, Go and Rust. Grammar per entry:
;;;   (UNARY <msg> [EXPECT_STATUS <code>])   ("-" encodes empty message)
;;;   (SERVER_STREAM <msg> <count>)
;;;   (CLIENT_STREAM <msg>...)
;;;   (BIDI <msg>...)
;;; Expectation rules are the shared Echo semantics: unary echoes
;;; "echo: <msg>", fail -> INVALID_ARGUMENT, streams echo in order,
;;; client-stream joins with "+".

(provide oracle-scenario-table)

(define oracle-scenario-table
  '((UNARY hello)
    (UNARY -)
    (UNARY fail EXPECT_STATUS 3)
    (SERVER_STREAM tick 3)
    (SERVER_STREAM once 1)
    (SERVER_STREAM zero 0)
    (CLIENT_STREAM a b c)
    (CLIENT_STREAM solo)
    (BIDI x y)
    (BIDI one)))
