#lang racket

(require (for-syntax racket/syntax))

;;; spec.rkt — the single source of truth for the grpc-dc wire protocol.
;;;
;;; The frame-type table and the gRPC status-code table are written ONCE,
;;; here, as arguments to two recursive macros.  Each macro consumes one
;;; table entry per expansion step and stencils out:
;;;   * Racket constants (frame:HEADERS, status:UNAVAILABLE, ...),
;;;   * name<->code maps and validation helpers,
;;;   * the runtime table values consumed by metagen.rkt, which generates
;;;     the Rust constants, the JS constants and both protoc plugins.
;;;
;;; Identifiers are built with format-id from the macro *call site*, so the
;;; generated constants are ordinary module bindings that `provide` exports.

(provide frame:HEADERS frame:DATA frame:TRAILERS frame:HALF-CLOSE frame:RST
         frame-type->name frame-name->type valid-frame-type? frame-table
         status:OK status:CANCELLED status:UNKNOWN status:INVALID-ARGUMENT
         status:DEADLINE-EXCEEDED status:NOT-FOUND status:ALREADY-EXISTS
         status:PERMISSION-DENIED status:RESOURCE-EXHAUSTED
         status:FAILED-PRECONDITION status:ABORTED status:OUT-OF-RANGE
         status:UNIMPLEMENTED status:INTERNAL status:UNAVAILABLE
         status:DATA-LOSS status:UNAUTHENTICATED
         status-code->name status-name->code status-table
         define-frame-table define-status-table define-frame-constants
         define-status-constants streaming-kind)

;; ---------------------------------------------------------------------------
;; Recursive table macros
;; ---------------------------------------------------------------------------

;; One expansion step per entry: emits `frame:NAME = code`, then recurses on
;; the remaining entries.  The base case is the empty begin.
(define-syntax (define-frame-constants stx)
  (syntax-case stx ()
    [(_) #'(begin)]
    [(_ (name code doc) rest ...)
     (with-syntax ([const (format-id #'name "frame:~a" (syntax->datum #'name))])
       #'(begin (define const code)
                (define-frame-constants rest ...)))]))

(define-syntax (define-status-constants stx)
  (syntax-case stx ()
    [(_) #'(begin)]
    [(_ (name code) rest ...)
     (with-syntax ([const (format-id #'name "status:~a" (syntax->datum #'name))])
       #'(begin (define const code)
                (define-status-constants rest ...)))]))

;; Builds the constants, both lookup directions and the runtime table value
;; from one literal table at the call site.
(define-syntax (define-frame-table stx)
  (syntax-case stx ()
    [(_ (name code doc) ...)
     (with-syntax ([type->name (format-id stx "frame-type->name")]
                   [name->type (format-id stx "frame-name->type")]
                   [valid? (format-id stx "valid-frame-type?")]
                   [table (format-id stx "frame-table")])
       #'(begin
           (define-frame-constants (name code doc) ...)
           (define (type->name t)
             (cond [(= t code) 'name] ...
                   [else (error 'frame-type->name "unknown frame type: ~e" t)]))
           (define (name->type n)
             (cond [(eq? n 'name) code] ...
                   [else (error 'frame-name->type "unknown frame name: ~e" n)]))
           (define (valid? t)
             (and (exact-integer? t) (or (= t code) ...)))
           (define table '((name code doc) ...))))]))

(define-syntax (define-status-table stx)
  (syntax-case stx ()
    [(_ (name code) ...)
     (with-syntax ([code->name (format-id stx "status-code->name")]
                   [name->code (format-id stx "status-name->code")]
                   [table (format-id stx "status-table")])
       #'(begin
           (define-status-constants (name code) ...)
           (define (code->name c)
             (cond [(= c code) (symbol->string 'name)] ...
                   [else (error 'status-code->name "unknown status code: ~e" c)]))
           (define (name->code n)
             (cond [(equal? n (symbol->string 'name)) code] ...
                   [else #f]))
           (define table '((name code) ...))))]))

;; ---------------------------------------------------------------------------
;; The tables — written exactly once
;; ---------------------------------------------------------------------------

(define-frame-table
  (HEADERS    #x01 "call headers, JSON {path, metadata}")
  (DATA       #x02 "one serialized protobuf message")
  (TRAILERS   #x03 "terminal status, JSON {code, message}")
  (HALF-CLOSE #x04 "client finished sending")
  (RST        #x05 "abort stream, JSON {code, message}"))

(define-status-table
  (OK 0) (CANCELLED 1) (UNKNOWN 2) (INVALID-ARGUMENT 3) (DEADLINE-EXCEEDED 4)
  (NOT-FOUND 5) (ALREADY-EXISTS 6) (PERMISSION-DENIED 7) (RESOURCE-EXHAUSTED 8)
  (FAILED-PRECONDITION 9) (ABORTED 10) (OUT-OF-RANGE 11) (UNIMPLEMENTED 12)
  (INTERNAL 13) (UNAVAILABLE 14) (DATA-LOSS 15) (UNAUTHENTICATED 16))

;; ---------------------------------------------------------------------------
;; Rust enum emission shape — the static text of the generated
;; Rust enum codec, written once. Consumed by template-rust.rkt
;; (native plugin) and by webgen.rkt, which serializes the table
;; into the browser generators as RP_ENUM_SHAPE. A fix to the
;; enum shape (e.g. the Unknown(i32) round-trip) is made here
;; only; the webapp parity test byte-compares both sides.
;; Entries are format strings; the comment names the ~a fill-ins
;; in order.
;; ---------------------------------------------------------------------------

(define rust-enum-shape
  '((header . "#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]\n#[repr(i32)]\npub enum ~a {\n") ; enum name
    (defaultMark . "#[default]\n    ")
    (value . "    ~a~a = ~a,\n") ; defaultMark-or-empty, value name, number
    (unknownVariant . "    Unknown(i32),\n}\n\n")
    (implOpen . "impl ~a {\n    pub fn from_i32(v: i32) -> Self {\n        match v {\n") ; enum name
    (fromArm . "            ~a => ~a::~a,\n") ; number, enum name, value name
    (unknownFromArm . "            _ => ~a::Unknown(v),\n        }\n    }\n") ; enum name
    (toOpen . "    pub fn to_i32(self) -> i32 {\n        match self {\n")
    (toArm . "            ~a::~a => ~a,\n") ; enum name, value name, number
    (unknownToArm . "            ~a::Unknown(v) => v,\n        }\n    }\n}\n\n"))) ; enum name

(define (rust-enum-fragment key)
  (define entry (assq key rust-enum-shape))
  (unless entry (error 'rust-enum-fragment "unknown key: ~e" key))
  (cdr entry))

(provide rust-enum-shape rust-enum-fragment)

;; ---------------------------------------------------------------------------
;; Streaming-kind classification: (client-streaming?, server-streaming?)
;; ---------------------------------------------------------------------------

;; A macro (not a function) so protoc-plugin templates classify a method at
;; expansion time when the flags are literals, and at run time otherwise.
(define-syntax (streaming-kind stx)
  (syntax-case stx ()
    [(_ client? server?)
     #'(cond [(and client? server?) 'bidi]
             [client? 'client-streaming]
             [server? 'server-streaming]
             [else 'unary])]))


;; ---------------------------------------------------------------------------
;; Method rename aliases (version resilience)
;; ---------------------------------------------------------------------------
;; When a method is renamed, old clients keep calling the old path.
;; Each entry is (service-full-name alias-name target-name): generated
;; servers register BOTH /<service>/<target> and /<service>/<alias>
;; for the same handler, and generated clients gain an alias-named
;; method that calls the target path. The table ships empty; add an
;; entry in the same commit that renames a method. Templates read it
;; through current-method-aliases (a parameter so tests can bind
;; synthetic tables).

(define method-alias-table '())

(define current-method-aliases (make-parameter method-alias-table))

(define (method-aliases-for service-full-name)
  (for/list ([a (in-list (current-method-aliases))]
             #:when (equal? (first a) service-full-name))
    a))

(provide method-alias-table current-method-aliases method-aliases-for)
