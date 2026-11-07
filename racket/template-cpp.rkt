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
            (format "}  // namespace ~a\n" (cpp-pb-ns pkg))))
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
  (define pb-file (emit-cpp-pb-file file-model))
  (if pb-file (list stub pb-file) stub))
