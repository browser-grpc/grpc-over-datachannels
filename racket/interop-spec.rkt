#lang racket

;;; interop-spec.rkt — the canonical grpc interop case table
;;; (grpc.testing.TestService, semantics mirroring upstream
;;; AbstractInteropTest) as data. Emitters in interop-gen.rkt
;;; stamp this table per language; runners interpret it. Case
;;; kinds: EMPTY, LARGE_UNARY, CLIENT_STREAMING, SERVER_STREAMING,
;;; PING_PONG, EMPTY_STREAM, STATUS_UNARY, STATUS_DUPLEX,
;;; UNIMPLEMENTED_METHOD, UNIMPLEMENTED_SERVICE,
;;; SPECIAL_STATUS (status unary whose message carries leading /
;;; trailing whitespace and non-BMP unicode), CANCEL_AFTER_BEGIN
;;; (client-streaming call cancelled before any request),
;;; CANCEL_AFTER_FIRST (duplex call cancelled after the first
;;; response; resp-sizes holds the first response size — duplex
;;; keeps the call open because the server waits for more input,
;;; so the cancel cannot race call completion), TIMEOUT_SLEEPING
;;; (server-streaming call against 1 s response intervals with a
;;; 100 ms deadline; resp-sizes are the requested sizes).
;;;
;;; Row: (name kind req-sizes resp-sizes status-code status-message)
;;; req-sizes: request payload sizes (client-streaming / ping-pong
;;; requests); resp-sizes: requested response sizes. status-code
;;; -1 = expect OK.

(provide interop-case-table interop-service-methods)

(define interop-case-table
  '((empty EMPTY () () -1 "")
    (large-unary LARGE_UNARY (271828) (314159) -1 "")
    (client-streaming CLIENT_STREAMING (27182 8 1828 45904) () -1 "")
    (server-streaming SERVER_STREAMING () (31415 9 2653 58979) -1 "")
    (ping-pong PING_PONG (27182 8 1828 45904) (31415 9 2653 58979) -1 "")
    (empty-stream EMPTY_STREAM () () -1 "")
    (custom-metadata CUSTOM_METADATA () () -1 "")
    (status-code-and-message STATUS_UNARY () () 2 "test status message")
    (status-code-and-message-duplex STATUS_DUPLEX () () 2 "test status message")
    (unimplemented-method UNIMPLEMENTED_METHOD () () 12 "")
    (unimplemented-service UNIMPLEMENTED_SERVICE () () 12 "")
    (special-status-message SPECIAL_STATUS () () 2 "\t\ntest with whitespace\r\nand Unicode BMP ☺ and non-BMP 😈\t\n")
    (cancel-after-begin CANCEL_AFTER_BEGIN () () 1 "")
    (cancel-after-first-response CANCEL_AFTER_FIRST () (31415) 1 "")
    (timeout-on-sleeping-server TIMEOUT_SLEEPING () (1 1 1) 4 "")))

;;; grpc.testing TestService behavior, shared by the generated
;;; implementations (interop-service-gen.rkt; INTEROP-GEN-SPEC.md).
;;; Row: (method kind behavior). Kinds follow the generated
;;; stubs; behavior names the shared rule the emitters stamp.
;;; UnimplementedCall is deliberately in the table (the impl
;;; raises UNIMPLEMENTED itself, matching the reference).
(define interop-service-methods
  '((EmptyCall unary empty)
    (UnaryCall unary sized-with-status-and-orca)
    (CacheableUnaryCall unary echo-payload)
    (StreamingOutputCall server-streaming response-parameters)
    (StreamingInputCall client-streaming aggregate-payload-size)
    (FullDuplexCall bidi per-request-response-parameters-and-orca-oob)
    (HalfDuplexCall bidi collect-then-response-parameters)
    (UnimplementedCall unary raise-unimplemented)))
