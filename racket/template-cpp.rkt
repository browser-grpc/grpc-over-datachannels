#lang racket

;;; template-cpp.rkt — emitter body spliced into
;;; protoc-gen-grpc-dc-cpp.
;;;
;;; Generated code is one struct <Base>GrpcDc in the proto package's
;;; namespace, beside hand-written message types implementing
;;; grpcdc::Marshaler / grpcdc::Unmarshaler. Method names keep the
;;; proto spelling, mirroring the Go/Java/C# stubs.

(require "spec.rkt" "desc.rkt" "segments.rkt")
(provide emit-cpp-file)

(define current-service (make-parameter ""))

;; Package of the proto file whose stubs are being emitted.
(define current-cpp-pkg (make-parameter ""))

;; Display name of a method input/output type in stub code: the
;; plain name when the type shares the stub file's package, else
;; fully qualified (::pkg::...::Type) so cross-file message types
;; resolve inside the stub namespace.
(define (cpp-stub-type-name m full-key)
  (define full (hash-ref m full-key))
  (define pkg (current-cpp-pkg))
  (if (or (string=? pkg "")
          (not (string-contains? full "."))
          (string-prefix? full (string-append pkg ".")))
      (hash-ref m (if (eq? full-key 'input-full) 'input 'output))
      (string-append "::" (string-join (string-split full ".") "::"))))

(define (pascal sym) ; echo_service -> EchoService ; echo -> Echo
  (apply string-append
         (for/list ([part (in-list (string-split (symbol->string sym) "[_.-]"))])
           (if (string=? part "")
               ""
               (string-append (string (char-upcase (string-ref part 0)))
                              (substring part 1))))))





(define (cpp-client-method m)
  (run-segments cpp-client-method-program m (current-service) #f (list "    ")))

(define (cpp-client-stream-class m)
  (run-segments cpp-stream-class-program m (current-service)))

(define (cpp-client-async-method m)
  (run-segments cpp-client-async-method-program m (current-service)))

(define (cpp-client-coro-stream-class m)
  (run-segments cpp-coro-stream-class-program m (current-service)))

(define (cpp-client-coro-method m)
  (run-segments cpp-client-coro-method-program m (current-service)))

(define (cpp-server-stream-iface m)
  (run-segments cpp-server-stream-iface-program m (current-service)))



(define (cpp-server-iface-method m)
  (run-segments cpp-server-iface-method-program m (current-service) #f (list "    ")))

(define (cpp-server-async-iface-method m)
  (run-segments cpp-server-async-iface-method-program m (current-service)))

(define (cpp-server-async-adapter-method m)
  (run-segments cpp-server-async-adapter-method-program m (current-service)))

(define (cpp-stream-impl m)
  (run-segments cpp-stream-impl-program m (current-service)))

(define (cpp-register-method m)
  (run-segments cpp-register-method-program m (current-service)))

(define (cpp-service svc)
  (parameterize ([seg-cpp-pkg (current-cpp-pkg)])
    (run-segments cpp-service-program svc (hash-ref svc 'name))))

;; ---------------------------------------------------------------------------
;; C++ message types (<base>_messages.hpp, matching the stub's
;; include): classes implementing grpcdc::Marshaler/Unmarshaler
;; plus a pb_<base> wire-support namespace per proto file.
;; Dependency-free (std only). Mirrors the Java emitter on the
;; shared desc.rkt model.
;; ---------------------------------------------------------------------------

(define cpp-pb-varint-types varint-scalar-types)
(define cpp-pb-fixed (fixed-scalar-table 'cpp))

(define (cpp-pb-resolve model type-name)
  (hash-ref (hash-ref model 'types) type-name
            (lambda () (error 'emit-cpp-pb-file "unresolved type ~a" type-name))))

(define (cpp-pb-ns pkg)
  (if (string=? pkg "") "proto" (string-join (string-split pkg ".") "::")))







(define (cpp-pb-rel pkg full)
  (define rel (if (and pkg (not (string=? pkg "")) (string-prefix? full (string-append pkg ".")))
                  (substring full (add1 (string-length pkg)))
                  full))
  (string-join (string-split rel ".") "::"))

(define (cpp-pb-type model f)
  (run-segments cpp-pb-type-program f #f model))

(define (cpp-pb-explicit-literal model f)
  (run-segments cpp-pb-explicit-literal-program f #f model))

(define (cpp-pb-default model f)
  (run-segments cpp-pb-default-program f #f model))

(define (cpp-pb-varint-expr f v)
  (run-segments cpp-pb-varint-expr-program f #f #f (list v)))

(define (cpp-pb-varint-decode f v)
  (run-segments cpp-pb-varint-decode-program f #f #f (list v)))

(define (cpp-pb-nonzero f v)
  (run-segments cpp-pb-nonzero-program f #f #f (list v)))

(define (cpp-pb-encode-singular model f v indent support)
  (run-segments cpp-pb-encode-singular-program f #f model (list v indent)))

(define (cpp-pb-set-expr sib)
  (run-segments cpp-pb-set-expr-program sib #f))

;; Encode-side oneof clearing: suppress f when a later sibling is
;; set, so only the winning member is written.


(define (cpp-pb-encode-field model f support)
  (run-segments cpp-pb-encode-field-program f #f model (list support)))

(define (cpp-pb-decode-singular model f target src indent support)
  (run-segments cpp-pb-decode-singular-program f #f model (list target src indent support)))

(define (cpp-pb-oneof-clearing model f)
  (run-segments cpp-pb-clearing-program f #f model))

(define (cpp-pb-decode-case model f support)
  (run-segments cpp-pb-decode-case-program f #f model (list support)))



(define (cpp-pb-map-helpers model entry support)
  (cons (run-segments cpp-pb-map-helpers-decl-program entry #f model)
        (run-segments cpp-pb-map-helpers-impl-program entry #f model (list support))))

(define (cpp-pb-support-open base pkg deps)
  (string-append
   "// @generated by protoc-gen-grpc-dc-cpp. DO NOT EDIT.\n"
   "#pragma once\n\n"
   "#include <cstdint>\n#include <cstring>\n#include <map>\n#include <optional>\n#include <stdexcept>\n#include <string>\n#include <utility>\n#include <vector>\n\n"
   "#include \"grpcdc/transport.hpp\"\n"
   (apply string-append
          (map (lambda (d)
                 (format "#include \"~a_messages.hpp\"\n"
                         (path->string (path-replace-extension (file-name-from-path d) ""))))
               deps))
   "\n"
   (format "namespace ~a {\n\n" (cpp-pb-ns pkg))))

(define (cpp-pb-support base pkg helpers)
  (string-append
   (format "namespace pb_~a {\n\n" base)
   "class Writer {\n"
   "    grpcdc::Bytes out_;\n"
   "public:\n"
   "    void Varint(std::uint64_t v) { while (v > 0x7f) { out_.push_back(static_cast<std::uint8_t>((v & 0x7f) | 0x80)); v >>= 7; } out_.push_back(static_cast<std::uint8_t>(v)); }\n"
   "    void Tag(int field, int wire) { Varint(static_cast<std::uint64_t>((field << 3) | wire)); }\n"
   "    void BytesField(int field, const grpcdc::Bytes& payload) { Tag(field, 2); Varint(payload.size()); out_.insert(out_.end(), payload.begin(), payload.end()); }\n"
   "    void StringField(int field, const std::string& value) { if (value.empty()) return; BytesField(field, grpcdc::Bytes(value.begin(), value.end())); }\n"
   "    void FixedInt32(std::int32_t v) { std::uint32_t u = static_cast<std::uint32_t>(v); for (int i = 0; i < 4; i++) out_.push_back(static_cast<std::uint8_t>((u >> (8 * i)) & 0xff)); }\n"
   "    void FixedInt64(std::int64_t v) { std::uint64_t u = static_cast<std::uint64_t>(v); for (int i = 0; i < 8; i++) out_.push_back(static_cast<std::uint8_t>((u >> (8 * i)) & 0xff)); }\n"
   "    void FixedFloat(float v) { std::uint32_t u; std::memcpy(&u, &v, 4); FixedInt32(static_cast<std::int32_t>(u)); }\n"
   "    void FixedDouble(double v) { std::uint64_t u; std::memcpy(&u, &v, 8); FixedInt64(static_cast<std::int64_t>(u)); }\n"
   "    void Raw(const grpcdc::Bytes& payload) { out_.insert(out_.end(), payload.begin(), payload.end()); }\n"
   "    grpcdc::Bytes ToBytes() const { return out_; }\n"
   "};\n\n"
   "inline float BitsToFloat(std::uint32_t u) { float v; std::memcpy(&v, &u, 4); return v; }\n"
   "inline double BitsToDouble(std::uint64_t u) { double v; std::memcpy(&v, &u, 8); return v; }\n\n"
   "struct Field {\n"
   "    int number = 0; int wire = 0; std::uint64_t varint = 0; grpcdc::Bytes bytes; std::uint64_t fixed = 0; grpcdc::Bytes raw;\n"
   "};\n\n"
   "class Reader {\n"
   "    grpcdc::Bytes buf_; std::size_t pos_ = 0;\n"
   "public:\n"
   "    explicit Reader(const grpcdc::Bytes& buf) : buf_(buf) {}\n"
   "    bool Done() const { return pos_ >= buf_.size(); }\n"
   "    std::uint64_t Varint() { std::uint64_t result = 0; int shift = 0; while (true) { if (pos_ >= buf_.size()) throw std::invalid_argument(\"truncated varint\"); std::uint8_t b = buf_[pos_++]; result |= static_cast<std::uint64_t>(b & 0x7f) << shift; if ((b & 0x80) == 0) return result; shift += 7; if (shift >= 64) throw std::invalid_argument(\"varint too long\"); } }\n"
   "    grpcdc::Bytes Take(std::size_t n) { if (pos_ + n > buf_.size()) throw std::invalid_argument(\"truncated field\"); grpcdc::Bytes v(buf_.begin() + pos_, buf_.begin() + pos_ + n); pos_ += n; return v; }\n"
   "    std::uint32_t Fixed32() { auto b = Take(4); return static_cast<std::uint32_t>(b[0]) | (static_cast<std::uint32_t>(b[1]) << 8) | (static_cast<std::uint32_t>(b[2]) << 16) | (static_cast<std::uint32_t>(b[3]) << 24); }\n"
   "    std::uint64_t Fixed64() { auto b = Take(8); std::uint64_t v = 0; for (int i = 0; i < 8; i++) v |= static_cast<std::uint64_t>(b[i]) << (8 * i); return v; }\n"
   "    bool Next(Field& field) {\n"
   "        if (pos_ >= buf_.size()) return false;\n"
   "        std::size_t start = pos_;\n"
   "        std::uint64_t tag = Varint(); field.number = static_cast<int>(tag >> 3); field.wire = static_cast<int>(tag & 7);\n"
   "        switch (field.wire) {\n"
   "            case 0: field.varint = Varint(); field.raw.assign(buf_.begin() + start, buf_.begin() + pos_); return true;\n"
   "            case 2: { std::size_t n = static_cast<std::size_t>(Varint()); field.bytes = Take(n); field.raw.assign(buf_.begin() + start, buf_.begin() + pos_); return true; }\n"
   "            case 1: field.bytes = Take(8); field.fixed = 0; for (int i = 0; i < 8; i++) field.fixed |= static_cast<std::uint64_t>(field.bytes[i]) << (8 * i); field.raw.assign(buf_.begin() + start, buf_.begin() + pos_); return true;\n"
   "            case 5: field.bytes = Take(4); field.fixed = static_cast<std::uint32_t>(field.bytes[0]) | (static_cast<std::uint32_t>(field.bytes[1]) << 8) | (static_cast<std::uint32_t>(field.bytes[2]) << 16) | (static_cast<std::uint32_t>(field.bytes[3]) << 24); field.raw.assign(buf_.begin() + start, buf_.begin() + pos_); return true;\n"
   "            default: throw std::invalid_argument(\"bad wire type\");\n"
   "        }\n"
   "    }\n"
   "};\n\n"
   helpers
   (format "}  // namespace pb_~a\n\n" base)))

(define (cpp-pb-message-class model msg support indent)
  (run-segments cpp-pb-message-program msg #f model (list support indent)))

;; Out-of-line MarshalDc/UnmarshalDc definitions for a message
;; class and its nested classes, emitted after all class
;; declarations and the map helper declarations.
(define (cpp-pb-message-impls model msg support qual)
  (run-segments cpp-pb-message-impls-program msg #f model (list support qual)))

(define (cpp-pb-nested-enum e indent)
  (run-segments cpp-pb-nested-enum-program e #f #f (list indent)))

(define (emit-cpp-pb-file file-model)
  (and (hash-has-key? file-model 'messages)
       (hash-has-key? file-model 'types)
       (emit-cpp-pb-file/inner file-model)))

;; Top-level messages ordered so same-file by-value dependencies
;; (singular message fields held as std::optional, map values)
;; are defined before their users — C++ requires complete types
;; for those members regardless of proto declaration order.
(define (cpp-pb-ordered-messages file-model messages)
  (define tops (filter (lambda (m) (not (hash-ref m 'map-entry))) messages))
  (define (top-of e)
    (and (equal? (hash-ref e 'file) (hash-ref file-model 'name))
         (car (string-split (cpp-pb-rel (hash-ref file-model 'package) (hash-ref e 'full)) "::"))))
  (define (deps m)
    (define out '())
    (define (note f)
      (when (= (hash-ref f 'type) 11)
        (define e (cpp-pb-resolve file-model (hash-ref f 'type-name)))
        (cond [(eq? (hash-ref e 'kind) 'map)
               (define val-f (findf (lambda (x) (= (hash-ref x 'number) 2))
                                    (hash-ref (hash-ref e 'msg) 'fields)))
               (when (= (hash-ref val-f 'type) 11)
                 (define ve (cpp-pb-resolve file-model (hash-ref val-f 'type-name)))
                 (when (eq? (hash-ref ve 'kind) 'message)
                   (define t (top-of ve))
                   (when t (set! out (cons t out)))))]
              [(and (eq? (hash-ref e 'kind) 'message) (not (= (hash-ref f 'label) 3)))
               (define t (top-of e))
               (when t (set! out (cons t out)))])))
    (define (walk msg)
      (for ([f (in-list (hash-ref msg 'fields))]) (note f))
      (for ([n (in-list (hash-ref msg 'nested))]) (walk n)))
    (walk m)
    (remove-duplicates (reverse out)))
  (define dep-map (map (lambda (m) (cons (hash-ref m 'name) (deps m))) tops))
  (define remaining (list->mutable-set (map (lambda (m) (hash-ref m 'name)) tops)))
  (define (ready? m)
    (andmap (lambda (d) (or (equal? d (hash-ref m 'name)) (not (set-member? remaining d))))
            (cdr (assoc (hash-ref m 'name) dep-map))))
  (let loop ([ms tops] [out '()])
    (cond [(null? ms) (reverse out)]
          [else
           (define next (findf ready? ms))
           (unless next (error 'emit-cpp-pb-file "message dependency cycle"))
           (set-remove! remaining (hash-ref next 'name))
           (loop (remq next ms) (cons next out))])))

(define (emit-cpp-pb-file/inner file-model)
  (define messages (hash-ref file-model 'messages))
  (define enums (hash-ref file-model 'enums))
  (and (or (pair? messages) (pair? enums))
       (let ()
         (define base (path->string (path-replace-extension
                                     (file-name-from-path (hash-ref file-model 'name)) "")))
         (define pkg (hash-ref file-model 'package))
         (define support (format "pb_~a" base))
         (define seen-maps (mutable-set))
         (define helpers '())
         (define (collect msg)
           (for ([f (in-list (hash-ref msg 'fields))])
             (when (= (hash-ref f 'type) 11)
               (define e (cpp-pb-resolve file-model (hash-ref f 'type-name)))
               (when (and (eq? (hash-ref e 'kind) 'map)
                          (not (set-member? seen-maps (hash-ref (hash-ref e 'msg) 'full-name))))
                 (set-add! seen-maps (hash-ref (hash-ref e 'msg) 'full-name))
                 (set! helpers (cons (cpp-pb-map-helpers file-model e support) helpers)))))
           (for ([n (in-list (hash-ref msg 'nested))]) (collect n)))
         (for ([m (in-list messages)]) (collect m))
         (define ordered (cpp-pb-ordered-messages file-model messages))
         (define content
           (string-append
            (cpp-pb-support-open base pkg (hash-ref file-model 'dependencies))
            (apply string-append
                   (map (lambda (m) (format "class ~a;\n" (hash-ref m 'name)))
                        (filter (lambda (m) (not (hash-ref m 'map-entry))) messages)))
            "\n"
            ;; Top-level enums precede the support block: its map
            ;; helper declarations name enum value types.
            (apply string-append
                   (map (lambda (e)
                          (string-append
                           (format "enum class ~a : std::int32_t {\n" (hash-ref e 'name))
                           (string-join (map (lambda (v) (format "  ~a = ~a" (hash-ref v 'name) (hash-ref v 'number)))
                                             (hash-ref e 'values)) ",\n")
                           "\n};\n\n"))
                        enums))
            (cpp-pb-support base pkg "")
            (apply string-append
                   (map (lambda (m) (cpp-pb-message-class file-model m support ""))
                        ordered))
            ;; Map helper declarations come after the classes:
            ;; they name nested message types, which must be
            ;; declared first. Implementations follow, then the
            ;; out-of-line MarshalDc/UnmarshalDc definitions.
            (if (null? helpers)
                ""
                (string-append
                 (format "namespace pb_~a {\n\n" base)
                 (apply string-append (map car (reverse helpers)))
                 (format "}  // namespace pb_~a\n\n" base)))
            (apply string-append
                   (map (lambda (m) (cpp-pb-message-impls file-model m support ""))
                        ordered))
            (if (null? helpers)
                ""
                (string-append
                 (format "namespace pb_~a {\n\n" base)
                 (apply string-append (map cdr (reverse helpers)))
                 (format "}  // namespace pb_~a\n\n" base)))
            (format "}  // namespace ~a\n" (cpp-pb-ns pkg))
            (if (seg-struct-codec) (format "#include \"~a_struct.hpp\"\n" base) "")))
         (cons (string-append base "_messages.hpp") content))))

;; Message includes for a stub: one examples/<base>_messages.hpp
;; per file that defines a method input/output type (which may
;; live in an imported proto, not the service's own file).
(define (cpp-stub-includes file-model)
  (define self-base
    (path->string (path-replace-extension
                   (file-name-from-path (hash-ref file-model 'name)) "")))
  (cond [(not (hash-has-key? file-model 'types))
         (format "#include \"examples/~a_messages.hpp\"\n" self-base)]
        [else
         (define files
           (remove-duplicates
            (for*/list ([svc (in-list (hash-ref file-model 'services))]
                        [m (in-list (hash-ref svc 'methods))]
                        [k (in-list '(input-full output-full))])
              (hash-ref (cpp-pb-resolve file-model (hash-ref m k)) 'file))))
         (apply string-append
                (map (lambda (fn)
                       (format "#include \"examples/~a_messages.hpp\"\n"
                               (path->string (path-replace-extension
                                              (file-name-from-path fn) ""))))
                     files))]))

(define (emit-cpp-file file-model params)
  (define base (path->string (path-replace-extension
                              (file-name-from-path (hash-ref file-model 'name)) "")))
  (define struct-name (string-append (pascal (string->symbol base)) "GrpcDc"))
  (define pkg (hash-ref file-model 'package))
  (define ns (cpp-pb-ns pkg))
  (define stub
    (cons (string-append base "_grpc_dc.hpp")
          (parameterize ([current-cpp-pkg pkg])
           (string-append
           "// @generated by protoc-gen-grpc-dc-cpp. DO NOT EDIT.\n"
         (format "// source: ~a\n" (hash-ref file-model 'name))
         "#pragma once\n\n"
         "#include <future>\n#include <optional>\n\n#if __cplusplus >= 202002L\n#include \"grpcdc/async.hpp\"\n#endif\n"
         "#include <memory>\n"
         "#include <vector>\n\n"
         (cpp-stub-includes file-model)
         "#include \"grpcdc/channel.hpp\"\n"
         "#include \"grpcdc/server.hpp\"\n\n"
         (format "namespace ~a {\n\n" ns)
         ;; trace=hooks: delegate the tracer registrar to grpcdc::Tracing.
         (if (equal? (hash-ref params 'trace #f) "hooks")
             (string-append
              "/// Tracing (trace=hooks@@TRACING_BETA@@): register an observer via SetTracer.\n"
              "inline void SetTracer(grpcdc::Tracing::Tracer* t) { grpcdc::Tracing::SetTracer(t); }\n"
              "inline void SetTraceFilter(const std::string& patterns) { grpcdc::Tracing::SetTraceFilter(patterns); }\n"
              (let ([methods (hash-ref params 'trace_methods #f)])
                (if methods
                    (format "inline const bool _grpcdcTraceFilterApplied = [] { grpcdc::Tracing::SetTraceFilter(~s); return true; }();\n" methods)
                    ""))
              "\n")
             "")
         (format "/// Generated gRPC-over-DataChannels stubs for ~a.\n" (hash-ref file-model 'name))
         (format "struct ~a {\n" struct-name)
         (apply string-append
                (map cpp-service (hash-ref file-model 'services)))
         "};\n\n"
         (format "}  // namespace ~a\n" ns)))))
  (define pb-file (parameterize ([seg-struct-codec (equal? (hash-ref params 'struct_codec #f) "true")])
                    (emit-cpp-pb-file file-model)))
  (define struct-file (emit-cpp-struct-file file-model params))
  (if struct-file
      (append (list stub pb-file) (list struct-file))
      (if pb-file (list stub pb-file) stub)))

;; ------------------------------------------------------------------
;; Struct codec (struct_codec=true): <Msg>Struct struct with static
;; Size/Marshal/Unmarshal per message in <base>_struct.hpp, packed
;; layout from SPEC.md (byte-identical to the other struct codecs;
;; verified by conformance/struct).
(define (cpp-struct-fingerprint s)
  (for/fold ([h 2166136261]) ([c (in-string s)])
    (modulo (* (bitwise-xor h (char->integer c)) 16777619) 4294967296)))

(define (cpp-struct-fixed32-type? t) (member t '(2 7 15)))
(define (cpp-struct-fixed64-type? t) (member t '(1 6 16)))

(define (cpp-struct-slot-size f)
  (if (cpp-struct-fixed32-type? (hash-ref f 'type)) 4 8))

(define (cpp-struct-sorted-fields msg)
  (sort (hash-ref msg 'fields) < #:key (lambda (f) (hash-ref f 'number))))

(define (cpp-struct-map-entry model f)
  (and (= (hash-ref f 'type) 11)
       (let ([e (cpp-pb-resolve model (hash-ref f 'type-name))])
         (and (eq? (hash-ref e 'kind) 'map) e))))

(define (cpp-struct-map-key-field model f)
  (define em (hash-ref (cpp-struct-map-entry model f) 'msg))
  (findf (lambda (x) (= (hash-ref x 'number) 1)) (hash-ref em 'fields)))
(define (cpp-struct-map-val-field model f)
  (define em (hash-ref (cpp-struct-map-entry model f) 'msg))
  (findf (lambda (x) (= (hash-ref x 'number) 2)) (hash-ref em 'fields)))

(define (cpp-struct-type-name model msg)
  (cpp-pb-rel (hash-ref model 'package) (hash-ref msg 'full-name)))

(define (cpp-struct-flat-name model msg)
  (string-replace (cpp-struct-type-name model msg) "::" "_"))

(define (cpp-struct-class-name model f)
  (define e (cpp-pb-resolve model (hash-ref f 'type-name)))
  (cpp-struct-type-name model (hash-ref e 'msg)))

(define (cpp-struct-companion model f)
  (string-append (string-replace (cpp-struct-class-name model f) "::" "_") "Struct"))

(define (cpp-struct-present model f fn)
  (define t (hash-ref f 'type))
  (cond [(cpp-struct-map-entry model f) (format "!m.~a.empty()" fn)]
        [(= (hash-ref f 'label) 3) (format "!m.~a.empty()" fn)]
        [(= t 11) (format "m.~a.has_value()" fn)]
        [(= t 9) (format "!m.~a.empty()" fn)]
        [(= t 12) (format "!m.~a.empty()" fn)]
        [(= t 8) (format "m.~a" fn)]
        [(= t 14) (format "static_cast<std::int32_t>(m.~a) != 0" fn)]
        [else (format "m.~a != 0" fn)]))

(define (cpp-struct-scalar-encode f v)
  (define t (hash-ref f 'type))
  (cond [(cpp-struct-fixed32-type? t)
         (if (= t 2)
             (format "{ float fv = ~a; std::uint32_t u; std::memcpy(&u, &fv, 4); Put32(buf, off, u); }" v)
             (format "Put32(buf, off, static_cast<std::uint32_t>(~a));" v))]
        [(cpp-struct-fixed64-type? t)
         (if (= t 1)
             (format "{ double fv = ~a; std::uint64_t u; std::memcpy(&u, &fv, 8); Put64(buf, off, u); }" v)
             (format "Put64(buf, off, static_cast<std::uint64_t>(~a));" v))]
        [(= t 8) (format "buf[off] = ~a ? 1 : 0;" v)]
        [(= t 14) (format "Put64(buf, off, static_cast<std::uint64_t>(static_cast<std::int64_t>(~a)));" v)]
        [(member t '(3 16 18)) (format "Put64(buf, off, static_cast<std::uint64_t>(static_cast<std::int64_t>(~a)));" v)]
        [(member t '(5 17)) (format "Put64(buf, off, static_cast<std::uint64_t>(static_cast<std::int64_t>(~a)));" v)]
        [else (format "Put64(buf, off, static_cast<std::uint64_t>(~a));" v)]))

(define (cpp-struct-scalar-value/off model f offv)
  (define t (hash-ref f 'type))
  (cond [(cpp-struct-fixed32-type? t)
         (if (= t 2)
             (format "BitsToFloat(Get32(data, ~a))" offv)
             (format "static_cast<~a>(Get32(data, ~a))" (first (scalar-type-entry 'cpp t)) offv))]
        [(cpp-struct-fixed64-type? t)
         (if (= t 1)
             (format "BitsToDouble(Get64(data, ~a))" offv)
             (format "static_cast<~a>(Get64(data, ~a))" (first (scalar-type-entry 'cpp t)) offv))]
        [(= t 8) (format "(data[~a] != 0)" offv)]
        [(= t 14) (format "static_cast<~a>(static_cast<std::int32_t>(Get64(data, ~a)))"
                          (cpp-pb-type model (hash-set f 'label 1)) offv)]
        [(member t '(3 16 18)) (format "static_cast<~a>(static_cast<std::int64_t>(Get64(data, ~a)))" (first (scalar-type-entry 'cpp t)) offv)]
        [(member t '(5 17)) (format "static_cast<~a>(static_cast<std::int32_t>(Get64(data, ~a)))" (first (scalar-type-entry 'cpp t)) offv)]
        [else (format "static_cast<~a>(Get64(data, ~a))" (first (scalar-type-entry 'cpp t)) offv)]))

(define (cpp-struct-value-size model f v)
  (define t (hash-ref f 'type))
  (cond [(= t 9) (format "~a.size()" v)]
        [(= t 12) (format "~a.size()" v)]
        [(= t 11) (format "~aStruct::Size(~a)" (string-replace (cpp-struct-class-name model f) "::" "_") v)]
        [(cpp-struct-fixed32-type? t) "4"]
        [else "8"]))

(define (cpp-structdc-detail-name model)
  (define base (path->string (path-replace-extension
                              (file-name-from-path (hash-ref model 'name)) "")))
  (string-append "structdc_detail_"
                 (regexp-replace* #rx"[^A-Za-z0-9_]" base "_")))

(define (cpp-struct-message model msg)
  (define detail (cpp-structdc-detail-name model))
  (define type-name (cpp-struct-type-name model msg))
  (define flat (cpp-struct-flat-name model msg))
  (define full-name (hash-ref msg 'full-name))
  (define out (open-output-string))
  (fprintf out "struct ~aStruct {\n" flat)
  (fprintf out "    static std::size_t Size(const ~a& m) { return Marshal(m).size(); }\n\n" type-name)
  (fprintf out "    static grpcdc::Bytes Marshal(const ~a& m) {\n        return ~a::Transcode(true, \"~a\", m.MarshalDc());\n    }\n\n" type-name detail full-name)
  (fprintf out "    static ~a Unmarshal(const grpcdc::Bytes& data) {\n        auto pb = ~a::Transcode(false, \"~a\", data);\n        ~a m;\n        m.UnmarshalDc(pb);\n        return m;\n    }\n};\n\n" type-name detail full-name type-name)
  (fprintf out "#if !defined(__wasm__)\n")
  (fprintf out "inline grpcdc::Bytes ~a::MarshalStruct() const { return ~aStruct::Marshal(*this); }\n" type-name flat)
  (fprintf out "inline void ~a::UnmarshalStruct(const grpcdc::Bytes& data) { *this = ~aStruct::Unmarshal(data); }\n" type-name flat)
  (fprintf out "#endif\n\n")
  (get-output-string out))

(define (cpp-struct-value-write model f v)
  (define t (hash-ref f 'type))
  (define out (open-output-string))
  (cond [(= t 9)
         (fprintf out "                if (!~a.empty()) std::memcpy(buf.data() + vp, ~a.data(), ~a.size()); vp += ~a.size();\n" v v v v)]
        [(= t 12)
         (fprintf out "                if (!~a.empty()) std::memcpy(buf.data() + vp, ~a.data(), ~a.size()); vp += ~a.size();\n" v v v v)]
        [(= t 11)
         (fprintf out "                { auto nb = ~aStruct::Marshal(~a); if (!nb.empty()) std::memcpy(buf.data() + vp, nb.data(), nb.size()); vp += nb.size(); }\n"
                  (string-replace (cpp-struct-class-name model f) "::" "_") v)]
        [else
         (fprintf out "                { std::size_t off = vp; ~a } vp += ~a;\n"
                  (cpp-struct-scalar-encode f v) (if (cpp-struct-fixed32-type? t) 4 8))])
  (get-output-string out))

(define (cpp-struct-marshal-field model f off)
  (define fn (hash-ref f 'name))
  (define t (hash-ref f 'type))
  (define out (open-output-string))
  (define mv (format "m.~a" fn))
  (cond [(cpp-struct-map-entry model f)
         (define kf (cpp-struct-map-key-field model f))
         (define vf (cpp-struct-map-val-field model f))
         (fprintf out "        if (!~a.empty()) {\n            Put32(buf, ~a, static_cast<std::uint32_t>(vp)); Put32(buf, ~a, static_cast<std::uint32_t>(~a.size()));\n" mv off (+ off 4) mv)
         (fprintf out "            for (const auto& e : ~a) {\n                Put32(buf, vp, static_cast<std::uint32_t>(~a)); Put32(buf, vp + 4, static_cast<std::uint32_t>(~a)); vp += 8;\n"
                  mv (cpp-struct-value-size model kf "e.first") (cpp-struct-value-size model vf "e.second"))
         (display (cpp-struct-value-write model kf "e.first") out)
         (display (cpp-struct-value-write model vf "e.second") out)
         (fprintf out "            }\n        }\n")]
        [(= (hash-ref f 'label) 3)
         (cond [(member t '(9 12))
                (fprintf out "        if (!~a.empty()) {\n            Put32(buf, ~a, static_cast<std::uint32_t>(vp)); Put32(buf, ~a, static_cast<std::uint32_t>(~a.size()));\n            std::size_t doff = vp + 8 * ~a.size();\n            for (const auto& e : ~a) { Put32(buf, vp, static_cast<std::uint32_t>(doff)); Put32(buf, vp + 4, static_cast<std::uint32_t>(~a)); doff += ~a; vp += 8; }\n            for (const auto& e : ~a) { ~a }\n        }\n"
                         mv off (+ off 4) mv mv mv "e.size()" "e.size()"
                         mv "if (!e.empty()) std::memcpy(buf.data() + vp, e.data(), e.size()); vp += e.size();")]
               [(= t 11)
                (fprintf out "        if (!~a.empty()) {\n            Put32(buf, ~a, static_cast<std::uint32_t>(vp)); Put32(buf, ~a, static_cast<std::uint32_t>(~a.size()));\n            std::size_t doff = vp + 8 * ~a.size();\n            for (const auto& e : ~a) { std::size_t es = ~aStruct::Size(e); Put32(buf, vp, static_cast<std::uint32_t>(doff)); Put32(buf, vp + 4, static_cast<std::uint32_t>(es)); doff += es; vp += 8; }\n            for (const auto& e : ~a) { auto nb = ~aStruct::Marshal(e); if (!nb.empty()) std::memcpy(buf.data() + vp, nb.data(), nb.size()); vp += nb.size(); }\n        }\n"
                         mv off (+ off 4) mv mv mv (string-replace (cpp-struct-class-name model f) "::" "_")
                         mv (string-replace (cpp-struct-class-name model f) "::" "_"))]
               [else
                (fprintf out "        if (!~a.empty()) {\n            Put32(buf, ~a, static_cast<std::uint32_t>(vp)); Put32(buf, ~a, static_cast<std::uint32_t>(~a.size()));\n            for (const auto& e : ~a) { std::size_t off = vp; ~a vp += ~a; }\n        }\n"
                         mv off (+ off 4) mv
                         mv
                         (cpp-struct-scalar-encode f "e")
                         (if (cpp-struct-fixed32-type? t) 4 8))])]
        [(= t 11)
         (fprintf out "        if (~a.has_value()) {\n            Put32(buf, ~a, static_cast<std::uint32_t>(vp)); Put32(buf, ~a, static_cast<std::uint32_t>(~aStruct::Size(*~a)));\n            auto nb = ~aStruct::Marshal(*~a); if (!nb.empty()) std::memcpy(buf.data() + vp, nb.data(), nb.size()); vp += nb.size();\n        }\n"
                  mv off (+ off 4) (string-replace (cpp-struct-class-name model f) "::" "_") mv (string-replace (cpp-struct-class-name model f) "::" "_") mv)]
        [(member t '(9 12))
         (fprintf out "        if (!~a.empty()) {\n            Put32(buf, ~a, static_cast<std::uint32_t>(vp)); Put32(buf, ~a, static_cast<std::uint32_t>(~a.size()));\n            if (!~a.empty()) std::memcpy(buf.data() + vp, ~a.data(), ~a.size()); vp += ~a.size();\n        }\n"
                  mv off (+ off 4) mv mv mv mv mv)]
        [else
         (fprintf out "        { std::size_t off = ~a; ~a }\n" off (cpp-struct-scalar-encode f mv))])
  (get-output-string out))

(define (cpp-struct-value-expr/off model f lenvar offv)
  (define t (hash-ref f 'type))
  (cond [(= t 9) (format "std::string(reinterpret_cast<const char*>(data.data() + ~a), ~a)" offv lenvar)]
        [(= t 12) (format "grpcdc::Bytes(data.begin() + ~a, data.begin() + ~a + ~a)" offv offv lenvar)]
        [(= t 11) (format "(~a > 0 ? ~aStruct::Unmarshal(grpcdc::Bytes(data.begin() + ~a, data.begin() + ~a + ~a)) : ~a())"
                          lenvar (string-replace (cpp-struct-class-name model f) "::" "_") offv offv lenvar
                          (cpp-struct-class-name model f))]
        [else (cpp-struct-scalar-value/off model f offv)]))

(define (cpp-struct-decode-field model f foff)
  (define fn (hash-ref f 'name))
  (define t (hash-ref f 'type))
  (define out (open-output-string))
  (define mv (format "m.~a" fn))
  (cond [(cpp-struct-map-entry model f)
         (define kf (cpp-struct-map-key-field model f))
         (define vf (cpp-struct-map-val-field model f))
         (fprintf out "            std::size_t off = Get32(data, ~a); std::size_t n = Get32(data, ~a);\n" foff (+ foff 4))
         (fprintf out "            std::size_t p = off;\n            for (std::size_t i = 0; i < n; i++) {\n")
         (fprintf out "                Check(data, p, 8);\n                std::size_t kl = Get32(data, p); std::size_t vl = Get32(data, p + 4); p += 8;\n                Check(data, p, kl + vl);\n")
         (fprintf out "                auto k = [&] { std::size_t io = p; return ~a; }();\n" (cpp-struct-value-expr/off model kf "kl" "io"))
         (fprintf out "                auto v = [&] { std::size_t io = p + kl; return ~a; }();\n" (cpp-struct-value-expr/off model vf "vl" "io"))
         (fprintf out "                ~a[k] = v;\n                p += kl + vl;\n            }\n            if (p > vend) { vend = p; }\n" mv)]
        [(= (hash-ref f 'label) 3)
         (fprintf out "            std::size_t off = Get32(data, ~a); std::size_t n = Get32(data, ~a);\n" foff (+ foff 4))
         (cond [(member t '(9 12))
                (fprintf out "            for (std::size_t i = 0; i < n; i++) {\n                std::size_t eo = Get32(data, off + 8 * i); std::size_t el = Get32(data, off + 8 * i + 4);\n                Check(data, eo, el);\n                ~a.push_back(~a);\n                if (eo + el > vend) { vend = eo + el; }\n            }\n"
                         mv (if (= t 9) "std::string(reinterpret_cast<const char*>(data.data() + eo), el)" "grpcdc::Bytes(data.begin() + eo, data.begin() + eo + el)"))]
               [(= t 11)
                (fprintf out "            for (std::size_t i = 0; i < n; i++) {\n                std::size_t eo = Get32(data, off + 8 * i); std::size_t el = Get32(data, off + 8 * i + 4);\n                if (el > 0) {\n                    Check(data, eo, el);\n                    ~a.push_back(~aStruct::Unmarshal(grpcdc::Bytes(data.begin() + eo, data.begin() + eo + el)));\n                    if (eo + el > vend) { vend = eo + el; }\n                }\n            }\n"
                         mv (string-replace (cpp-struct-class-name model f) "::" "_"))]
               [else
                (define esz (if (cpp-struct-fixed32-type? t) 4 8))
                (fprintf out "            Check(data, off, n * ~a);\n            for (std::size_t i = 0; i < n; i++) {\n                std::size_t eo = off + i * ~a;\n                ~a.push_back(~a);\n            }\n            if (off + n * ~a > vend) { vend = off + n * ~a; }\n"
                         esz esz mv (cpp-struct-scalar-value/off model f "eo") esz esz)])]
        [(= t 11)
         (fprintf out "            std::size_t off = Get32(data, ~a); std::size_t el = Get32(data, ~a);\n" foff (+ foff 4))
         (fprintf out "            Check(data, off, el);\n            ~a = ~aStruct::Unmarshal(grpcdc::Bytes(data.begin() + off, data.begin() + off + el));\n            if (off + el > vend) { vend = off + el; }\n" mv (string-replace (cpp-struct-class-name model f) "::" "_"))]
        [(member t '(9 12))
         (fprintf out "            std::size_t off = Get32(data, ~a); std::size_t el = Get32(data, ~a);\n" foff (+ foff 4))
         (fprintf out "            Check(data, off, el);\n")
         (if (= t 9)
             (fprintf out "            ~a = std::string(reinterpret_cast<const char*>(data.data() + off), el);\n" mv)
             (fprintf out "            ~a = grpcdc::Bytes(data.begin() + off, data.begin() + off + el);\n" mv))
         (fprintf out "            if (off + el > vend) { vend = off + el; }\n")]
        [else
         (fprintf out "            std::size_t off = ~a;\n            ~a = ~a;\n" foff mv
                  (cpp-struct-scalar-value/off model f "off"))])
  (get-output-string out))

(define (emit-cpp-struct-file file-model params)
  (and (equal? (hash-ref params 'struct_codec #f) "true")
       (hash-has-key? file-model 'messages)
       (let ()
         (define base (path->string (path-replace-extension
                                     (file-name-from-path (hash-ref file-model 'name)) "")))
         (define pkg (hash-ref file-model 'package))
         (define (walk msg)
           (if (hash-ref msg 'map-entry)
               '()
               (append (walk-nested msg) (list msg))))
         (define (walk-nested msg)
           (append-map walk (hash-ref msg 'nested)))
         (define all (append-map walk (hash-ref file-model 'messages)))
         (define content
           (string-append
            "// @generated by protoc-gen-grpc-dc-cpp. DO NOT EDIT.\n"
            (format "// source: ~a\n\n" (hash-ref file-model 'name))
            "#pragma once\n\n"
            (format "#include \"~a_messages.hpp\"\n\n" base)
            (format "namespace ~a {\n\n" (cpp-pb-ns pkg))
            "extern \"C\" {\n"
            "int grpcdc_struct_encode(const std::uint8_t*, std::size_t, const std::uint8_t*, std::size_t, const std::uint8_t*, std::size_t, std::uint8_t**, std::size_t*, char**);\n"
            "int grpcdc_struct_decode(const std::uint8_t*, std::size_t, const std::uint8_t*, std::size_t, const std::uint8_t*, std::size_t, std::uint8_t**, std::size_t*, char**);\n"
            "void grpcdc_struct_free(std::uint8_t*, std::size_t);\n"
            "void grpcdc_struct_error_free(char*);\n"
            "}\n\n"
            (format "namespace ~a {\n" (cpp-structdc-detail-name file-model))
            (format "inline const std::uint8_t kDescriptor[] = {~a};\n"
                    (string-join (for/list ([b (in-bytes (hash-ref file-model 'descriptor-set #""))]) (format "0x~x" b)) ","))
            "inline grpcdc::Bytes Transcode(bool encode, const char* type, const grpcdc::Bytes& input) {\n"
            "    std::uint8_t* out = nullptr; std::size_t out_len = 0; char* err = nullptr;\n"
            "    auto rc = encode\n"
            "        ? grpcdc_struct_encode(kDescriptor, sizeof(kDescriptor), reinterpret_cast<const std::uint8_t*>(type), std::strlen(type), input.data(), input.size(), &out, &out_len, &err)\n"
            "        : grpcdc_struct_decode(kDescriptor, sizeof(kDescriptor), reinterpret_cast<const std::uint8_t*>(type), std::strlen(type), input.data(), input.size(), &out, &out_len, &err);\n"
            "    if (rc != 0) { std::string msg = err ? err : \"struct codec transcode failed\"; grpcdc_struct_error_free(err); throw std::runtime_error(msg); }\n"
            "    grpcdc::Bytes result(out, out + out_len); grpcdc_struct_free(out, out_len); return result;\n"
            "}\n"
            (format "}  // namespace ~a\n\n" (cpp-structdc-detail-name file-model))
            (apply string-append
                   (map (lambda (m) (cpp-struct-message file-model m)) all))
            (format "}  // namespace ~a\n" (cpp-pb-ns pkg))))
         (cons (string-append base "_struct.hpp") content))))
