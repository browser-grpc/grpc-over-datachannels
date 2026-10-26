#lang racket

;;; interop-spec.rkt — the canonical grpc interop case table
;;; (grpc.testing.TestService, semantics mirroring upstream
;;; AbstractInteropTest) as data. Emitters in interop-gen.rkt
;;; stamp this table per language; runners interpret it. Case
;;; kinds: EMPTY, LARGE_UNARY, CLIENT_STREAMING, SERVER_STREAMING,
;;; PING_PONG, EMPTY_STREAM, STATUS_UNARY, STATUS_DUPLEX,
;;; UNIMPLEMENTED_METHOD, UNIMPLEMENTED_SERVICE.
;;;
;;; Row: (name kind req-sizes resp-sizes status-code status-message)
;;; req-sizes: request payload sizes (client-streaming / ping-pong
;;; requests); resp-sizes: requested response sizes. status-code
;;; -1 = expect OK.

(provide interop-case-table)

(define interop-case-table
  '((empty EMPTY () () -1 "")
    (large-unary LARGE_UNARY (271828) (314159) -1 "")
    (client-streaming CLIENT_STREAMING (27182 8 1828 45904) () -1 "")
    (server-streaming SERVER_STREAMING () (31415 9 2653 58979) -1 "")
    (ping-pong PING_PONG (27182 8 1828 45904) (31415 9 2653 58979) -1 "")
    (empty-stream EMPTY_STREAM () () -1 "")
    (status-code-and-message STATUS_UNARY () () 2 "test status message")
    (status-code-and-message-duplex STATUS_DUPLEX () () 2 "test status message")
    (unimplemented-method UNIMPLEMENTED_METHOD () () 12 "")
    (unimplemented-service UNIMPLEMENTED_SERVICE () () 12 "")))
