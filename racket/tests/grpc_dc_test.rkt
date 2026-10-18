#lang racket

;;; Tests for the metaprogram layer: macro-generated tables, the protobuf
;;; wire codec, the frame codec (against fixtures/vectors.json, the same
;;; golden bytes the Rust and JS tests consume), and descriptor parsing.

(require rackunit json racket/runtime-path
         "../spec.rkt" "../pb.rkt" "../desc.rkt")

(define-runtime-path vectors-path "../../fixtures/vectors.json")
(define vectors (call-with-input-file vectors-path read-json))
(define frames (hash-ref vectors 'frames))

;; --- macro-generated tables ------------------------------------------------
(check-equal? frame:HEADERS 1)
(check-equal? frame:HALF-CLOSE 4)
(check-equal? (frame-type->name frame:RST) 'RST)
(check-equal? (frame-name->type 'TRAILERS) 3)
(check-true (valid-frame-type? 5))
(check-false (valid-frame-type? 6))
(check-exn exn:fail? (lambda () (frame-type->name 99)))
(check-equal? status:UNAUTHENTICATED 16)
(check-equal? (status-code->name 12) "UNIMPLEMENTED")
(check-equal? (status-name->code "DATA-LOSS") 15)
(check-equal? (length status-table) 17)
(check-equal? (streaming-kind #f #f) 'unary)
(check-equal? (streaming-kind #t #f) 'client-streaming)
(check-equal? (streaming-kind #f #t) 'server-streaming)
(check-equal? (streaming-kind #t #t) 'bidi)

;; --- frame codec vs golden vectors -----------------------------------------
(for ([f (in-list frames)])
  (define payload (if (hash-has-key? f 'payload_utf8)
                      (string->bytes/utf-8 (hash-ref f 'payload_utf8))
                      (hex->bytes (hash-ref f 'payload_hex))))
  (check-equal? (bytes->hex (encode-frame (hash-ref f 'type) (hash-ref f 'stream) payload))
                (hash-ref f 'hex)
                (format "encode ~a" (hash-ref f 'name)))
  (define-values (t id p) (decode-frame (hex->bytes (hash-ref f 'hex))))
  (check-equal? t (hash-ref f 'type))
  (check-equal? id (hash-ref f 'stream))
  (check-equal? p payload))
(check-exn exn:fail? (lambda () (decode-frame #"short")))
(check-exn exn:fail? (lambda () (encode-frame 99 1 #"")))

;; --- protobuf wire codec ----------------------------------------------------
(define sample
  (bytes-append (pb-string-field 1 "echo.proto")
                (pb-varint-field 7 300)
                (pb-bytes-field 15 (pb-string-field 1 "nested"))))
(define parsed (pb-parse sample))
(check-equal? (pb-get-string parsed 1) "echo.proto")
(check-equal? (pb-get parsed 7) 300)
(check-equal? (pb-get-string (pb-parse (pb-get parsed 15)) 1) "nested")

;; --- descriptor walk on a hand-built CodeGeneratorRequest -------------------
;; Minimal FileDescriptorProto for package "echo", service "S", one
;; server-streaming method "M" — encoded with the same pb writers the
;; plugins use to answer protoc.
(define method-desc
  (bytes-append (pb-string-field 1 "M")
                (pb-string-field 2 ".echo.Req")
                (pb-string-field 3 ".echo.Resp")
                (pb-varint-field 6 1)))
(define service-desc
  (bytes-append (pb-string-field 1 "S") (pb-bytes-field 2 method-desc)))
(define file-desc
  (bytes-append (pb-string-field 1 "x.proto")
                (pb-string-field 2 "echo")
                (pb-bytes-field 6 service-desc)))
(define request
  (bytes-append (pb-string-field 1 "x.proto") (pb-bytes-field 15 file-desc)))
(define-values (files _param) (parse-request request))
(check-equal? (length files) 1)
(define svc (first (hash-ref (first files) 'services)))
(check-equal? (hash-ref svc 'full-name) "echo.S")
(define m (first (hash-ref svc 'methods)))
(check-equal? (hash-ref m 'path) "/echo.S/M")
(check-equal? (hash-ref m 'kind) 'server-streaming)
(check-equal? (hash-ref m 'input) "Req")
(check-equal? (hash-ref m 'output) "Resp")

;; --- descriptor features: oneofs, proto2 defaults, syntax, extensions -------
;; Hand-built proto2 file: message Msg with an optional field carrying
;; an explicit default, a oneof, and an in-file extension merged in.
(define feat-field
  (bytes-append (pb-string-field 1 "count")
                (pb-varint-field 3 2)
                (pb-varint-field 4 1)
                (pb-varint-field 5 5)
                (pb-string-field 7 "42")))
(define feat-oneof-field
  (bytes-append (pb-string-field 1 "text")
                (pb-varint-field 3 3)
                (pb-varint-field 4 1)
                (pb-varint-field 5 9)
                (pb-varint-field 9 0)))
(define feat-ext-field
  (bytes-append (pb-string-field 1 "ext_note")
                (pb-string-field 2 ".feat.Msg")
                (pb-varint-field 3 100)
                (pb-varint-field 4 1)
                (pb-varint-field 5 9)))
(define feat-msg
  (bytes-append (pb-string-field 1 "Msg")
                (pb-bytes-field 2 feat-field)
                (pb-bytes-field 2 feat-oneof-field)
                (pb-bytes-field 8 (pb-string-field 1 "choice"))))
(define feat-file
  (bytes-append (pb-string-field 1 "feat.proto")
                (pb-string-field 2 "feat")
                (pb-string-field 12 "proto2")
                (pb-bytes-field 4 feat-msg)
                (pb-bytes-field 7 feat-ext-field)))
(define feat-request
  (bytes-append (pb-string-field 1 "feat.proto") (pb-bytes-field 15 feat-file)))
(define-values (feat-files _feat-param) (parse-request feat-request))
(define feat-model (first feat-files))
(check-equal? (hash-ref feat-model 'syntax) "proto2")
(define feat-msg-model (first (hash-ref feat-model 'messages)))
(check-equal? (hash-ref feat-msg-model 'oneofs) '("choice"))
(define feat-fields (hash-ref feat-msg-model 'fields))
(check-equal? (map (lambda (f) (hash-ref f 'name)) feat-fields)
              '("count" "text" "ext_note"))
(check-equal? (hash-ref (first feat-fields) 'default) "42")
(check-equal? (field-explicit-default (first feat-fields)) "42")
(check-equal? (hash-ref (second feat-fields) 'oneof-index) 0)
(check-false (field-explicit-default (second feat-fields)))

;; Response encoding parses back: error field and supported features.
(define resp-fields (pb-parse (encode-response (list (cons "out.rs" "body")))))
(check-equal? (pb-get resp-fields 2) 1)
(define out-file (pb-parse (pb-get resp-fields 15)))
(check-equal? (pb-get-string out-file 1) "out.rs")
(check-equal? (pb-get-string out-file 15) "body")
(check-equal? (pb-get-string (pb-parse (encode-error-response "boom")) 1) "boom")

(displayln "grpc_dc_test: all checks passed")
