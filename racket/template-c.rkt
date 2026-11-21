#lang racket

;;; template-c.rkt — emitter body spliced into protoc-gen-grpc-dc-c.
;;;
;;; Generated C99 code: message types in <base>_messages.h
;;; (header-only, stdlib only) plus stubs in <base>_grpc_dc.h over
;;; the grpcdc C runtime. Mirrors the Zig emitter on the shared
;;; desc.rkt model: structs with marshal/unmarshal functions,
;;; statuses as values, streaming via explicit stream handles.

(require "spec.rkt" "desc.rkt" "segments.rkt")
(provide emit-c-file)

(define current-service (make-parameter ""))

(define (pascal sym)
  (apply string-append
         (for/list ([part (in-list (string-split (symbol->string sym) "[_.-]"))])
           (if (string=? part "")
               ""
               (string-append (string (char-upcase (string-ref part 0)))
                              (substring part 1))))))

(define (lower-first s)
  (if (string=? s "")
      s
      (string-append (string (char-downcase (string-ref s 0))) (substring s 1))))

(define (snake-case s) ; ServerStream -> server_stream
  (apply string-append
         (for/list ([c (in-string s)] [i (in-naturals)])
           (cond [(char-upper-case? c)
                  (string-append (if (= i 0) "" "_")
                                 (string (char-downcase c)))]
                 [else (string c)]))))

;; ---------------------------------------------------------------------------
;; C99 message types (<base>_messages.h): header-only structs with
;; <Msg>_init/_marshal/_unmarshal/_clear functions plus a
;; <Base>Pb wire-support block per proto file. Dependency-free
;; (C99 stdlib only). Mirrors the Zig emitter on the shared
;; desc.rkt model. Maps become arrays of generated entry structs;
;; nested messages/enums flatten with _ like the Dart emitter.
;; ---------------------------------------------------------------------------

(define c-pb-varint-types varint-scalar-types)
(define c-pb-fixed (fixed-scalar-table 'c))

(define (c-pb-resolve model type-name)
  (hash-ref (hash-ref model 'types) type-name
            (lambda () (error 'emit-c-pb-file "unresolved type ~a" type-name))))

(define (c-pb-rel pkg full)
  (define rel (if (and pkg (not (string=? pkg "")) (string-prefix? full (string-append pkg ".")))
                  (substring full (add1 (string-length pkg)))
                  full))
  (string-join (string-split rel ".") "_"))

(define (c-pb-entry-ref model entry)
  ;; Flattened C name for a message/enum entry. Cross-file types
  ;; keep the name their own generated header defines (the header
  ;; is included); C has no namespaces to qualify with.
  (c-pb-rel (hash-ref entry 'pkg)
            (if (eq? (hash-ref entry 'kind) 'enum)
                (hash-ref entry 'full)
                (hash-ref (hash-ref entry 'msg) 'full-name))))

(define (c-pb-entry-support entry)
  ;; Support prefix of the file defining entry (its <Base>Pb).
  (string-append (pascal (string->symbol (path->string (path-replace-extension (file-name-from-path (hash-ref entry 'file)) "")))) "Pb"))

(define (c-pb-scalar f) (scalar-type-entry 'c (hash-ref f 'type)))

(define (c-pb-msg-name model msg)
  (c-pb-rel (hash-ref model 'package) (hash-ref msg 'full-name)))

(define (c-pb-type model f support)
  (run-segments c-pb-type-program f "" model (list support)))
(define (c-pb-explicit-literal model f)
  (define lit (run-segments c-pb-explicit-literal-program f "" model))
  (and (not (string=? lit "")) lit))
(define (c-pb-default model f support)
  (run-segments c-pb-default-program f "" model (list support)))
(define (c-pb-varint-expr f v)
  (run-segments c-pb-varint-expr-program f "" #f (list v)))
(define (c-pb-varint-decode f v)
  (run-segments c-pb-varint-decode-program f "" #f (list v)))
(define (c-pb-nonzero f v)
  (run-segments c-pb-nonzero-program f "" #f (list v)))
(define (c-pb-encode-singular model f v indent support)
  (run-segments c-pb-encode-singular-program f "" model (list v indent support)))
(define (c-pb-encode-field model f support)
  (run-segments c-pb-encode-field-program f "" model (list support)))
(define (c-pb-decode-singular model f target src indent support)
  (run-segments c-pb-decode-singular-program f "" model (list target src indent support)))
(define (c-pb-grow-stmt model f v expr indent [support ""])
  (run-segments c-pb-grow-program f "" model (list v expr indent support)))
(define (c-pb-decode-case model f support)
  (run-segments c-pb-decode-case-program f "" model (list support)))
(define (c-pb-map-helpers model entry support)
  (run-segments c-pb-map-helpers-program entry "" model (list support)))
(define (c-pb-support support guard)
  (string-append
   (format "#ifndef ~a\n#define ~a\n\n" guard guard)
   "#include <stdbool.h>\n#include <stdint.h>\n#include <stdlib.h>\n#include <string.h>\n\n"
   (format "typedef struct { uint8_t *data; size_t len; } ~aBytes;\n\n" support)
   (format "static inline ~aBytes ~a_bytes_empty(void) { ~aBytes b; b.data = NULL; b.len = 0; return b; }\n" support support support)
   (format "static inline ~aBytes ~a_bytes_copy(const uint8_t *data, size_t len) { ~aBytes b; b.data = (uint8_t *)malloc(len ? len : 1); if (len) memcpy(b.data, data, len); b.len = len; return b; }\n" support support support)
   (format "static inline char *~a_strdup_bytes(const uint8_t *data, size_t len) { char *s = (char *)malloc(len + 1); if (len) memcpy(s, data, len); s[len] = 0; return s; }\n\n" support)
   (format "typedef struct { uint8_t *data; size_t len; size_t cap; } ~aWriter;\n\n" support)
   (format "static inline void ~a_writer_init(~aWriter *w) { w->data = NULL; w->len = 0; w->cap = 0; }\n" support support)
   (format "static inline void ~a_writer_free(~aWriter *w) { free(w->data); w->data = NULL; w->len = w->cap = 0; }\n" support support)
   (format "static inline void ~a_writer_reserve(~aWriter *w, size_t n) { if (w->len + n > w->cap) { size_t cap = w->cap ? w->cap * 2 : 64; while (cap < w->len + n) cap *= 2; w->data = (uint8_t *)realloc(w->data, cap); w->cap = cap; } }\n" support support)
   (format "static inline void ~a_writer_varint(~aWriter *w, uint64_t v) { ~a_writer_reserve(w, 10); while (v > 0x7f) { w->data[w->len++] = (uint8_t)((v & 0x7f) | 0x80); v >>= 7; } w->data[w->len++] = (uint8_t)v; }\n" support support support)
   (format "static inline void ~a_writer_tag(~aWriter *w, int field, int wire) { ~a_writer_varint(w, (uint64_t)((field << 3) | wire)); }\n" support support support)
   (format "static inline void ~a_writer_bytes_field(~aWriter *w, int field, const uint8_t *payload, size_t len) { ~a_writer_tag(w, field, 2); ~a_writer_varint(w, (uint64_t)len); ~a_writer_reserve(w, len); if (len) memcpy(w->data + w->len, payload, len); w->len += len; }\n" support support support support support)
   (format "static inline void ~a_writer_string_field(~aWriter *w, int field, const char *value) { if (!value || !value[0]) return; ~a_writer_bytes_field(w, field, (const uint8_t *)value, strlen(value)); }\n" support support support)
   (format "static inline void ~a_writer_raw(~aWriter *w, const uint8_t *payload, size_t len) { ~a_writer_reserve(w, len); if (len) memcpy(w->data + w->len, payload, len); w->len += len; }\n" support support support)
   (format "static inline void ~a_writer_fixed_u32(~aWriter *w, uint32_t v) { ~a_writer_reserve(w, 4); for (int i = 0; i < 4; i++) w->data[w->len++] = (uint8_t)((v >> (8 * i)) & 0xff); }\n" support support support)
   (format "static inline void ~a_writer_fixed_u64(~aWriter *w, uint64_t v) { ~a_writer_reserve(w, 8); for (int i = 0; i < 8; i++) w->data[w->len++] = (uint8_t)((v >> (8 * i)) & 0xff); }\n" support support support)
   (format "static inline void ~a_writer_fixed_i32(~aWriter *w, int32_t v) { ~a_writer_fixed_u32(w, (uint32_t)v); }\n" support support support)
   (format "static inline void ~a_writer_fixed_i64(~aWriter *w, int64_t v) { ~a_writer_fixed_u64(w, (uint64_t)v); }\n" support support support)
   (format "static inline void ~a_writer_fixed_f32(~aWriter *w, float v) { uint32_t u; memcpy(&u, &v, 4); ~a_writer_fixed_u32(w, u); }\n" support support support)
   (format "static inline void ~a_writer_fixed_f64(~aWriter *w, double v) { uint64_t u; memcpy(&u, &v, 8); ~a_writer_fixed_u64(w, u); }\n" support support support)
   (format "static inline float ~a_fixed_to_f32(uint32_t u) { float v; memcpy(&v, &u, 4); return v; }\n" support)
   (format "static inline double ~a_fixed_to_f64(uint64_t u) { double v; memcpy(&v, &u, 8); return v; }\n" support)
   (format "static inline ~aBytes ~a_writer_to_bytes(~aWriter *w) { ~aBytes b; b.data = w->data; b.len = w->len; w->data = NULL; w->len = w->cap = 0; return b; }\n\n" support support support support)
   (format "typedef struct { int number; int wire; uint64_t varint_value; ~aBytes bytes_value; uint64_t fixed_value; ~aBytes raw_value; } ~aField;\n\n" support support support)
   (format "typedef struct { const uint8_t *buf; size_t len; size_t pos; } ~aReader;\n\n" support)
   (format "static inline void ~a_reader_init(~aReader *r, const uint8_t *buf, size_t len) { r->buf = buf; r->len = len; r->pos = 0; }\n" support support)
   (format "static inline bool ~a_reader_done(const ~aReader *r) { return r->pos >= r->len; }\n" support support)
   (format "static inline uint64_t ~a_reader_varint(~aReader *r) { uint64_t result = 0; int shift = 0; while (1) { if (r->pos >= r->len) return result; uint8_t b = r->buf[r->pos++]; result |= (uint64_t)(b & 0x7f) << shift; if ((b & 0x80) == 0) return result; shift += 7; if (shift >= 64) return result; } }\n" support support)
   (format "static inline uint32_t ~a_reader_fixed_u32(~aReader *r) { uint32_t v = 0; for (int i = 0; i < 4; i++) { if (r->pos < r->len) v |= (uint32_t)r->buf[r->pos++] << (8 * i); } return v; }\n" support support)
   (format "static inline uint64_t ~a_reader_fixed_u64(~aReader *r) { uint64_t v = 0; for (int i = 0; i < 8; i++) { if (r->pos < r->len) v |= (uint64_t)r->buf[r->pos++] << (8 * i); } return v; }\n" support support)
   (format "static inline bool ~a_reader_next(~aReader *r, ~aField *field) {\n" support support support)
   "    if (r->pos >= r->len) return false;\n"
   "    size_t start = r->pos;\n"
   (format "    uint64_t tag = ~a_reader_varint(r); field->number = (int)(tag >> 3); field->wire = (int)(tag & 7);\n" support)
   "    field->varint_value = 0; field->fixed_value = 0; field->bytes_value.data = NULL; field->bytes_value.len = 0;\n"
   "    switch (field->wire) {\n"
   (format "        case 0: field->varint_value = ~a_reader_varint(r); break;\n" support)
   (format "        case 2: { uint64_t n = ~a_reader_varint(r); if (r->pos + (size_t)n > r->len) n = r->len - r->pos; field->bytes_value.data = (uint8_t *)(r->buf + r->pos); field->bytes_value.len = (size_t)n; r->pos += (size_t)n; break; }\n" support)
   "        case 1: field->bytes_value.data = (uint8_t *)(r->buf + r->pos); field->bytes_value.len = 8 <= r->len - r->pos ? 8 : r->len - r->pos; field->fixed_value = 0; for (size_t i = 0; i < field->bytes_value.len; i++) field->fixed_value |= (uint64_t)r->buf[r->pos + i] << (8 * i); r->pos += field->bytes_value.len; break;\n"
   "        case 5: field->bytes_value.data = (uint8_t *)(r->buf + r->pos); field->bytes_value.len = 4 <= r->len - r->pos ? 4 : r->len - r->pos; field->fixed_value = 0; for (size_t i = 0; i < field->bytes_value.len; i++) field->fixed_value |= (uint64_t)r->buf[r->pos + i] << (8 * i); r->pos += field->bytes_value.len; break;\n"
   "        default: return false;\n"
   "    }\n"
   "    field->raw_value.data = (uint8_t *)(r->buf + start); field->raw_value.len = r->pos - start;\n"
   "    return true;\n"
   "}\n\n"))

(define (c-pb-enum-decl model e name)
  (run-segments c-pb-enum-decl-program e "" model (list name)))
(define (c-pb-field-decls model msg support)
  (run-segments c-pb-field-decls-program msg "" model (list support)))
(define (c-pb-message-fns model msg support)
  (run-segments c-pb-message-program msg "" model (list support)))
(define (c-pb-collect model)
  ;; Returns (values entry-structs map-helpers all-messages all-enums)
  (define entries (make-hash))
  (define helpers '())
  (define (collect msg)
    (for ([f (in-list (hash-ref msg 'fields))])
      (when (= (hash-ref f 'type) 11)
        (define e (c-pb-resolve model (hash-ref f 'type-name)))
        (when (and (eq? (hash-ref e 'kind) 'map)
                   (not (hash-has-key? entries (hash-ref (hash-ref e 'msg) 'full-name))))
          (hash-set! entries (hash-ref (hash-ref e 'msg) 'full-name) e)
          (set! helpers (cons e helpers)))))
    (for ([n (in-list (hash-ref msg 'nested))]) (collect n)))
  (for ([m (in-list (hash-ref model 'messages))]) (collect m))
  (values (reverse helpers)))

(define (c-pb-all-messages model)
  (define (walk msg)
    (if (hash-ref msg 'map-entry)
        '()
        (cons msg (append-map walk (hash-ref msg 'nested)))))
  (append-map walk (hash-ref model 'messages)))

(define (c-pb-all-enums model)
  (define (walk msg)
    (append (map (lambda (e) (cons e (c-pb-msg-name model msg))) (hash-ref msg 'enums))
            (append-map walk (hash-ref msg 'nested))))
  (append (map (lambda (e) (cons e #f)) (hash-ref model 'enums))
          (append-map walk (hash-ref model 'messages))))

(define (emit-c-pb-file file-model)
  (and (hash-has-key? file-model 'messages)
       (hash-has-key? file-model 'types)
       (emit-c-pb-file/inner file-model)))

(define (emit-c-pb-file/inner file-model)
  (define messages (hash-ref file-model 'messages))
  (define enums (hash-ref file-model 'enums))
  (and (or (pair? messages) (pair? enums))
       (let ()
         (define base (path->string (path-replace-extension
                                     (file-name-from-path (hash-ref file-model 'name)) "")))
         (define support (string-append (pascal (string->symbol base)) "Pb"))
         (define guard (format "GRPCDC_~a_MESSAGES_H" (string-upcase base)))
         (define map-entries (c-pb-collect file-model))
         (define all-msgs (c-pb-all-messages file-model))
         (define all-enums (c-pb-all-enums file-model))
         (define content
           (string-append
            "// @generated by protoc-gen-grpc-dc-c. DO NOT EDIT.\n"
            (c-pb-support support guard)
            ;; dependency message headers (complete types for
            ;; cross-file fields and map entry values)
            (apply string-append
                   (map (lambda (d)
                          (format "#include \"~a_messages.h\"\n" (path->string (path-replace-extension (file-name-from-path d) ""))))
                        (hash-ref file-model 'dependencies)))
            (if (null? (hash-ref file-model 'dependencies)) "" "\n")
            ;; enum typedefs (fields hold them by value)
            (apply string-append
                   (map (lambda (pair)
                          (define e (car pair))
                          (define parent (cdr pair))
                          (c-pb-enum-decl file-model e (if parent (format "~a_~a" parent (hash-ref e 'name)) (hash-ref e 'name))))
                        all-enums))
            ;; forward typedefs (fields point at later types)
            (apply string-append
                   (map (lambda (m) (format "typedef struct ~a ~a;\n" (c-pb-msg-name file-model m) (c-pb-msg-name file-model m))) all-msgs))
            (apply string-append
                   (map (lambda (e) (format "typedef struct ~a ~a;\n" (c-pb-entry-ref file-model e) (c-pb-entry-ref file-model e))) map-entries))
            "\n"
            ;; message struct definitions
            (apply string-append
                   (map (lambda (m)
                          (string-append
                           (format "struct ~a {\n" (c-pb-msg-name file-model m))
                           (c-pb-field-decls file-model m support)
                           (format "    ~aBytes unknown_fields;\n};\n\n" support)))
                        all-msgs))
            ;; map entry struct definitions
            (apply string-append
                   (map (lambda (e)
                          (define em (hash-ref e 'msg))
                          (define kf (findf (lambda (x) (= (hash-ref x 'number) 1)) (hash-ref em 'fields)))
                          (define vf (findf (lambda (x) (= (hash-ref x 'number) 2)) (hash-ref em 'fields)))
                          (format "struct ~a { ~a key; ~a value; };\n\n"
                                  (c-pb-entry-ref file-model e)
                                  (c-pb-type file-model (hash-set kf 'label 1) support)
                                  (if (= (hash-ref vf 'type) 11)
                                      (c-pb-entry-ref file-model (c-pb-resolve file-model (hash-ref vf 'type-name)))
                                      (c-pb-type file-model (hash-set vf 'label 1) support))))
                        map-entries))
            ;; function prototypes
            (apply string-append
                   (map (lambda (m)
                          (define name (c-pb-msg-name file-model m))
                          (format "static inline void ~a_init(~a *m);\nstatic inline ~aBytes ~a_marshal(const ~a *m);\nstatic inline void ~a_unmarshal(~a *m, const uint8_t *data, size_t len);\n"
                                  name name support name name name name))
                        all-msgs))
            "\n"
            ;; map helpers
            (apply string-append (map (lambda (e) (c-pb-map-helpers file-model e support)) map-entries))
            ;; message functions
            (apply string-append (map (lambda (m) (c-pb-message-fns file-model m support)) all-msgs))
            (format "#endif /* ~a */\n" guard)))
         (cons (string-append base "_messages.h") content))))

;; ---------------------------------------------------------------------------
;; C99 stubs (<base>_grpc_dc.h): header-only client structs and
;; server registration over the grpcdc C runtime. The runtime is
;; bytes-level; generated adapters marshal/unmarshal via the
;; generated message functions. Streaming uses explicit stream
;; handles with recv returning 1 (message) / 0 (end) / -1 (status).
;; ---------------------------------------------------------------------------

(define (c-type-ref model full)
  (c-pb-entry-ref model (c-pb-resolve model full)))

(define (c-deprecated m indent)
  (run-segments c-deprecated-program m "" #f (list indent)))
(define (c-client-method model m support)
  (run-segments c-client-method-program m (current-service) model (list support)))
(define (c-server-types model m support)
  (run-segments c-server-types-program m (current-service) model (list support)))
(define (c-server-impl-field model m)
  (run-segments c-server-impl-field-program m (current-service) model))
(define (c-server-adapter model m support)
  (run-segments c-server-adapter-program m (current-service) model (list support)))
(define (c-service model svc support)
  (run-segments c-service-program svc (hash-ref svc 'name) model (list support)))
(define (emit-c-file file-model params)
  (define base (path->string (path-replace-extension
                              (file-name-from-path (hash-ref file-model 'name)) "")))
  (define support (string-append (pascal (string->symbol base)) "Pb"))
  (define guard (format "GRPCDC_~a_GRPC_DC_H" (string-upcase base)))
  (define stub
    (cons (string-append base "_grpc_dc.h")
          (string-append
           "// @generated by protoc-gen-grpc-dc-c. DO NOT EDIT.\n"
           (format "// source: ~a\n\n" (hash-ref file-model 'name))
           (format "#ifndef ~a\n#define ~a\n\n" guard guard)
           "#include \"grpcdc/grpcdc.h\"\n"
           (apply string-append
                  (map (lambda (d) (format "#include \"~a_messages.h\"\n" (path->string (path-replace-extension (file-name-from-path d) ""))))
                       (hash-ref file-model 'dependencies)))
           (if (emit-c-pb-file file-model) (format "#include \"~a_messages.h\"\n" base) "")
           (if (equal? (hash-ref params 'struct_codec #f) "true") (format "#include \"~a_struct.h\"\n" base) "")
           ;; trace=hooks: apply the baked filter from a generated
           ;; initializer the caller invokes once.
           (if (equal? (hash-ref params 'trace #f) "hooks")
               (let ([methods (hash-ref params 'trace_methods #f)])
                 (if methods
                     (format "\n/* Tracing (trace=hooks@@TRACING_BETA@@): call once at startup to apply\n   the baked trace_methods filter. */\nstatic inline void grpcdc_~a_apply_trace_filter(void) {\n    grpcdc_set_trace_filter(~s);\n}\n" base methods)
                     "\n/* Tracing (trace=hooks@@TRACING_BETA@@): register an observer via\n   grpcdc_set_tracer (grpcdc/grpcdc.h). */\n"))
               "")
           "\n"
           (parameterize ([seg-struct-codec (equal? (hash-ref params 'struct_codec #f) "true")])
             (apply string-append
                    (map (lambda (svc) (c-service file-model svc support)) (hash-ref file-model 'services))))
           (format "#endif /* ~a */\n" guard))))
  (define pb-file (emit-c-pb-file file-model))
  (define struct-file (emit-c-struct-file file-model params))
  (if struct-file
      (append (list stub pb-file) (list struct-file))
      (if pb-file (list stub pb-file) stub)))

;; ------------------------------------------------------------------
;; Struct codec (struct_codec=true): <Msg>_struct_size/_marshal/
;; _unmarshal functions per message in <base>_struct.h with the
;; packed layout from SPEC.md (byte-identical to the other struct
;; codecs; verified by conformance/struct).
(define (c-struct-fingerprint s)
  (for/fold ([h 2166136261]) ([c (in-string s)])
    (modulo (* (bitwise-xor h (char->integer c)) 16777619) 4294967296)))

(define (c-struct-fixed32-type? t) (member t '(2 7 15)))
(define (c-struct-fixed64-type? t) (member t '(1 6 16)))

(define (c-struct-slot-size f)
  (if (c-struct-fixed32-type? (hash-ref f 'type)) 4 8))

(define (c-struct-sorted-fields msg)
  (sort (hash-ref msg 'fields) < #:key (lambda (f) (hash-ref f 'number))))

(define (c-struct-map-entry model f)
  (and (= (hash-ref f 'type) 11)
       (let ([e (c-pb-resolve model (hash-ref f 'type-name))])
         (and (eq? (hash-ref e 'kind) 'map) e))))

(define (c-struct-map-key-field model f)
  (define em (hash-ref (c-struct-map-entry model f) 'msg))
  (findf (lambda (x) (= (hash-ref x 'number) 1)) (hash-ref em 'fields)))
(define (c-struct-map-val-field model f)
  (define em (hash-ref (c-struct-map-entry model f) 'msg))
  (findf (lambda (x) (= (hash-ref x 'number) 2)) (hash-ref em 'fields)))

(define (c-struct-msg-name model msg)
  (c-pb-rel (hash-ref model 'package) (hash-ref msg 'full-name)))

(define (c-struct-class-name model f)
  (define e (c-pb-resolve model (hash-ref f 'type-name)))
  (c-struct-msg-name model (hash-ref e 'msg)))

(define (c-struct-entry-name model f)
  (c-pb-entry-ref model (c-pb-resolve model (hash-ref f 'type-name))))

(define (c-struct-elem-ctype model f support)
  (define t (hash-ref f 'type))
  (cond [(= t 9) "char *"]
        [(= t 12) (format "~aBytes" support)]
        [(= t 11) (c-struct-entry-name model f)]
        [(= t 14) (c-pb-entry-ref model (c-pb-resolve model (hash-ref f 'type-name)))]
        [else (first (c-pb-scalar f))]))

(define (c-struct-present model f fn)
  (define t (hash-ref f 'type))
  (cond [(c-struct-map-entry model f) (format "m->~a_count > 0" fn)]
        [(= (hash-ref f 'label) 3) (format "m->~a_count > 0" fn)]
        [(= t 11) (format "m->~a != NULL" fn)]
        [(= t 9) (format "(m->~a != NULL && m->~a[0] != 0)" fn fn)]
        [(= t 12) (format "m->~a.len > 0" fn)]
        [(= t 8) (format "m->~a" fn)]
        [else (format "m->~a != 0" fn)]))

;; scalar encode statement writing v at buf[off]
(define (c-struct-scalar-encode model f v)
  (define t (hash-ref f 'type))
  (define P (c-struct-prefix))
  (cond [(c-struct-fixed32-type? t)
         (if (= t 2)
             (format "{ float fv = ~a; uint32_t u; memcpy(&u, &fv, 4); ~aPut32(buf, off, u); }" v P)
             (format "~aPut32(buf, off, (uint32_t)(~a));" P v))]
        [(c-struct-fixed64-type? t)
         (if (= t 1)
             (format "{ double fv = ~a; uint64_t u; memcpy(&u, &fv, 8); ~aPut64(buf, off, u); }" v P)
             (format "~aPut64(buf, off, (uint64_t)(~a));" P v))]
        [(= t 8) (format "buf[off] = (~a) ? 1 : 0;" v)]
        [(= t 14) (format "~aPut64(buf, off, (uint64_t)(int64_t)(~a));" P v)]
        [(member t '(3 16 18)) (format "~aPut64(buf, off, (uint64_t)(int64_t)(~a));" P v)]
        [else (format "~aPut64(buf, off, (uint64_t)(~a));" P v)]))

(define c-struct-prefix (make-parameter "MsgsStruct"))
(define c-struct-support (make-parameter "MsgsPb"))

;; expression reading a scalar of f's type at data[offv]
(define (c-struct-scalar-value/off model f offv)
  (define t (hash-ref f 'type))
  (define P (c-struct-prefix))
  (cond [(c-struct-fixed32-type? t)
         (if (= t 2)
             (format "~a_fixed_to_f32(~aGet32(data, ~a))" (c-struct-support) P offv)
             (format "(~a)~aGet32(data, ~a)" (first (c-pb-scalar f)) P offv))]
        [(c-struct-fixed64-type? t)
         (if (= t 1)
             (format "~a_fixed_to_f64(~aGet64(data, ~a))" (c-struct-support) P offv)
             (format "(~a)~aGet64(data, ~a)" (first (c-pb-scalar f)) P offv))]
        [(= t 8) (format "(data[~a] != 0)" offv)]
        [(= t 14) (format "(~a)~aGet64(data, ~a)"
                          (c-pb-entry-ref model (c-pb-resolve model (hash-ref f 'type-name))) P offv)]
        [(member t '(3 16 18)) (format "(~a)(int64_t)~aGet64(data, ~a)" (first (c-pb-scalar f)) P offv)]
        [(member t '(5 15 17)) (format "(~a)(int32_t)~aGet64(data, ~a)" (first (c-pb-scalar f)) P offv)]
        [else (format "(~a)~aGet64(data, ~a)" (first (c-pb-scalar f)) P offv)]))

(define (c-struct-value-size model f v support)
  (define t (hash-ref f 'type))
  (cond [(= t 9) (format "(~a ? strlen(~a) : 0)" v v)]
        [(= t 12) (format "~a.len" v)]
        [(= t 11) (format "~a_struct_size(&~a)" (c-struct-class-name model f) v)]
        [(c-struct-fixed32-type? t) "4"]
        [else "8"]))

(define (c-struct-message model msg support)
  (define name (c-struct-msg-name model msg))
  (define full (hash-ref msg 'full-name))
  (define P (c-struct-prefix))
  (define out (open-output-string))
  (fprintf out "static inline size_t ~a_struct_size(const ~a *m) {\n    ~aBytes b = ~a_struct_marshal(m);\n    size_t n = b.len;\n    free(b.data);\n    return n;\n}\n\n" name name support name)
  (fprintf out "static inline void ~a_struct_write(const ~a *m, uint8_t *buf) {\n    ~aBytes b = ~a_struct_marshal(m);\n    if (b.len) memcpy(buf, b.data, b.len);\n    free(b.data);\n}\n\n" name name support name)
  (fprintf out "static inline ~aBytes ~a_struct_marshal(const ~a *m) {\n    ~aBytes pb = ~a_marshal(m);\n    uint8_t *out = NULL;\n    size_t out_len = 0;\n    char *err = NULL;\n    if (grpcdc_struct_encode(~aDescriptor, ~aDescriptorLen, (const uint8_t *)\"~a\", ~a, pb.data, pb.len, &out, &out_len, &err) != 0) {\n        fprintf(stderr, \"struct codec encode failed: %s\\n\", err ? err : \"unknown\");\n        grpcdc_struct_error_free(err);\n        free(pb.data);\n        abort();\n    }\n    free(pb.data);\n    ~aBytes b;\n    b.data = out;\n    b.len = out_len;\n    return b;\n}\n\n"
           support name name support name P P full (string-length full) support)
  (fprintf out "static inline bool ~a_struct_unmarshal(~a *m, const uint8_t *data, size_t len) {\n    uint8_t *pb = NULL;\n    size_t pb_len = 0;\n    char *err = NULL;\n    if (grpcdc_struct_decode(~aDescriptor, ~aDescriptorLen, (const uint8_t *)\"~a\", ~a, data, len, &pb, &pb_len, &err) != 0) {\n        grpcdc_struct_error_free(err);\n        return false;\n    }\n    ~a_unmarshal(m, pb, pb_len);\n    grpcdc_struct_free(pb, pb_len);\n    return true;\n}\n\n"
           name name P P full (string-length full) name)
  (get-output-string out))

(define (c-struct-value-write model f v support)
  ;; v is an lvalue expression for the value; writes at buf+vp.
  (define t (hash-ref f 'type))
  (define out (open-output-string))
  (cond [(= t 9)
         (fprintf out "                { const char *sv = ~a; size_t sl = sv ? strlen(sv) : 0; if (sl) memcpy(buf + vp, sv, sl); vp += sl; }\n" v)]
        [(= t 12)
         (fprintf out "                if (~a.len) memcpy(buf + vp, ~a.data, ~a.len); vp += ~a.len;\n" v v v)]
        [(= t 11)
         (fprintf out "                ~a_struct_write(&~a, buf + vp); vp += ~a_struct_size(&~a);\n"
                  (c-struct-class-name model f) v (c-struct-class-name model f) v)]
        [else
         (fprintf out "                { size_t off = vp; ~a } vp += ~a;\n"
                  (c-struct-scalar-encode model f v) (if (c-struct-fixed32-type? t) 4 8))])
  (get-output-string out))

(define (c-struct-marshal-field model f off support)
  (define fn (hash-ref f 'name))
  (define t (hash-ref f 'type))
  (define P (c-struct-prefix))
  (define out (open-output-string))
  (define mv (format "m->~a" fn))
  (cond [(c-struct-map-entry model f)
         (define kf (c-struct-map-key-field model f))
         (define vf (c-struct-map-val-field model f))
         (define entry (c-struct-entry-name model f))
         (fprintf out "    if (m->~a_count > 0) {\n        ~aPut32(buf, ~a, (uint32_t)vp); ~aPut32(buf, ~a, (uint32_t)m->~a_count);\n" fn P off P (+ off 4) fn)
         (fprintf out "        const ~a **ord = (const ~a **)malloc(sizeof(*ord) * m->~a_count);\n        for (size_t i = 0; i < m->~a_count; i++) ord[i] = &m->~a[i];\n        qsort(ord, m->~a_count, sizeof(*ord), ~a_~a_struct_cmp);\n"
                  entry entry fn fn fn fn (c-struct-msg-name model (current-struct-msg)) fn)
         (fprintf out "        for (size_t i = 0; i < m->~a_count; i++) {\n            const ~a *e = ord[i];\n            ~aPut32(buf, vp, (uint32_t)~a); ~aPut32(buf, vp + 4, (uint32_t)~a); vp += 8;\n"
                  fn entry P (c-struct-value-size model kf "e->key" support) P (c-struct-value-size model vf "e->value" support))
         (display (c-struct-value-write model kf "e->key" support) out)
         (display (c-struct-value-write model vf "e->value" support) out)
         (fprintf out "        }\n        free(ord);\n    }\n")]
        [(= (hash-ref f 'label) 3)
         (cond [(member t '(9 12))
                (fprintf out "    if (m->~a_count > 0) {\n        ~aPut32(buf, ~a, (uint32_t)vp); ~aPut32(buf, ~a, (uint32_t)m->~a_count);\n        size_t doff = vp + 8 * m->~a_count;\n        for (size_t i = 0; i < m->~a_count; i++) { ~aPut32(buf, vp, (uint32_t)doff); ~aPut32(buf, vp + 4, (uint32_t)~a); doff += ~a; vp += 8; }\n        for (size_t i = 0; i < m->~a_count; i++) { ~a }\n    }\n"
                         fn P off P (+ off 4) fn fn fn P P
                         (if (= t 9) (format "strlen(m->~a[i])" fn) (format "m->~a[i].len" fn))
                         (if (= t 9) (format "strlen(m->~a[i])" fn) (format "m->~a[i].len" fn))
                         fn
                         (if (= t 9) (format "{ const char *sv = m->~a[i]; size_t sl = strlen(sv); if (sl) memcpy(buf + vp, sv, sl); vp += sl; }" fn)
                             (format "if (m->~a[i].len) memcpy(buf + vp, m->~a[i].data, m->~a[i].len); vp += m->~a[i].len;" fn fn fn)))]
               [(= t 11)
                (fprintf out "    if (m->~a_count > 0) {\n        ~aPut32(buf, ~a, (uint32_t)vp); ~aPut32(buf, ~a, (uint32_t)m->~a_count);\n        size_t doff = vp + 8 * m->~a_count;\n        for (size_t i = 0; i < m->~a_count; i++) { size_t es = ~a_struct_size(&m->~a[i]); ~aPut32(buf, vp, (uint32_t)doff); ~aPut32(buf, vp + 4, (uint32_t)es); doff += es; vp += 8; }\n        for (size_t i = 0; i < m->~a_count; i++) { ~a_struct_write(&m->~a[i], buf + vp); vp += ~a_struct_size(&m->~a[i]); }\n    }\n"
                         fn P off P (+ off 4) fn fn fn (c-struct-class-name model f) fn P P
                         fn (c-struct-class-name model f) fn (c-struct-class-name model f) fn)]
               [else
                (fprintf out "    if (m->~a_count > 0) {\n        ~aPut32(buf, ~a, (uint32_t)vp); ~aPut32(buf, ~a, (uint32_t)m->~a_count);\n        for (size_t i = 0; i < m->~a_count; i++) { size_t off = vp; ~a vp += ~a; }\n    }\n"
                         fn P off P (+ off 4) fn
                         fn
                         (c-struct-scalar-encode model f (format "m->~a[i]" fn))
                         (if (c-struct-fixed32-type? t) 4 8))])]
        [(= t 11)
         (fprintf out "    if (m->~a) {\n        ~aPut32(buf, ~a, (uint32_t)vp); ~aPut32(buf, ~a, (uint32_t)~a_struct_size(m->~a));\n        ~a_struct_write(m->~a, buf + vp); vp += ~a_struct_size(m->~a);\n    }\n"
                  fn P off P (+ off 4) (c-struct-class-name model f) fn
                  (c-struct-class-name model f) fn (c-struct-class-name model f) fn)]
        [(member t '(9 12))
         (fprintf out "    if (~a) {\n        ~aPut32(buf, ~a, (uint32_t)vp); ~aPut32(buf, ~a, (uint32_t)~a);\n        ~a\n    }\n"
                  (if (= t 9) (format "(m->~a && m->~a[0])" fn fn) (format "m->~a.len > 0" fn))
                  P off P (+ off 4)
                  (if (= t 9) (format "strlen(m->~a)" fn) (format "m->~a.len" fn))
                  (if (= t 9)
                      (format "{ const char *sv = m->~a; size_t sl = strlen(sv); if (sl) memcpy(buf + vp, sv, sl); vp += sl; }" fn)
                      (format "memcpy(buf + vp, m->~a.data, m->~a.len); vp += m->~a.len;" fn fn fn)))]
        [else
         (fprintf out "    { size_t off = ~a; ~a }\n" off (c-struct-scalar-encode model f mv))])
  (get-output-string out))

(define current-struct-msg (make-parameter #f))

(define (c-struct-value-expr/off model f lenvar offv support)
  (define t (hash-ref f 'type))
  (define P (c-struct-prefix))
  (cond [(= t 9) (format "~a_strdup_bytes(data + ~a, ~a)" support offv lenvar)]
        [(= t 12) (format "~a_bytes_copy(data + ~a, ~a)" support offv lenvar)]
        [(= t 11) (format "({ ~a *np = NULL; if (~a > 0) { np = (~a *)malloc(sizeof(*np)); memset(np, 0, sizeof(*np)); ~a_struct_unmarshal(np, data + ~a, ~a); } np; })"
                          (c-struct-class-name model f) lenvar (c-struct-class-name model f)
                          (c-struct-class-name model f) offv lenvar)]
        [else (c-struct-scalar-value/off model f offv)]))

(define (c-struct-decode-field model f foff support)
  (define fn (hash-ref f 'name))
  (define t (hash-ref f 'type))
  (define P (c-struct-prefix))
  (define out (open-output-string))
  (define mv (format "m->~a" fn))
  (cond [(c-struct-map-entry model f)
         (define kf (c-struct-map-key-field model f))
         (define vf (c-struct-map-val-field model f))
         (define entry (c-struct-entry-name model f))
         (fprintf out "        size_t off = ~aGet32(data, ~a); size_t n = ~aGet32(data, ~a);\n" P foff P (+ foff 4))
         (fprintf out "        size_t p = off;\n        m->~a = (~a *)malloc(sizeof(~a) * (n ? n : 1)); m->~a_count = n;\n        for (size_t i = 0; i < n; i++) {\n" fn entry entry fn)
         (fprintf out "            if (p + 8 > len) return false;\n            size_t kl = ~aGet32(data, p); size_t vl = ~aGet32(data, p + 4); p += 8;\n            if (p + kl + vl > len) return false;\n" P P)
         ;; value assignment: msg values are structs by value
         (define vt (hash-ref vf 'type))
         (cond [(= vt 11)
                (fprintf out "            { size_t io = p; m->~a[i].key = ~a; }\n" fn (c-struct-value-expr/off model kf "kl" "io" support))
                (fprintf out "            memset(&m->~a[i].value, 0, sizeof(m->~a[i].value));\n            if (vl > 0) { if (!~a_struct_unmarshal(&m->~a[i].value, data + p + kl, vl)) return false; }\n" fn fn (c-struct-class-name model vf) fn)]
               [else
                (fprintf out "            { size_t io = p; m->~a[i].key = ~a; }\n            { size_t io = p + kl; m->~a[i].value = ~a; }\n"
                         fn (c-struct-value-expr/off model kf "kl" "io" support)
                         fn (c-struct-value-expr/off model vf "vl" "io" support))])
         (fprintf out "            p += kl + vl;\n        }\n        if (p > vend) vend = p;\n")]
        [(= (hash-ref f 'label) 3)
         (define et (c-struct-elem-ctype model f support))
         (fprintf out "        size_t off = ~aGet32(data, ~a); size_t n = ~aGet32(data, ~a);\n" P foff P (+ foff 4))
         (fprintf out "        m->~a = (~a *)malloc(sizeof(~a) * (n ? n : 1)); m->~a_count = n;\n" fn et et fn)
         (cond [(member t '(9 12))
                (fprintf out "        for (size_t i = 0; i < n; i++) {\n            size_t eo = ~aGet32(data, off + 8 * i); size_t el = ~aGet32(data, off + 8 * i + 4);\n            if (eo + el > len) return false;\n            m->~a[i] = ~a;\n            if (eo + el > vend) vend = eo + el;\n        }\n"
                         P P fn (c-struct-value-expr/off model f "el" "eo" support))]
               [(= t 11)
                (fprintf out "        for (size_t i = 0; i < n; i++) {\n            size_t eo = ~aGet32(data, off + 8 * i); size_t el = ~aGet32(data, off + 8 * i + 4);\n            memset(&m->~a[i], 0, sizeof(m->~a[i]));\n            if (el > 0) {\n                if (eo + el > len) return false;\n                if (!~a_struct_unmarshal(&m->~a[i], data + eo, el)) return false;\n                if (eo + el > vend) vend = eo + el;\n            }\n        }\n"
                         P P fn fn (c-struct-class-name model f) fn)]
               [else
                (define esz (if (c-struct-fixed32-type? t) 4 8))
                (fprintf out "        if (off + n * ~a > len) return false;\n        for (size_t i = 0; i < n; i++) {\n            size_t eo = off + i * ~a;\n            m->~a[i] = ~a;\n        }\n        if (off + n * ~a > vend) vend = off + n * ~a;\n"
                         esz esz fn (c-struct-scalar-value/off model f "eo") esz esz)])]
        [(= t 11)
         (fprintf out "        size_t off = ~aGet32(data, ~a); size_t el = ~aGet32(data, ~a);\n" P foff P (+ foff 4))
         (fprintf out "        if (off + el > len) return false;\n        m->~a = (~a *)malloc(sizeof(*m->~a)); memset(m->~a, 0, sizeof(*m->~a));\n        if (el > 0) { if (!~a_struct_unmarshal(m->~a, data + off, el)) return false; }\n        if (off + el > vend) vend = off + el;\n"
                  fn (c-struct-class-name model f) fn fn fn (c-struct-class-name model f) fn)]
        [(member t '(9 12))
         (fprintf out "        size_t off = ~aGet32(data, ~a); size_t el = ~aGet32(data, ~a);\n" P foff P (+ foff 4))
         (fprintf out "        if (off + el > len) return false;\n")
         (if (= t 9)
             (fprintf out "        m->~a = ~a;\n" fn (c-struct-value-expr/off model f "el" "off" support))
             (fprintf out "        m->~a = ~a;\n" fn (c-struct-value-expr/off model f "el" "off" support)))
         (fprintf out "        if (off + el > vend) vend = off + el;\n")]
        [else
         (fprintf out "        { size_t off = ~a; m->~a = ~a; }\n" foff fn
                  (c-struct-scalar-value/off model f "off"))])
  (get-output-string out))

(define (emit-c-struct-file file-model params)
  (and (equal? (hash-ref params 'struct_codec #f) "true")
       (hash-has-key? file-model 'messages)
       (let ()
         (define base (path->string (path-replace-extension
                                     (file-name-from-path (hash-ref file-model 'name)) "")))
         (define support (string-append (pascal (string->symbol base)) "Pb"))
         (define prefix (string-append (pascal (string->symbol base)) "Struct"))
         (define guard (format "GRPCDC_~a_STRUCT_H" (string-upcase base)))
         (define all-msgs (c-pb-all-messages file-model))
         (define descriptor (hash-ref file-model 'descriptor-set #""))
         (parameterize ([c-struct-prefix prefix] [c-struct-support support])
           (define content
             (string-append
              "// @generated by protoc-gen-grpc-dc-c. DO NOT EDIT.\n"
              (format "// source: ~a\n\n" (hash-ref file-model 'name))
              (format "#ifndef ~a\n#define ~a\n\n" guard guard)
              (format "#include \"~a_messages.h\"\n" base)
              "#include <stdio.h>\n\n"
              "/* Shared Rust struct codec (libgrpc_dc): protobuf <-> struct transcode. */\n"
              "int grpcdc_struct_encode(const uint8_t *desc, size_t desc_len, const uint8_t *type_name, size_t type_len, const uint8_t *input, size_t input_len, uint8_t **out, size_t *out_len, char **err_out);\n"
              "int grpcdc_struct_decode(const uint8_t *desc, size_t desc_len, const uint8_t *type_name, size_t type_len, const uint8_t *input, size_t input_len, uint8_t **out, size_t *out_len, char **err_out);\n"
              "void grpcdc_struct_free(uint8_t *ptr, size_t len);\n"
              "void grpcdc_struct_error_free(char *ptr);\n\n"
              (format "static const uint8_t ~aDescriptor[] = {~a};\n" prefix
                      (string-join (for/list ([b (in-bytes descriptor)]) (format "0x~x" b)) ","))
              (format "static const size_t ~aDescriptorLen = ~a;\n\n" prefix (bytes-length descriptor))
              (apply string-append
                     (map (lambda (m)
                            (define name (c-struct-msg-name file-model m))
                            (format "static inline size_t ~a_struct_size(const ~a *m);\nstatic inline void ~a_struct_write(const ~a *m, uint8_t *buf);\nstatic inline ~aBytes ~a_struct_marshal(const ~a *m);\nstatic inline bool ~a_struct_unmarshal(~a *m, const uint8_t *data, size_t len);\n"
                                    name name name name support name name name name))
                          all-msgs))
              "\n"
              (apply string-append
                     (map (lambda (m) (c-struct-message file-model m support)) all-msgs))
              (apply string-append
                     (map (lambda (m)
                            (define name (c-struct-msg-name file-model m))
                            (format "static inline ~aBytes ~a_marshal_for_codec(bool sc, const ~a *m) { return sc ? ~a_struct_marshal(m) : ~a_marshal(m); }\nstatic inline void ~a_unmarshal_for_codec(bool sc, ~a *m, const uint8_t *data, size_t len) { if (sc) { ~a_struct_unmarshal(m, data, len); } else { ~a_unmarshal(m, data, len); } }\n"
                                    support name name name name name name name name))
                          all-msgs))
              (format "#endif /* ~a */\n" guard)))
           (cons (string-append base "_struct.h") content)))))
