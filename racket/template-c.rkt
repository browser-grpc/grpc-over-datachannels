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
           ;; trace=hooks: apply the baked filter from a generated
           ;; initializer the caller invokes once.
           (if (equal? (hash-ref params 'trace #f) "hooks")
               (let ([methods (hash-ref params 'trace_methods #f)])
                 (if methods
                     (format "\n/* Tracing (trace=hooks): call once at startup to apply\n   the baked trace_methods filter. */\nstatic inline void grpcdc_~a_apply_trace_filter(void) {\n    grpcdc_set_trace_filter(~s);\n}\n" base methods)
                     "\n/* Tracing (trace=hooks): register an observer via\n   grpcdc_set_tracer (grpcdc/grpcdc.h). */\n"))
               "")
           "\n"
           (apply string-append
                  (map (lambda (svc) (c-service file-model svc support)) (hash-ref file-model 'services)))
           (format "#endif /* ~a */\n" guard))))
  (define pb-file (emit-c-pb-file file-model))
  (if pb-file (list stub pb-file) stub))
