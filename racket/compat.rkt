#lang racket

;;; compat.rkt — descriptor-set compatibility gate.
;;;
;;; Usage: racket racket/compat.rkt <baseline.bin> <current.bin>
;;;
;;; Compares two FileDescriptorSets (protoc --descriptor_set_out) and
;;; fails (exit 1) on wire- or API-breaking changes:
;;;   * file/package/message/service/method removed
;;;   * field removed without a covering `reserved` range or name
;;;   * field number reused for a different field, or renumbered
;;;   * field type or label (optional/repeated) changed
;;;   * field renamed (same number) — JSON/API breaking
;;;   * new field occupying a reserved number or name
;;;   * method input/output type or streaming shape changed
;;; Additive changes (new messages, fields, methods, services) pass.
;;; To accept a breaking change deliberately, refresh the baseline:
;;;   make update-baseline
;;;
;;; This is the CI gate that turns "additive evolution is safe" from a
;;; convention into a checked property of the schema.

(require "pb.rkt")
(provide descriptor-diff parse-file-model (struct-out field-info))

(struct field-info (name number type label) #:transparent)

;; ---------------------------------------------------------------------------
;; Descriptor model
;; ---------------------------------------------------------------------------

(define (parse-file-model bstr)
  (define top (pb-parse bstr))
  (define files (pb-get-all top 1))
  (unless (= (length files) 1)
    (error 'compat "expected exactly one file in descriptor set, got ~a" (length files)))
  (define f (pb-parse (first files)))
  (hash 'package (pb-get-string f 2 "")
          'messages
          (for/hash ([m (in-list (pb-get-all f 4))])
            (define-values (name model) (parse-message (pb-parse m) ""))
            (values name model))
          'services
          (for/hash ([s (in-list (pb-get-all f 6))])
            (define-values (name model) (parse-service (pb-parse s)))
            (values name model))))

(define (parse-message fields prefix)
  (define name (pb-get-string fields 1 ""))
  (define full (if (string=? prefix "") name (string-append prefix "." name)))
  (define infos
    (for/hash ([fd (in-list (pb-get-all fields 2))])
      (define d (pb-parse fd))
      (define info
        (field-info (pb-get-string d 1 "")
                    (pb-get d 3 0)
                    (pb-get d 5 0)
                    (pb-get d 4 1)))
      (values (field-info-number info) info)))
  (define reserved-ranges
    (for/list ([r (in-list (pb-get-all fields 9))])
      (define d (pb-parse r))
      ;; DescriptorProto.ReservedRange: start=1, end=2 (exclusive)
      (cons (pb-get d 1 0) (pb-get d 2 0))))
  (define reserved-names
    (for/list ([n (in-list (pb-get-all fields 10))])
      (bytes->string/utf-8 n)))
  (define nested
    (for/hash ([n (in-list (pb-get-all fields 3))])
      (define-values (nested-name model) (parse-message (pb-parse n) full))
      (values nested-name model)))
  (values full
          (hash 'fields infos
                  'reserved-ranges reserved-ranges
                  'reserved-names reserved-names
                  'nested nested)))

(define (parse-service fields)
  (define name (pb-get-string fields 1 ""))
  (define methods
    (for/hash ([m (in-list (pb-get-all fields 2))])
      (define d (pb-parse m))
      (values (pb-get-string d 1 "")
              (hash 'input (pb-get-string d 2 "")
                      'output (pb-get-string d 3 "")
                      'client-streaming (pb-get-bool d 5)
                      'server-streaming (pb-get-bool d 6)))))
  (values name (hash 'methods methods)))

;; ---------------------------------------------------------------------------
;; Diff
;; ---------------------------------------------------------------------------

(define (reserved-covers? model number name)
  (or (for/or ([r (in-list (hash-ref model 'reserved-ranges))])
        (and (>= number (car r)) (< number (cdr r))))
      (member name (hash-ref model 'reserved-names))))

(define (type-name t)
  (case t
    [(1) "double"] [(2) "float"] [(3) "int64"] [(4) "uint64"] [(5) "int32"]
    [(6) "fixed64"] [(7) "fixed32"] [(8) "bool"] [(9) "string"] [(10) "group"]
    [(11) "message"] [(12) "bytes"] [(13) "uint32"] [(14) "enum"]
    [(15) "sfixed32"] [(16) "sfixed64"] [(17) "sint32"] [(18) "sint64"]
    [else (format "type-~a" t)]))

(define (diff-messages old new prefix)
  (append
   (for/list ([(name old-model) (in-hash old)]
              #:unless (hash-has-key? new name))
     (format "BREAKING: message ~a~a removed" prefix name))
   (append-map
    (lambda (name)
      (define old-model (hash-ref old name))
      (define new-model (hash-ref new name))
      (append (diff-fields name old-model new-model)
              (diff-messages (hash-ref old-model 'nested)
                             (hash-ref new-model 'nested)
                             (string-append prefix name "."))))
    (filter (lambda (name) (hash-has-key? new name)) (hash-keys old)))))

(define (diff-fields msg-name old-model new-model)
  (define old-fields (hash-ref old-model 'fields))
  (define new-fields (hash-ref new-model 'fields))
  (append
   ;; removed fields
   (for/list ([(num old-info) (in-hash old-fields)]
              #:unless (hash-has-key? new-fields num))
     (if (reserved-covers? new-model num (field-info-name old-info))
         #f
         (format "BREAKING: field ~a.~a (number ~a) removed without a reserved range/name"
                 msg-name (field-info-name old-info) num)))
   ;; changed fields
   (append-map
    (lambda (num)
      (define old-info (hash-ref old-fields num))
      (define new-info (hash-ref new-fields num))
      (append
       (if (equal? (field-info-name old-info) (field-info-name new-info))
           '()
           (list (format "BREAKING: field ~a number ~a renamed ~a -> ~a"
                         msg-name num (field-info-name old-info) (field-info-name new-info))))
       (if (= (field-info-type old-info) (field-info-type new-info))
           '()
           (list (format "BREAKING: field ~a.~a type changed ~a -> ~a"
                         msg-name (field-info-name old-info)
                         (type-name (field-info-type old-info)) (type-name (field-info-type new-info)))))
       (if (= (field-info-label old-info) (field-info-label new-info))
           '()
           (list (format "BREAKING: field ~a.~a label changed ~a -> ~a"
                         msg-name (field-info-name old-info)
                         (field-info-label old-info) (field-info-label new-info))))))
    (filter (lambda (num) (hash-has-key? new-fields num)) (hash-keys old-fields)))
   ;; added fields must not squat on reserved slots/names
   (for/list ([(num new-info) (in-hash new-fields)]
              #:unless (hash-has-key? old-fields num))
     (if (reserved-covers? old-model num (field-info-name new-info))
         (format "BREAKING: field ~a.~a (number ~a) added on a reserved number/name"
                 msg-name (field-info-name new-info) num)
         #f))))

(define (diff-services old new)
  (append
   (for/list ([(name _m) (in-hash old)]
              #:unless (hash-has-key? new name))
     (format "BREAKING: service ~a removed" name))
   (append-map
    (lambda (name)
      (define old-methods (hash-ref (hash-ref old name) 'methods))
      (define new-methods (hash-ref (hash-ref new name) 'methods))
      (append
       (for/list ([(mname _mm) (in-hash old-methods)]
                  #:unless (hash-has-key? new-methods mname))
         (format "BREAKING: method ~a.~a removed" name mname))
       (append-map
        (lambda (mname)
          (define o (hash-ref old-methods mname))
          (define n (hash-ref new-methods mname))
          (append
           (if (equal? (hash-ref o 'input) (hash-ref n 'input))
               '()
               (list (format "BREAKING: method ~a.~a input type changed ~a -> ~a"
                             name mname (hash-ref o 'input) (hash-ref n 'input))))
           (if (equal? (hash-ref o 'output) (hash-ref n 'output))
               '()
               (list (format "BREAKING: method ~a.~a output type changed ~a -> ~a"
                             name mname (hash-ref o 'output) (hash-ref n 'output))))
           (if (and (equal? (hash-ref o 'client-streaming) (hash-ref n 'client-streaming))
                    (equal? (hash-ref o 'server-streaming) (hash-ref n 'server-streaming)))
               '()
               (list (format "BREAKING: method ~a.~a streaming shape changed" name mname)))))
        (filter (lambda (m) (hash-has-key? new-methods m)) (hash-keys old-methods)))))
    (filter (lambda (name) (hash-has-key? new name)) (hash-keys old)))))

;; descriptor-diff : bytes bytes -> (listof string) of BREAKING lines.
(define (descriptor-diff old-bytes new-bytes)
  (define old (parse-file-model old-bytes))
  (define new (parse-file-model new-bytes))
  (filter
   values
   (append
    (if (equal? (hash-ref old 'package) (hash-ref new 'package))
        '()
        (list (format "BREAKING: package changed ~a -> ~a"
                      (hash-ref old 'package) (hash-ref new 'package))))
    (diff-messages (hash-ref old 'messages) (hash-ref new 'messages) "")
    (diff-services (hash-ref old 'services) (hash-ref new 'services)))))

(module+ main
  (define args (current-command-line-arguments))
  (unless (= (vector-length args) 2)
    (eprintf "usage: racket racket/compat.rkt <baseline.bin> <current.bin>\n")
    (exit 2))
  (define old (file->bytes (vector-ref args 0)))
  (define new (file->bytes (vector-ref args 1)))
  (define findings (descriptor-diff old new))
  (for ([f (in-list findings)]) (printf "~a\n" f))
  (if (null? findings)
      (printf "compat: OK (no breaking changes)\n")
      (begin
        (printf "compat: ~a breaking change(s); accept deliberately via `make update-baseline`\n"
                (length findings))
        (exit 1))))
