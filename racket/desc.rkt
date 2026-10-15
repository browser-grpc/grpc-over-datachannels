#lang racket

;;; desc.rkt — recursive walk of a CodeGeneratorRequest into a plain model.
;;;
;;; The walk is structural recursion over descriptor.proto:
;;;   request -> proto_file[] -> service[] -> method[]
;;; Models are immutable hashes so both language templates can share them:
;;;   file:    #hash((name . str) (package . str) (services . (service ...)))
;;;   service: #hash((name . str) (full-name . str) (methods . (method ...)))
;;;   method:  #hash((name . str) (path . str) (input . str) (output . str)
;;;                  (kind . unary|client-streaming|server-streaming|bidi)
;;;                  (client-streaming . bool) (server-streaming . bool)
;;;                  (deprecated . bool))
;;;   service also carries (deprecated . bool). Deprecation comes from
;;;   the descriptor options (MethodOptions.deprecated=33,
;;;   ServiceOptions.deprecated=33) and is stamped by every template.
;;; Type names are the simple (last-segment) names: ".echo.EchoRequest"
;;; becomes "EchoRequest"; code generators refer messages to a per-language
;;; module (Rust `message_module`, JS `./<base>_pb.js`).

(require "pb.rkt" "spec.rkt")
(provide (all-defined-out))

(define (simple-type-name full)
  (define parts (string-split (string-trim full ".") "."))
  (last parts))

(define (method-path package service method)
  (if (and package (not (string=? package "")))
      (format "/~a.~a/~a" package service method)
      (format "/~a/~a" service method)))

;; options-deprecated : fields int -> bool
;; Reads field `options-field` (a submessage) and returns its
;; `deprecated` flag (field 33 in *Options messages).
(define (options-deprecated fields options-field)
  (define raw (pb-get fields options-field #f))
  (and raw (bytes? raw) (pb-get-bool (pb-parse raw) 33)))

;; MethodDescriptorProto: name=1 input_type=2 output_type=3 options=4
;;                        client_streaming=5 server_streaming=6
(define (parse-method fields package service-name)
  (define name (pb-get-string fields 1))
  (define client? (pb-get-bool fields 5))
  (define server? (pb-get-bool fields 6))
  (hasheq 'name name
          'path (method-path package service-name name)
          'input (simple-type-name (pb-get-string fields 2))
          'output (simple-type-name (pb-get-string fields 3))
          'kind (streaming-kind client? server?)
          'client-streaming client?
          'server-streaming server?
          'deprecated (options-deprecated fields 4)))

;; ServiceDescriptorProto: name=1 method=2 options=3
(define (parse-service fields package)
  (define name (pb-get-string fields 1))
  (hasheq 'name name
          'deprecated (options-deprecated fields 3)
          'full-name (if (and package (not (string=? package "")))
                         (format "~a.~a" package name)
                         name)
          'methods (for/list ([m (in-list (pb-get-all fields 2))])
                     (parse-method (pb-parse m) package name))))

;; FileDescriptorProto: name=1 package=2 service=6
(define (parse-file-desc fields)
  (define package (pb-get-string fields 2 ""))
  (hasheq 'name (pb-get-string fields 1)
          'package package
          'services (for/list ([s (in-list (pb-get-all fields 6))])
                      (parse-service (pb-parse s) package))))

;; CodeGeneratorRequest: file_to_generate=1 parameter=2 proto_file=15
;; -> (values (listof file-model) parameter-string)
(define (parse-request bstr)
  (define fields (pb-parse bstr))
  (define wanted (map (lambda (b) (bytes->string/utf-8 b)) (pb-get-all fields 1)))
  (define parameter (pb-get-string fields 2 ""))
  (define files
    (for/list ([f (in-list (pb-get-all fields 15))])
      (parse-file-desc (pb-parse f))))
  (define by-name (for/hash ([f (in-list files)]) (values (hash-ref f 'name) f)))
  (values (for/list ([w (in-list wanted)])
            (hash-ref by-name w
                      (lambda ()
                        (error 'parse-request "file_to_generate not in request: ~a" w))))
          parameter))

;; "message_module=crate::pb,pb_import=./echo_pb.js" -> #hash((sym . str))
(define (parse-parameters parameter)
  (for/hash ([part (in-list (string-split parameter #rx"[,:]"))]
             #:when (regexp-match? #rx"=" part))
    (define kv (string-split part "="))
    (values (string->symbol (first kv)) (second kv))))

;; CodeGeneratorResponse: error=1 supported_features=2 file=15(name=1 content=15)
(define (encode-response files)
  (apply bytes-append
         (pb-varint-field 2 1) ; FEATURE_PROTO3_OPTIONAL
         (for/list ([f (in-list files)])
           (pb-bytes-field 15 (bytes-append (pb-string-field 1 (car f))
                                            (pb-string-field 15 (cdr f)))))))

(define (encode-error-response message)
  (pb-string-field 1 message))


;; ---------------------------------------------------------------------------
;; Rename-alias method clones (version resilience)
;; ---------------------------------------------------------------------------
;; For every alias-table entry of a service, build two clones of the
;; target method model:
;;   client clone: name = alias, path = target path (source compat
;;                 for callers of the old name);
;;   server clone: name = alias, path = alias path, impl-name = target
;;                 (wire compat for clients of the old path).
;; Templates emit the clones next to the regular methods; emitters
;; that call into the service implementation must use
;; (method-impl-name m).

(define (method-impl-name m)
  (hash-ref m 'impl-name (hash-ref m 'name)))

(define (find-method svc name)
  (findf (lambda (m) (equal? (hash-ref m 'name) name)) (hash-ref svc 'methods)))

(define (alias-client-methods svc)
  (for/list ([a (in-list (method-aliases-for (hash-ref svc 'full-name)))]
             #:do [(define target (find-method svc (third a)))]
             #:when target)
    (hash-set target 'name (second a))))

(define (alias-server-methods svc)
  (define full (hash-ref svc 'full-name))
  (for/list ([a (in-list (method-aliases-for full))]
             #:do [(define target (find-method svc (third a)))]
             #:when target)
    (hash-set* target
               'name (second a)
               'path (format "/~a/~a" full (second a))
               'impl-name (hash-ref target 'name))))
