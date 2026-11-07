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
         define-status-constants streaming-kind
         tracing-beta-enabled tracing-beta-suffix apply-tracing-beta)

;; ---------------------------------------------------------------------------
;; Tracing beta designation. The tracing surface (runtime hooks,
;; propagation, generated docs) is beta: generated tracing text
;; carries the token @@TRACING_BETA@@, which the generator writers
;; (metagen/desc/coverage-docs) replace with tracing-beta-suffix.
;; To end the beta, set tracing-beta-enabled to #f (labels vanish)
;; or remove the token and these helpers.
(define tracing-beta-enabled #t)

(define (tracing-beta-suffix)
  (if tracing-beta-enabled " (beta)" ""))

(define (apply-tracing-beta text)
  (string-replace text "@@TRACING_BETA@@" (tracing-beta-suffix)))

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
;; Go module paths — the published import prefixes for the Go
;; runtime and the WebRTC stack (pkg.go.dev-resolvable), written
;; once. template-go.rkt, the eventbus/oracle Go emitters and
;; webgen.rkt (which serializes the path for the browser Go
;; emitter) format these in; the go.mod files carry the same
;; strings. See GO-MODULE-PATH-SPEC.md.
;; ---------------------------------------------------------------------------

(define go-module-path "github.com/browser-grpc/grpc-over-datachannels/go")
(define go-webrtc-module-path "github.com/browser-grpc/grpc-over-datachannels/webrtc/go")

(provide go-module-path go-webrtc-module-path)

;; ---------------------------------------------------------------------------
;; Protobuf scalar wire tables — written once, consumed by
;; every language template and serialized by webgen.rkt into
;; the browser generators (WEBGEN-SINGLESOURCE-SPEC option 2).
;;
;; varint-scalar-types: field-type numbers carried as varints
;; (int32 int64 uint32 uint64 sint32 sint64 bool enum).
;;
;; fixed-scalar-tables: per language, (type-number byte-size
;; type-name) for the fixed-width scalar types (float double
;; fixed32 sfixed32 fixed64 sfixed64); type-name is the token
;; the language's generated codec uses (a Rust primitive, a
;; DataView accessor suffix, a struct/pack format, ...).
;; Templates derive their local tables from these (Rust and
;; Scala map the name back to a symbol for case dispatch).
;; ---------------------------------------------------------------------------

(define varint-scalar-types '(5 3 13 4 17 18 8 14))

(define fixed-scalar-tables
  '((js     (2 4 "Float32") (1 8 "Float64") (7 4 "Uint32") (15 4 "Int32") (6 8 "BigUint64") (16 8 "BigInt64"))
    (go     (2 4 "Float32") (1 8 "Float64") (7 4 "Uint32") (15 4 "Int32") (6 8 "BigUint64") (16 8 "BigInt64"))
    (python (2 4 "<f") (1 8 "<d") (7 4 "<I") (15 4 "<i") (6 8 "<Q") (16 8 "<q"))
    (c      (2 4 "f32") (1 8 "f64") (7 4 "u32") (15 4 "i32") (6 8 "u64") (16 8 "i64"))
    (rust   (1 8 "f64") (2 4 "f32") (6 8 "u64") (7 4 "u32") (15 4 "i32") (16 8 "i64"))
    (java   (2 4 "Float") (1 8 "Double") (7 4 "Int") (15 4 "Int") (6 8 "Long") (16 8 "Long"))
    (csharp (2 4 "Float") (1 8 "Double") (7 4 "Int") (15 4 "Int") (6 8 "Long") (16 8 "Long"))
    (cpp    (2 4 "Float") (1 8 "Double") (7 4 "Int32") (15 4 "Int32") (6 8 "Int64") (16 8 "Int64"))
    (swift  (2 4 "Float") (1 8 "Double") (7 4 "UInt32") (15 4 "Int32") (6 8 "UInt64") (16 8 "Int64"))
    (kotlin (2 4 "Float") (1 8 "Double") (7 4 "UInt") (15 4 "Int") (6 8 "ULong") (16 8 "Long"))
    (dart   (2 4 "Float32") (1 8 "Float64") (7 4 "Uint32") (15 4 "Int32") (6 8 "Uint64") (16 8 "Int64"))
    (zig    (2 4 "f32") (1 8 "f64") (7 4 "u32") (15 4 "i32") (6 8 "u64") (16 8 "i64"))
    (lua    (2 4 "f") (1 8 "d") (7 4 "I4") (15 4 "i4") (6 8 "I8") (16 8 "i8"))
    (ruby   (2 4 "e") (1 8 "E") (7 4 "V") (15 4 "l<") (6 8 "Q<") (16 8 "q<"))
    (php    (2 4 "g") (1 8 "e") (7 4 "V") (15 4 "V") (6 8 "P") (16 8 "P"))
    (scala  (1 8 "double") (2 4 "float") (6 8 "fixed64") (7 4 "fixed32") (15 4 "fixed32") (16 8 "fixed64"))))

(define (fixed-scalar-table lang)
  (define entry (assq lang fixed-scalar-tables))
  (unless entry (error 'fixed-scalar-table "unknown language: ~e" lang))
  (cdr entry))

(provide varint-scalar-types fixed-scalar-tables fixed-scalar-table)

;; ---------------------------------------------------------------------------
;; Scalar type tables — the leaf type mapping of every typed
;; language's generated message codec, written once: per
;; language, the default leaf value plus (type-number .
;; payload) entries, where the payload is exactly what the
;; language's scalar leaf returns (a type name, or a list
;; such as (primitive boxed default)). Dynamic languages
;; (JS, Python, Lua, Ruby, PHP) have no scalar type names
;; and are not listed. Templates derive their
;; <lang>-pb-scalar leaves from these; webgen.rkt serializes
;; them into the browser generators as SCALAR_TABLES.
;; ---------------------------------------------------------------------------

(define scalar-type-tables
  '((go #f
     (1 . "float64")
     (2 . "float32")
     (3 . "int64")
     (4 . "uint64")
     (5 . "int32")
     (6 . "uint64")
     (7 . "uint32")
     (8 . "bool")
     (9 . "string")
     (12 . "[]byte")
     (13 . "uint32")
     (15 . "int32")
     (16 . "int64")
     (17 . "int32")
     (18 . "int64"))
    (rust "i32"
     (1 . "f64")
     (2 . "f32")
     (3 . "i64-or-u64")
     (4 . "i64-or-u64")
     (6 . "i64-or-u64")
     (8 . "bool")
     (9 . "String")
     (12 . "Vec<u8>")
     (16 . "i64-or-u64")
     (18 . "i64-or-u64"))
    (scala "Int"
     (1 . "Double")
     (2 . "Float")
     (3 . "Long")
     (4 . "Long")
     (6 . "Long")
     (8 . "Boolean")
     (9 . "String")
     (12 . "Array[Byte]")
     (16 . "Long")
     (18 . "Long"))
    (java #f
     (1 . ("double" "Double" "0"))
     (2 . ("float" "Float" "0"))
     (3 . ("long" "Long" "0L"))
     (4 . ("long" "Long" "0L"))
     (5 . ("int" "Integer" "0"))
     (6 . ("long" "Long" "0L"))
     (7 . ("int" "Integer" "0"))
     (8 . ("boolean" "Boolean" "false"))
     (9 . ("String" "String" "\"\""))
     (12 . ("byte[]" "byte[]" "new byte[0]"))
     (13 . ("int" "Integer" "0"))
     (15 . ("int" "Integer" "0"))
     (16 . ("long" "Long" "0L"))
     (17 . ("int" "Integer" "0"))
     (18 . ("long" "Long" "0L")))
    (csharp #f
     (1 . ("double" "0"))
     (2 . ("float" "0"))
     (3 . ("long" "0"))
     (4 . ("ulong" "0"))
     (5 . ("int" "0"))
     (6 . ("ulong" "0"))
     (7 . ("uint" "0"))
     (8 . ("bool" "false"))
     (9 . ("string" "\"\""))
     (12 . ("byte[]" "new byte[0]"))
     (13 . ("uint" "0"))
     (15 . ("int" "0"))
     (16 . ("long" "0"))
     (17 . ("int" "0"))
     (18 . ("long" "0")))
    (cpp #f
     (1 . ("double" "0"))
     (2 . ("float" "0"))
     (3 . ("std::int64_t" "0"))
     (4 . ("std::uint64_t" "0"))
     (5 . ("std::int32_t" "0"))
     (6 . ("std::uint64_t" "0"))
     (7 . ("std::uint32_t" "0"))
     (8 . ("bool" "false"))
     (9 . ("std::string" "\"\""))
     (12 . ("std::vector<std::uint8_t>" "{}"))
     (13 . ("std::uint32_t" "0"))
     (15 . ("std::int32_t" "0"))
     (16 . ("std::int64_t" "0"))
     (17 . ("std::int32_t" "0"))
     (18 . ("std::int64_t" "0")))
    (swift #f
     (1 . ("Double" "0"))
     (2 . ("Float" "0"))
     (3 . ("Int64" "0"))
     (4 . ("UInt64" "0"))
     (5 . ("Int32" "0"))
     (6 . ("UInt64" "0"))
     (7 . ("UInt32" "0"))
     (8 . ("Bool" "false"))
     (9 . ("String" "\"\""))
     (12 . ("[UInt8]" "[]"))
     (13 . ("UInt32" "0"))
     (15 . ("Int32" "0"))
     (16 . ("Int64" "0"))
     (17 . ("Int32" "0"))
     (18 . ("Int64" "0")))
    (kotlin #f
     (1 . ("Double" "0.0"))
     (2 . ("Float" "0f"))
     (3 . ("Long" "0L"))
     (4 . ("ULong" "0uL"))
     (5 . ("Int" "0"))
     (6 . ("ULong" "0uL"))
     (7 . ("UInt" "0u"))
     (8 . ("Boolean" "false"))
     (9 . ("String" "\"\""))
     (12 . ("ByteArray" "ByteArray(0)"))
     (13 . ("UInt" "0u"))
     (15 . ("Int" "0"))
     (16 . ("Long" "0L"))
     (17 . ("Int" "0"))
     (18 . ("Long" "0L")))
    (dart #f
     (1 . ("double" "0"))
     (2 . ("double" "0"))
     (3 . ("int" "0"))
     (4 . ("int" "0"))
     (5 . ("int" "0"))
     (6 . ("int" "0"))
     (7 . ("int" "0"))
     (8 . ("bool" "false"))
     (9 . ("String" "''"))
     (12 . ("Uint8List" "Uint8List(0)"))
     (13 . ("int" "0"))
     (15 . ("int" "0"))
     (16 . ("int" "0"))
     (17 . ("int" "0"))
     (18 . ("int" "0")))
    (zig #f
     (1 . ("f64" "0"))
     (2 . ("f32" "0"))
     (3 . ("i64" "0"))
     (4 . ("u64" "0"))
     (5 . ("i32" "0"))
     (6 . ("u64" "0"))
     (7 . ("u32" "0"))
     (8 . ("bool" "false"))
     (9 . ("[]const u8" "\"\""))
     (12 . ("[]const u8" "\"\""))
     (13 . ("u32" "0"))
     (15 . ("i32" "0"))
     (16 . ("i64" "0"))
     (17 . ("i32" "0"))
     (18 . ("i64" "0")))
    (c #f
     (1 . ("double" "0"))
     (2 . ("float" "0"))
     (3 . ("int64_t" "0"))
     (4 . ("uint64_t" "0"))
     (5 . ("int32_t" "0"))
     (6 . ("uint64_t" "0"))
     (7 . ("uint32_t" "0"))
     (8 . ("bool" "false"))
     (9 . ("char *" "\"\""))
     (12 . ("~aBytes" "\"\""))
     (13 . ("uint32_t" "0"))
     (15 . ("int32_t" "0"))
     (16 . ("int64_t" "0"))
     (17 . ("int32_t" "0"))
     (18 . ("int64_t" "0")))))

(define (scalar-type-entry lang type)
  (define row (assq lang scalar-type-tables))
  (unless row (error 'scalar-type-entry "unknown language: ~e" lang))
  (define e (assv type (cddr row)))
  (if e (cdr e) (cadr row)))

(provide scalar-type-tables scalar-type-entry)


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
