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
          'input-full (string-trim (pb-get-string fields 2) ".")
          'output-full (string-trim (pb-get-string fields 3) ".")
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

;; EnumDescriptorProto: name=1 value=2 (EnumValueDescriptorProto:
;; name=1 number=2)
(define (parse-enum-desc fields)
  (hasheq 'name (pb-get-string fields 1)
          'values (for/list ([v (in-list (pb-get-all fields 2))])
                    (define vf (pb-parse v))
                    (hasheq 'name (pb-get-string vf 1)
                            'number (pb-get vf 2 0)))))

;; FieldDescriptorProto: name=1 extendee=2 number=3 label=4 type=5
;; type_name=6 default_value=7 oneof_index=9 json_name=10. Label:
;; 1 optional, 2 required, 3 repeated. Type codes match
;; descriptor.proto (1 double .. 18 sint64); the message generators
;; (template-pb-*.rkt, webgen.rkt) share them. `default` is the
;; descriptor's default_value string (proto2 explicit defaults),
;; #f when absent; `oneof-index` is #f for non-oneof fields.
(define (parse-field-desc fields)
  (hasheq 'name (pb-get-string fields 1)
          'extendee (string-trim (pb-get-string fields 2 "") ".")
          'number (pb-get fields 3 0)
          'label (pb-get fields 4 1)
          'type (pb-get fields 5 0)
          'type-name (string-trim (pb-get-string fields 6 "") ".")
          'default (pb-get-string fields 7 #f)
          'oneof-index (pb-get fields 9 #f)
          'json-name (pb-get-string fields 10 "")))

;; DescriptorProto: name=1 field=2 nested_type=3 enum_type=4
;; extension=6 options=7 (MessageOptions.map_entry=7) oneof_decl=8
;; (OneofDescriptorProto: name=1)
(define (parse-message-desc fields prefix)
  (define name (pb-get-string fields 1))
  (define full (if (string=? prefix "") name (format "~a.~a" prefix name)))
  (define opts (pb-get fields 7 #f))
  (hasheq 'name name
          'full-name full
          'fields (for/list ([f (in-list (pb-get-all fields 2))])
                    (parse-field-desc (pb-parse f)))
          'nested (for/list ([n (in-list (pb-get-all fields 3))])
                    (parse-message-desc (pb-parse n) full))
          'enums (for/list ([e (in-list (pb-get-all fields 4))])
                   (parse-enum-desc (pb-parse e)))
          'extensions (for/list ([f (in-list (pb-get-all fields 6))])
                        (parse-field-desc (pb-parse f)))
          'oneofs (for/list ([o (in-list (pb-get-all fields 8))])
                    (pb-get-string (pb-parse o) 1))
          'map-entry (and (bytes? opts) (pb-get-bool (pb-parse opts) 7))))

;; FileDescriptorProto: name=1 package=2 dependency=3
;; message_type=4 enum_type=5 service=6 extension=7 syntax=12
(define (parse-file-desc fields)
  (define package (pb-get-string fields 2 ""))
  (hasheq 'name (pb-get-string fields 1)
          'package package
          'syntax (pb-get-string fields 12 "")
          'dependencies (for/list ([d (in-list (pb-get-all fields 3))])
                          (bytes->string/utf-8 d))
          'services (for/list ([s (in-list (pb-get-all fields 6))])
                      (parse-service (pb-parse s) package))
          'messages (for/list ([m (in-list (pb-get-all fields 4))])
                      (parse-message-desc (pb-parse m) package))
          'enums (for/list ([e (in-list (pb-get-all fields 5))])
                   (parse-enum-desc (pb-parse e)))
          'extensions (for/list ([f (in-list (pb-get-all fields 7))])
                        (parse-field-desc (pb-parse f)))))

;; Extension fields (extend blocks) are merged into their extendee
;; message's field list, so every message generator emits them as
;; ordinary fields (wire-correct by field number) without knowing
;; about extensions at all. Extendees outside the request are
;; dropped: their bytes stay unknown fields on the wire.
(define (merge-extensions files)
  (define exts
    (append
     (append-map (lambda (f) (hash-ref f 'extensions)) files)
     (let loop ([msgs (append-map (lambda (f) (hash-ref f 'messages)) files)])
       (if (null? msgs)
           '()
           (append (append-map (lambda (m) (hash-ref m 'extensions)) msgs)
                   (loop (append-map (lambda (m) (hash-ref m 'nested)) msgs)))))))
  (define (add-to msg ext)
    (if (equal? (hash-ref msg 'full-name) (hash-ref ext 'extendee))
        (hash-set msg 'fields (append (hash-ref msg 'fields) (list ext)))
        (hash-set msg 'nested
                  (map (lambda (n) (add-to n ext)) (hash-ref msg 'nested)))))
  (for/fold ([fs files]) ([ext (in-list exts)])
    (map (lambda (f)
           (hash-set f 'messages
                     (map (lambda (m) (add-to m ext)) (hash-ref f 'messages))))
         fs)))

;; The descriptor's explicit (proto2) default for a singular scalar
;; or enum field, as a string; #f for repeated/message/bytes/group
;; fields and when no default was declared. Message generators turn
;; this into their language's literal (see *-pb-default emitters).
(define (field-explicit-default f)
  (and (hash-ref f 'default #f)
       (not (= (hash-ref f 'label 1) 3))
       (not (memv (hash-ref f 'type) '(10 11 12)))
       (hash-ref f 'default)))

;; The numeric value of a field's explicit enum default (the
;; descriptor stores the value *name*), or #f.
(define (enum-default-number model f)
  (define types (and (hash-has-key? model 'types) (hash-ref model 'types)))
  (define entry (and types (hash-ref types (hash-ref f 'type-name) #f)))
  (define e (and entry (hash-ref entry 'enum #f)))
  (define v (and e (findf (lambda (x) (equal? (hash-ref x 'name) (hash-ref f 'default)))
                          (hash-ref e 'values))))
  (and v (hash-ref v 'number)))

;; Global type registry across every file in the request, so the
;; message generators can resolve field types across imports.
;; Maps full type name -> #hash((kind . message|map|enum)
;; (msg . message-model|#f) (enum . enum-model|#f) (file . str)
;; (pkg . str)).
(define (build-type-registry files)
  (define reg (make-hash))
  (define (reg-msg file pkg msg)
    (hash-set! reg (hash-ref msg 'full-name)
               (hasheq 'kind (if (hash-ref msg 'map-entry) 'map 'message)
                       'msg msg 'enum #f 'file file 'pkg pkg))
    (for ([n (in-list (hash-ref msg 'nested))]) (reg-msg file pkg n))
    (for ([e (in-list (hash-ref msg 'enums))])
      (hash-set! reg (format "~a.~a" (hash-ref msg 'full-name) (hash-ref e 'name))
                 (hasheq 'kind 'enum 'msg #f 'enum e 'file file 'pkg pkg))))
  (for ([f (in-list files)])
    (define pkg (hash-ref f 'package))
    (for ([m (in-list (hash-ref f 'messages))]) (reg-msg (hash-ref f 'name) pkg m))
    (for ([e (in-list (hash-ref f 'enums))])
      (hash-set! reg (if (string=? pkg "") (hash-ref e 'name) (format "~a.~a" pkg (hash-ref e 'name)))
                 (hasheq 'kind 'enum 'msg #f 'enum e 'file (hash-ref f 'name) 'pkg pkg))))
  reg)

;; CodeGeneratorRequest: file_to_generate=1 parameter=2 proto_file=15
;; -> (values (listof file-model) parameter-string)
;; Each returned file-model carries a 'types registry (above).
(define (parse-request bstr)
  (define fields (pb-parse bstr))
  (define wanted (map (lambda (b) (bytes->string/utf-8 b)) (pb-get-all fields 1)))
  (define parameter (pb-get-string fields 2 ""))
  (define files
    (merge-extensions
     (for/list ([f (in-list (pb-get-all fields 15))])
       (parse-file-desc (pb-parse f)))))
  (define by-name (for/hash ([f (in-list files)]) (values (hash-ref f 'name) f)))
  (define registry (build-type-registry files))
  (values (for/list ([w (in-list wanted)])
            (hash-set (hash-ref by-name w
                                (lambda ()
                                  (error 'parse-request "file_to_generate not in request: ~a" w)))
                      'types registry))
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

;; Stamp the generated-output grant (GENERATED-CODE-LICENSE.md) as
;; the first line of every plugin output file, using the target
;; language's line-comment syntax (chosen by file extension).
(define (stamp-generated-header file-pair)
  (define prefix
    (cond [(or (string-suffix? (car file-pair) ".py")
               (string-suffix? (car file-pair) ".rb")) "#"]
          [(string-suffix? (car file-pair) ".lua") "--"]
          [else "//"]))
  (if (string-suffix? (car file-pair) ".php")
      ;; PHP: <?php must be the first bytes; stamp after it.
      (cons (car file-pair)
            (string-append "<?php\n"
                           prefix
                           " Generated code: use without restriction (see GENERATED-CODE-LICENSE.md).\n"
                           (substring (cdr file-pair) (string-length "<?php\n"))))
      (cons (car file-pair)
            (string-append prefix
                           " Generated code: use without restriction (see GENERATED-CODE-LICENSE.md).\n"
                           (cdr file-pair)))))


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
