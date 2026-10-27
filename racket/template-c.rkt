#lang racket

;;; template-c.rkt — emitter body spliced into protoc-gen-grpc-dc-c.
;;;
;;; Generated C99 code: message types in <base>_messages.h
;;; (header-only, stdlib only) plus stubs in <base>_grpc_dc.h over
;;; the grpcdc C runtime. Mirrors the Zig emitter on the shared
;;; desc.rkt model: structs with marshal/unmarshal functions,
;;; statuses as values, streaming via explicit stream handles.

(require "spec.rkt" "desc.rkt")
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

(define (c-pb-scalar f)
  (case (hash-ref f 'type)
    [(1) '("double" "0")] [(2) '("float" "0")] [(3) '("int64_t" "0")] [(4) '("uint64_t" "0")]
    [(5) '("int32_t" "0")] [(6) '("uint64_t" "0")] [(7) '("uint32_t" "0")] [(8) '("bool" "false")]
    [(9) '("char *" "\"\"")] [(12) '("~aBytes" "\"\"")] [(13) '("uint32_t" "0")]
    [(15) '("int32_t" "0")] [(16) '("int64_t" "0")] [(17) '("int32_t" "0")] [(18) '("int64_t" "0")]
    [else #f]))

(define (c-pb-msg-name model msg)
  (c-pb-rel (hash-ref model 'package) (hash-ref msg 'full-name)))

(define (c-pb-type model f support)
  (define type (hash-ref f 'type))
  (define singular
    (cond [(= type 11)
           (define entry (c-pb-resolve model (hash-ref f 'type-name)))
           (if (eq? (hash-ref entry 'kind) 'map)
               (format "~a *" (c-pb-entry-ref model entry))
               (format "~a *" (c-pb-entry-ref model entry)))]
          [(= type 14) (c-pb-entry-ref model (c-pb-resolve model (hash-ref f 'type-name)))]
          [(= type 12) (format "~aBytes" support)]
          [else (first (c-pb-scalar f))]))
  (cond [(and (= type 11)
              (eq? (hash-ref (c-pb-resolve model (hash-ref f 'type-name)) 'kind) 'map))
         singular]
        [(= (hash-ref f 'label) 3)
         (if (= type 11)
             (format "~a *" (c-pb-entry-ref model (c-pb-resolve model (hash-ref f 'type-name))))
             (format "~a *" (c-pb-type model (hash-set f 'label 1) support)))]
        [else singular]))

(define (c-pb-explicit-literal model f)
  (define d (field-explicit-default f))
  (and d
       (case (hash-ref f 'type)
         [(9) (format "~s" d)]
         [(8) d]
         [(14) (format "~a_~a" (c-pb-entry-ref model (c-pb-resolve model (hash-ref f 'type-name))) d)]
         [else d])))

(define (c-pb-default model f support)
  (cond [(c-pb-explicit-literal model f) => (lambda (lit) lit)]
        [(and (= (hash-ref f 'type) 11)
              (eq? (hash-ref (c-pb-resolve model (hash-ref f 'type-name)) 'kind) 'map))
         "NULL"]
        [(= (hash-ref f 'label) 3) "NULL"]
        [(= (hash-ref f 'type) 11) "NULL"]
        [(= (hash-ref f 'type) 12) (format "~a_bytes_empty()" support)]
        [(= (hash-ref f 'type) 14)
         (define entry (c-pb-resolve model (hash-ref f 'type-name)))
         (format "~a_~a" (c-pb-entry-ref model entry) (hash-ref (car (hash-ref (hash-ref entry 'enum) 'values)) 'name))]
        [else (second (c-pb-scalar f))]))

(define (c-pb-varint-expr f v)
  (case (hash-ref f 'type)
    [(8) (format "(~a ? 1 : 0)" v)]
    [(17) (format "((uint64_t)(uint32_t)((~a << 1) ^ (~a >> 31)))" v v)]
    [(18) (format "((uint64_t)((~a << 1) ^ (~a >> 63)))" v v)]
    [(14) (format "((uint64_t)(int64_t)~a)" v)]
    [(5) (format "((uint64_t)(int64_t)~a)" v)]
    [(3) (format "((uint64_t)~a)" v)]
    [else (format "((uint64_t)~a)" v)]))

(define (c-pb-varint-decode f v)
  (case (hash-ref f 'type)
    [(5) (format "((int32_t)(uint32_t)~a)" v)]
    [(13 7) (format "((uint32_t)~a)" v)]
    [(3) (format "((int64_t)~a)" v)]
    [(4 6) v]
    [(8) (format "(~a != 0)" v)]
    [(17) (format "((int32_t)(((uint32_t)~a >> 1) ^ (uint32_t)-(int32_t)((uint32_t)~a & 1)))" v v)]
    [(18) (format "(((int64_t)((uint64_t)~a >> 1)) ^ -(int64_t)((uint64_t)~a & 1))" v v)]))

(define (c-pb-nonzero f v)
  (case (hash-ref f 'type)
    [(8) v]
    [(14) (format "(~a != 0)" v)]
    [else (format "(~a != 0)" v)]))

(define (c-pb-encode-singular model f v indent support)
  (define n (hash-ref f 'number))
  (define type (hash-ref f 'type))
  ;; Proto2 optional/required fields have explicit presence.
  (define proto2? (equal? (hash-ref model 'syntax "") "proto2"))
  (cond [(memv type c-pb-varint-types)
         (if proto2?
             (format "~a{ ~a_writer_tag(&w, ~a, 0); ~a_writer_varint(&w, ~a); }\n" indent support n support (c-pb-varint-expr f v))
             (format "~aif (~a) { ~a_writer_tag(&w, ~a, 0); ~a_writer_varint(&w, ~a); }\n" indent (c-pb-nonzero f v) support n support (c-pb-varint-expr f v)))]
        [(assv type c-pb-fixed)
         => (lambda (info)
              (if proto2?
                  (format "~a{ ~a_writer_tag(&w, ~a, ~a); ~a_writer_fixed_~a(&w, ~a); }\n" indent support n
                          (if (= (second info) 8) 1 5) support (third info) v)
                  (format "~aif (~a) { ~a_writer_tag(&w, ~a, ~a); ~a_writer_fixed_~a(&w, ~a); }\n" indent (c-pb-nonzero f v) support n
                          (if (= (second info) 8) 1 5) support (third info) v)))]
        [(= type 9)
         (if proto2?
             (format "~a~a_writer_bytes_field(&w, ~a, (const uint8_t *)~a, strlen(~a));\n" indent support n v v)
             (format "~a~a_writer_string_field(&w, ~a, ~a);\n" indent support n v))]
        [(= type 12)
         (if proto2?
             (format "~a~a_writer_bytes_field(&w, ~a, ~a.data, ~a.len);\n" indent support n v v)
             (format "~aif (~a.len > 0) ~a_writer_bytes_field(&w, ~a, ~a.data, ~a.len);\n" indent v support n v v))]
        [(= type 11) (format "~aif (~a) { ~aBytes b = ~a_marshal(~a); ~a_writer_bytes_field(&w, ~a, b.data, b.len); free(b.data); }\n"
                             indent v (c-pb-entry-support (c-pb-resolve model (hash-ref f 'type-name))) (c-pb-entry-ref model (c-pb-resolve model (hash-ref f 'type-name))) v support n)]
        [else (error 'emit-c-pb-file "unsupported field type ~a (groups)" type)]))

(define (c-pb-set-expr sib)
  (define v (format "m->~a" (hash-ref sib 'name)))
  (case (hash-ref sib 'type)
    [(11 10) (format "(~a != NULL)" v)]
    [(9) (format "(~a != NULL && ~a[0] != 0)" v v)]
    [(12) (format "(~a.len > 0)" v)]
    [else (c-pb-nonzero sib v)]))

;; Encode-side oneof clearing: suppress f when a later sibling is
;; set, so only the winning member is written.
(define (c-pb-encode-guard model f code)
  (define later (oneof-later-siblings model f))
  (if (null? later)
      code
      (format "    if (!(~a)) {\n~a    }\n"
              (string-join (map c-pb-set-expr later) " || ")
              (if (string-suffix? code "\n") code (string-append code "\n")))))

(define (c-pb-encode-field model f support)
  (define v (format "m->~a" (hash-ref f 'name)))
  (define n (hash-ref f 'number))
  (define type (hash-ref f 'type))
  (cond [(and (= type 11)
              (eq? (hash-ref (c-pb-resolve model (hash-ref f 'type-name)) 'kind) 'map))
         (define entry (c-pb-resolve model (hash-ref f 'type-name)))
         (format "    for (size_t i = 0; i < ~a_count; i++) { ~aBytes b = encode_~a(~a[i].key, ~a[i].value); ~a_writer_bytes_field(&w, ~a, b.data, b.len); free(b.data); }\n"
                 v support (c-pb-entry-ref model entry) v v support n)]
        [(not (= (hash-ref f 'label) 3)) (c-pb-encode-singular model f v "    " support)]
        [(memv type c-pb-varint-types)
         (string-append
          (format "    if (~a_count > 0) {\n        ~aWriter payload; ~a_writer_init(&payload);\n" v support support)
          (format "        for (size_t i = 0; i < ~a_count; i++) ~a_writer_varint(&payload, ~a);\n" v support (c-pb-varint-expr f (format "~a[i]" v)))
          (format "        ~a_writer_bytes_field(&w, ~a, payload.data, payload.len); ~a_writer_free(&payload);\n    }\n" support n support))]
        [(assv type c-pb-fixed)
         => (lambda (info)
              (string-append
               (format "    if (~a_count > 0) {\n        ~aWriter payload; ~a_writer_init(&payload);\n" v support support)
               (format "        for (size_t i = 0; i < ~a_count; i++) ~a_writer_fixed_~a(&payload, ~a[i]);\n" v support (third info) v)
               (format "        ~a_writer_bytes_field(&w, ~a, payload.data, payload.len); ~a_writer_free(&payload);\n    }\n" support n support)))]
        [(= type 9) (format "    for (size_t i = 0; i < ~a_count; i++) ~a_writer_bytes_field(&w, ~a, (const uint8_t *)~a[i], strlen(~a[i]));\n" v support n v v)]
        [(= type 12) (format "    for (size_t i = 0; i < ~a_count; i++) ~a_writer_bytes_field(&w, ~a, ~a[i].data, ~a[i].len);\n" v support n v v)]
        [(= type 11) (format "    for (size_t i = 0; i < ~a_count; i++) { ~aBytes b = ~a_marshal(&~a[i]); ~a_writer_bytes_field(&w, ~a, b.data, b.len); free(b.data); }\n"
                             v (c-pb-entry-support (c-pb-resolve model (hash-ref f 'type-name))) (c-pb-entry-ref model (c-pb-resolve model (hash-ref f 'type-name))) v support n)]
        [else (error 'emit-c-pb-file "unsupported repeated field type ~a" type)]))

(define (c-pb-decode-singular model f target src indent support)
  (define type (hash-ref f 'type))
  (cond [(memv type c-pb-varint-types)
         (format "~a~a = ~a;\n" indent target
                 (if (= type 14)
                     (format "((~a)~a)" (c-pb-entry-ref model (c-pb-resolve model (hash-ref f 'type-name))) (c-pb-varint-decode (hash-set f 'type 5) src))
                     (c-pb-varint-decode f src)))]
        [(assv type c-pb-fixed)
         => (lambda (info)
              (format "~a~a = ~a;\n" indent target
                      (case (hash-ref f 'type)
                        [(2) (format "~a_fixed_to_f32((uint32_t)~a)" support src)]
                        [(1) (format "~a_fixed_to_f64(~a)" support src)]
                        [(7) (format "((uint32_t)~a)" src)]
                        [(15) (format "((int32_t)(uint32_t)~a)" src)]
                        [else src])))]
        [(= type 9) (format "~a~a = ~a_strdup_bytes(~a.data, ~a.len);\n" indent target support src src)]
        [(= type 12) (format "~a~a = ~a_bytes_copy(~a.data, ~a.len);\n" indent target support src src)]
        [(= type 11)
         (define ref (c-pb-entry-ref model (c-pb-resolve model (hash-ref f 'type-name))))
         (string-append
          (format "~a~a = (~a *)calloc(1, sizeof(~a));\n" indent target ref ref)
          (format "~a~a_unmarshal(~a, ~a.data, ~a.len);\n" indent ref target src src))]
        [else (error 'emit-c-pb-file "unsupported field type ~a" type)]))

(define (c-pb-grow model f v expr)
  ;; Inline repeated-field append: realloc the array and store.
  (define elem
    (if (= (hash-ref f 'type) 11)
        (c-pb-entry-ref model (c-pb-resolve model (hash-ref f 'type-name)))
        (c-pb-type model (hash-set f 'label 1) "")))
  (string-append
   (format "                            ~a = (~a *)realloc(~a, sizeof(~a) * (~a_count + 1));\n" v elem v elem v)
   (format "                            ~a[~a_count++] = ~a;\n" v v expr)))

(define (c-pb-grow-stmt model f v expr indent [support ""])
  ;; Inline repeated-field append: realloc the array and store.
  (define elem
    (if (= (hash-ref f 'type) 11)
        (c-pb-entry-ref model (c-pb-resolve model (hash-ref f 'type-name)))
        (c-pb-type model (hash-set f 'label 1) support)))
  (string-append
   (format "~a~a = (~a *)realloc(~a, sizeof(~a) * (~a_count + 1));\n" indent v elem v elem v)
   (format "~a~a[~a_count++] = ~a;\n" indent v v expr)))

(define (c-pb-decode-case model f support)
  (define v (format "m->~a" (hash-ref f 'name)))
  (define type (hash-ref f 'type))
  (define head (format "                case ~a: {\n" (hash-ref f 'number)))
  (define tail "                    break;\n                }\n")
  (cond [(and (= type 11)
              (eq? (hash-ref (c-pb-resolve model (hash-ref f 'type-name)) 'kind) 'map))
         (define entry (c-pb-resolve model (hash-ref f 'type-name)))
         (string-append head
                        (format "                    ~a kv = decode_~a(field.bytes_value.data, field.bytes_value.len);\n" (c-pb-entry-ref model entry) (c-pb-entry-ref model entry))
                        (c-pb-grow-stmt model f v "kv" "                    " support)
                        tail)]
        [(not (= (hash-ref f 'label) 3))
         (define clearing
           (apply string-append
                  (map (lambda (sib)
                         (format "                    ~a = ~a;\n" (format "m->~a" (hash-ref sib 'name)) (c-pb-default model sib support)))
                       (oneof-siblings model f))))
         (string-append head
                        clearing
                        (c-pb-decode-singular model f v
                                              (cond [(memv type c-pb-varint-types) "field.varint_value"]
                                                    [(assv type c-pb-fixed) "field.fixed_value"]
                                                    [else "field.bytes_value"])
                                              "                    " support)
                        tail)]
        [(memv type c-pb-varint-types)
         (string-append head
                        "                    if (field.wire == 2) {\n"
                        (format "                        ~aReader sub; ~a_reader_init(&sub, field.bytes_value.data, field.bytes_value.len);\n" support support)
                        (format "                        while (!~a_reader_done(&sub)) {\n" support)
                        (format "                            uint64_t raw = ~a_reader_varint(&sub);\n" support)
                        (c-pb-grow-stmt model f v
                                        (let ([conv (c-pb-varint-decode f "raw")])
                                          (if (= type 14)
                                              (format "((~a)~a)" (c-pb-entry-ref model (c-pb-resolve model (hash-ref f 'type-name))) (c-pb-varint-decode (hash-set f 'type 5) "raw"))
                                              conv))
                                        "                            " support)
                        "                        }\n                    } else {\n"
                        (c-pb-grow-stmt model f v
                                        (let ([conv (c-pb-varint-decode f "field.varint_value")])
                                          (if (= type 14)
                                              (format "((~a)~a)" (c-pb-entry-ref model (c-pb-resolve model (hash-ref f 'type-name))) (c-pb-varint-decode (hash-set f 'type 5) "field.varint_value"))
                                              conv))
                                        "                        " support)
                        "                    }\n" tail)]
        [(assv type c-pb-fixed)
         => (lambda (info)
              (string-append head
                             "                    if (field.wire == 2) {\n"
                             (format "                        ~aReader sub; ~a_reader_init(&sub, field.bytes_value.data, field.bytes_value.len);\n" support support)
                             (format "                        while (!~a_reader_done(&sub)) {\n" support)
                             (c-pb-grow-stmt model f v
                                             (case (hash-ref f 'type)
                                               [(2) (format "~a_fixed_to_f32(~a_reader_fixed_u32(&sub))" support support)]
                                               [(1) (format "~a_fixed_to_f64(~a_reader_fixed_u64(&sub))" support support)]
                                               [(7) (format "~a_reader_fixed_u32(&sub)" support)]
                                               [(15) (format "((int32_t)~a_reader_fixed_u32(&sub))" support)]
                                               [else (format "~a_reader_fixed_u64(&sub)" support)])
                                             "                            " support)
                             "                        }\n                    } else {\n"
                             (c-pb-grow-stmt model f v
                                             (case (hash-ref f 'type)
                                               [(2) (format "~a_fixed_to_f32((uint32_t)field.fixed_value)" support)]
                                               [(1) (format "~a_fixed_to_f64(field.fixed_value)" support)]
                                               [(7) "((uint32_t)field.fixed_value)"]
                                               [(15) "((int32_t)(uint32_t)field.fixed_value)"]
                                               [else "field.fixed_value"])
                                             "                        " support)
                             "                    }\n" tail))]
        [(= type 9) (string-append head (c-pb-grow-stmt model f v (format "~a_strdup_bytes(field.bytes_value.data, field.bytes_value.len)" support) "                    " support) tail)]
        [(= type 12) (string-append head (c-pb-grow-stmt model f v (format "~a_bytes_copy(field.bytes_value.data, field.bytes_value.len)" support) "                    " support) tail)]
        [(= type 11)
         (string-append head
                        (format "                    ~a item; memset(&item, 0, sizeof(item));\n" (c-pb-entry-ref model (c-pb-resolve model (hash-ref f 'type-name))))
                        (format "                    ~a_unmarshal(&item, field.bytes_value.data, field.bytes_value.len);\n" (c-pb-entry-ref model (c-pb-resolve model (hash-ref f 'type-name))))
                        (c-pb-grow-stmt model f v "item" "                    " support)
                        tail)]
        [else (error 'emit-c-pb-file "unsupported repeated field type ~a" type)]))

(define (c-pb-map-helpers model entry support)
  (define msg (hash-ref entry 'msg))
  (define ename (c-pb-entry-ref model entry))
  (define key-f (findf (lambda (x) (= (hash-ref x 'number) 1)) (hash-ref msg 'fields)))
  (define val-f (findf (lambda (x) (= (hash-ref x 'number) 2)) (hash-ref msg 'fields)))
  (unless (and key-f val-f) (error 'emit-c-pb-file "map entry ~a lacks key/value" (hash-ref msg 'full-name)))
  (define kt (c-pb-type model (hash-set key-f 'label 1) support))
  (define vt (c-pb-type model (hash-set val-f 'label 1) support))
  (define vt-plain (if (and (= (hash-ref val-f 'type) 11)
                            (not (eq? (hash-ref (c-pb-resolve model (hash-ref val-f 'type-name)) 'kind) 'map)))
                       (c-pb-entry-ref model (c-pb-resolve model (hash-ref val-f 'type-name)))
                       vt))
  (string-append
   (format "static inline ~aBytes encode_~a(~a key, ~a value) {\n" support ename kt vt-plain)
   (format "    ~aWriter w; ~a_writer_init(&w);\n" support support)
   (string-replace (c-pb-encode-singular model (hash-set key-f 'label 1) "key" "    " support) "m->" "")
   (if (= (hash-ref val-f 'type) 11)
       (format "    { ~aBytes b = ~a_marshal(&value); ~a_writer_bytes_field(&w, ~a, b.data, b.len); free(b.data); }\n" (c-pb-entry-support (c-pb-resolve model (hash-ref val-f 'type-name))) vt-plain support (hash-ref val-f 'number))
       (string-replace (c-pb-encode-singular model (hash-set val-f 'label 1) "value" "    " support) "m->" ""))
   (format "    return ~a_writer_to_bytes(&w);\n}\n\n" support)
   (format "static inline ~a decode_~a(const uint8_t *data, size_t len) {\n" ename ename)
   (format "    ~a result; memset(&result, 0, sizeof(result));\n" ename)
   (format "    result.key = ~a;\n" (c-pb-default model (hash-set key-f 'label 1) support))
   (if (= (hash-ref val-f 'type) 11)
       "    /* result.value zero-initialized */\n"
       (format "    result.value = ~a;\n" (c-pb-default model (hash-set val-f 'label 1) support)))
   (format "    ~aReader r; ~a_reader_init(&r, data, len);\n    ~aField field;\n    while (~a_reader_next(&r, &field)) {\n        switch (field.number) {\n" support support support support)
   (format "            case ~a: ~a break;\n" (hash-ref key-f 'number)
           (string-trim (c-pb-decode-singular model (hash-set key-f 'label 1) "result.key"
                                              (cond [(memv (hash-ref key-f 'type) c-pb-varint-types) "field.varint_value"]
                                                    [(assv (hash-ref key-f 'type) c-pb-fixed) "field.fixed_value"]
                                                    [else "field.bytes_value"]) "" support) "\n" #:left? #f #:repeat? #t))
   (format "            case ~a: ~a break;\n" (hash-ref val-f 'number)
           (if (= (hash-ref val-f 'type) 11)
               (format "~a_unmarshal(&result.value, field.bytes_value.data, field.bytes_value.len);" vt-plain)
               (string-trim (c-pb-decode-singular model (hash-set val-f 'label 1) "result.value"
                                                  (cond [(memv (hash-ref val-f 'type) c-pb-varint-types) "field.varint_value"]
                                                        [(assv (hash-ref val-f 'type) c-pb-fixed) "field.fixed_value"]
                                                        [else "field.bytes_value"]) "" support) "\n" #:left? #f #:repeat? #t)))
   "            default: break;\n        }\n    }\n    return result;\n}\n\n"))

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
  (string-append
   (format "typedef enum ~a {\n" name)
   (string-join (map (lambda (v) (format "    ~a_~a = ~a" name (hash-ref v 'name) (hash-ref v 'number)))
                     (hash-ref e 'values)) ",\n")
   (format "\n} ~a;\n\n" name)))

(define (c-pb-field-decls model msg support)
  (apply string-append
         (map (lambda (f)
                (define repeated? (or (= (hash-ref f 'label) 3)
                                      (and (= (hash-ref f 'type) 11)
                                           (eq? (hash-ref (c-pb-resolve model (hash-ref f 'type-name)) 'kind) 'map))))
                (string-append
                 (format "    ~a ~a;\n" (c-pb-type model f support) (hash-ref f 'name))
                 (if repeated? (format "    size_t ~a_count;\n" (hash-ref f 'name)) "")))
              (hash-ref msg 'fields))))

(define (c-pb-message-fns model msg support)
  (define name (c-pb-msg-name model msg))
  (define fields (hash-ref msg 'fields))
  (string-append
   (format "static inline void ~a_init(~a *m) {\n    memset(m, 0, sizeof(*m));\n" name name)
   (apply string-append
          (map (lambda (f)
                 (if (or (= (hash-ref f 'type) 9) (= (hash-ref f 'type) 14)
                         (and (c-pb-explicit-literal model f) #t))
                     (format "    m->~a = ~a;\n" (hash-ref f 'name) (c-pb-default model f support))
                     ""))
               fields))
   "}\n\n"
   (format "static inline ~aBytes ~a_marshal(const ~a *m) {\n" support name name)
   (format "    ~aWriter w; ~a_writer_init(&w);\n" support support)
   (apply string-append (map (lambda (f) (c-pb-encode-guard model f (c-pb-encode-field model f support))) fields))
   (format "    ~a_writer_raw(&w, m->unknown_fields.data, m->unknown_fields.len);\n" support)
   (format "    return ~a_writer_to_bytes(&w);\n}\n\n" support)
   (format "static inline void ~a_unmarshal(~a *m, const uint8_t *data, size_t len) {\n" name name)
   (format "    ~a_init(m);\n" name)
   (format "    ~aReader r; ~a_reader_init(&r, data, len);\n    ~aField field;\n    while (~a_reader_next(&r, &field)) {\n        switch (field.number) {\n" support support support support)
   (apply string-append (map (lambda (f) (c-pb-decode-case model f support)) fields))
   (format "            default: {\n                ~aBytes raw = ~a_bytes_copy(field.raw_value.data, field.raw_value.len);\n" support support)
   "                m->unknown_fields.data = (uint8_t *)realloc(m->unknown_fields.data, m->unknown_fields.len + raw.len);\n"
   "                if (raw.len) memcpy(m->unknown_fields.data + m->unknown_fields.len, raw.data, raw.len);\n"
   "                m->unknown_fields.len += raw.len; free(raw.data);\n                break;\n            }\n        }\n    }\n}\n\n"))

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
  (if (hash-ref m 'deprecated #f)
      (format "~a/* Deprecated in the proto schema. */\n" indent)
      ""))

(define (c-client-method model m support)
  (define name (snake-case (hash-ref m 'name)))
  (define req (c-type-ref model (hash-ref m 'input-full)))
  (define resp (c-type-ref model (hash-ref m 'output-full)))
  (define req-sup (c-pb-entry-support (c-pb-resolve model (hash-ref m 'input-full))))
  (define resp-sup (c-pb-entry-support (c-pb-resolve model (hash-ref m 'output-full))))
  (define path (hash-ref m 'path))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(unary)
     (string-append
      (c-deprecated m "")
      (format "static inline grpcdc_status ~aClient_~a(~aClient *c, const ~a *req, ~a *resp, const grpcdc_kv *md, size_t md_count, int64_t deadline_ms) {\n"
              svc name svc req resp)
      (format "    ~aBytes rb = ~a_marshal(req);\n" req-sup req)
      (format "    grpcdc_bytes out; grpcdc_status st = grpcdc_channel_unary(c->channel, ~s, rb.data, rb.len, md, md_count, deadline_ms, &out);\n" path)
      "    free(rb.data);\n"
      (format "    if (st.code == 0) { memset(resp, 0, sizeof(*resp)); ~a_unmarshal(resp, out.data, out.len); grpcdc_bytes_free(&out); }\n" resp)
      "    return st;\n}\n\n")]
    [(server-streaming)
     (string-append
      (c-deprecated m "")
      (format "typedef struct { grpcdc_stream *raw; } ~a~aClient;\n\n" svc (hash-ref m 'name))
      (format "static inline grpcdc_status ~aClient_~a(~aClient *c, const ~a *req, ~a~aClient *out_stream, const grpcdc_kv *md, size_t md_count, int64_t deadline_ms) {\n"
              svc name svc req svc (hash-ref m 'name))
      (format "    ~aBytes rb = ~a_marshal(req);\n" req-sup req)
      (format "    grpcdc_status st = grpcdc_channel_open(c->channel, ~s, rb.data, rb.len, 1, md, md_count, deadline_ms, &out_stream->raw);\n" path)
      "    free(rb.data);\n    return st;\n}\n\n"
      (format "static inline int ~a~aClient_recv(~a~aClient *s, ~a *resp, grpcdc_status *st) {\n"
              svc (hash-ref m 'name) svc (hash-ref m 'name) resp)
      "    grpcdc_bytes out; int r = grpcdc_stream_recv(s->raw, &out, st);\n"
      (format "    if (r == 1) { memset(resp, 0, sizeof(*resp)); ~a_unmarshal(resp, out.data, out.len); grpcdc_bytes_free(&out); }\n" resp)
      "    return r;\n}\n\n"
      (format "static inline void ~a~aClient_close(~a~aClient *s) { grpcdc_stream_free(s->raw); }\n\n"
              svc (hash-ref m 'name) svc (hash-ref m 'name))
      (format "static inline void ~a~aClient_cancel(~a~aClient *s) { grpcdc_stream_cancel(s->raw); }\n\n"
              svc (hash-ref m 'name) svc (hash-ref m 'name)))]
    [(client-streaming)
     (string-append
      (c-deprecated m "")
      (format "static inline grpcdc_status ~aClient_~a(~aClient *c, const ~a *reqs, size_t req_count, ~a *resp, const grpcdc_kv *md, size_t md_count, int64_t deadline_ms) {\n"
              svc name svc req resp)
      "    grpcdc_stream *raw; grpcdc_status st;\n"
      (format "    st = grpcdc_channel_open(c->channel, ~s, NULL, 0, 0, md, md_count, deadline_ms, &raw);\n" path)
      "    if (st.code != 0) return st;\n"
      "    for (size_t i = 0; i < req_count; i++) {\n"
      (format "        ~aBytes rb = ~a_marshal(&reqs[i]);\n" req-sup req)
      "        st = grpcdc_stream_send(raw, rb.data, rb.len); free(rb.data);\n"
      "        if (st.code != 0) { grpcdc_stream_free(raw); return st; }\n    }\n"
      "    st = grpcdc_stream_close_send(raw);\n"
      "    if (st.code != 0) { grpcdc_stream_free(raw); return st; }\n"
      "    grpcdc_bytes out; int r = grpcdc_stream_recv(raw, &out, &st);\n"
      (format "    if (r == 1) { memset(resp, 0, sizeof(*resp)); ~a_unmarshal(resp, out.data, out.len); grpcdc_bytes_free(&out); }\n" resp)
      "    grpcdc_stream_free(raw);\n"
      "    if (r == 0) return grpcdc_status_make(2, \"missing response\");\n"
      "    return st;\n}\n\n")]
    [(bidi)
     (string-append
      (c-deprecated m "")
      (format "typedef struct { grpcdc_stream *raw; } ~a~aClient;\n\n" svc (hash-ref m 'name))
      (format "static inline grpcdc_status ~aClient_~a(~aClient *c, const ~a *reqs, size_t req_count, ~a~aClient *out_stream, const grpcdc_kv *md, size_t md_count, int64_t deadline_ms) {\n"
              svc name svc req svc (hash-ref m 'name))
      "    grpcdc_status st;\n"
      (format "    st = grpcdc_channel_open(c->channel, ~s, NULL, 0, 0, md, md_count, deadline_ms, &out_stream->raw);\n" path)
      "    if (st.code != 0) return st;\n"
      "    for (size_t i = 0; i < req_count; i++) {\n"
      (format "        ~aBytes rb = ~a_marshal(&reqs[i]);\n" req-sup req)
      "        st = grpcdc_stream_send(out_stream->raw, rb.data, rb.len); free(rb.data);\n"
      "        if (st.code != 0) { grpcdc_stream_free(out_stream->raw); return st; }\n    }\n"
      "    return grpcdc_stream_close_send(out_stream->raw);\n}\n\n"
      (format "static inline int ~a~aClient_recv(~a~aClient *s, ~a *resp, grpcdc_status *st) {\n"
              svc (hash-ref m 'name) svc (hash-ref m 'name) resp)
      "    grpcdc_bytes out; int r = grpcdc_stream_recv(s->raw, &out, st);\n"
      (format "    if (r == 1) { memset(resp, 0, sizeof(*resp)); ~a_unmarshal(resp, out.data, out.len); grpcdc_bytes_free(&out); }\n" resp)
      "    return r;\n}\n\n"
      (format "static inline void ~a~aClient_close(~a~aClient *s) { grpcdc_stream_free(s->raw); }\n\n"
              svc (hash-ref m 'name) svc (hash-ref m 'name))
      (format "static inline void ~a~aClient_cancel(~a~aClient *s) { grpcdc_stream_cancel(s->raw); }\n\n"
              svc (hash-ref m 'name) svc (hash-ref m 'name)))]))

(define (c-server-types model m support)
  (define req (c-type-ref model (hash-ref m 'input-full)))
  (define resp (c-type-ref model (hash-ref m 'output-full)))
  (define resp-sup (c-pb-entry-support (c-pb-resolve model (hash-ref m 'output-full))))
  (define svc (current-service))
  (define mname (hash-ref m 'name))
  (case (hash-ref m 'kind)
    [(server-streaming)
     (string-append
      (format "typedef struct { grpcdc_server_stream *raw; } ~a~aStream;\n" svc mname)
      (format "static inline grpcdc_status ~a~aStream_send(~a~aStream *s, const ~a *resp) { ~aBytes rb = ~a_marshal(resp); grpcdc_status st = grpcdc_server_stream_send(s->raw, rb.data, rb.len); free(rb.data); return st; }\n\n"
              svc mname svc mname resp resp-sup resp))]
    [(client-streaming)
     (string-append
      (format "typedef struct { grpcdc_server_stream *raw; } ~a~aStream;\n" svc mname)
      (format "static inline int ~a~aStream_recv(~a~aStream *s, ~a *req, grpcdc_status *st) { grpcdc_bytes out; int r = grpcdc_server_stream_recv(s->raw, &out, st); if (r == 1) { memset(req, 0, sizeof(*req)); ~a_unmarshal(req, out.data, out.len); grpcdc_bytes_free(&out); } return r; }\n\n"
              svc mname svc mname req req))]
    [(bidi)
     (string-append
      (format "typedef struct { grpcdc_server_stream *raw; } ~a~aStream;\n" svc mname)
      (format "static inline grpcdc_status ~a~aStream_send(~a~aStream *s, const ~a *resp) { ~aBytes rb = ~a_marshal(resp); grpcdc_status st = grpcdc_server_stream_send(s->raw, rb.data, rb.len); free(rb.data); return st; }\n"
              svc mname svc mname resp resp-sup resp)
      (format "static inline int ~a~aStream_recv(~a~aStream *s, ~a *req, grpcdc_status *st) { grpcdc_bytes out; int r = grpcdc_server_stream_recv(s->raw, &out, st); if (r == 1) { memset(req, 0, sizeof(*req)); ~a_unmarshal(req, out.data, out.len); grpcdc_bytes_free(&out); } return r; }\n\n"
              svc mname svc mname req req))]
    [else ""]))

(define (c-server-impl-field model m)
  (define req (c-type-ref model (hash-ref m 'input-full)))
  (define resp (c-type-ref model (hash-ref m 'output-full)))
  (define svc (current-service))
  (define mname (hash-ref m 'name))
  (case (hash-ref m 'kind)
    [(unary) (format "    grpcdc_status (*~a)(void *ctx, const grpcdc_kv *md, size_t md_count, const ~a *req, ~a *resp);\n" (snake-case mname) req resp)]
    [(server-streaming) (format "    grpcdc_status (*~a)(void *ctx, const grpcdc_kv *md, size_t md_count, const ~a *req, ~a~aStream *stream);\n" (snake-case mname) req svc mname)]
    [(client-streaming) (format "    grpcdc_status (*~a)(void *ctx, ~a~aStream *stream, ~a *resp);\n" (snake-case mname) svc mname resp)]
    [(bidi) (format "    grpcdc_status (*~a)(void *ctx, ~a~aStream *stream);\n" (snake-case mname) svc mname)]))

(define (c-server-adapter model m support)
  (define req (c-type-ref model (hash-ref m 'input-full)))
  (define resp (c-type-ref model (hash-ref m 'output-full)))
  (define resp-sup (c-pb-entry-support (c-pb-resolve model (hash-ref m 'output-full))))
  (define svc (current-service))
  (define mname (hash-ref m 'name))
  (define snake (snake-case mname))
  (case (hash-ref m 'kind)
    [(unary)
     (string-append
      (format "static grpcdc_status ~a_~a_unary_adapter(void *impl, const grpcdc_kv *md, size_t md_count, grpcdc_bytes reqb, grpcdc_bytes *respb) {\n" svc snake)
      (format "    ~aServerImpl *impl_ = (~aServerImpl *)impl;\n" svc svc)
      (format "    ~a req; memset(&req, 0, sizeof(req)); ~a_unmarshal(&req, reqb.data, reqb.len);\n" req req)
      (format "    ~a resp; memset(&resp, 0, sizeof(resp));\n" resp)
      (format "    grpcdc_status st = impl_->~a(impl_->ctx, md, md_count, &req, &resp);\n" snake)
      (format "    if (st.code == 0) { ~aBytes rb = ~a_marshal(&resp); respb->data = rb.data; respb->len = rb.len; }\n" resp-sup resp)
      "    return st;\n}\n\n")]
    [(server-streaming)
     (string-append
      (format "static grpcdc_status ~a_~a_sstream_adapter(void *impl, const grpcdc_kv *md, size_t md_count, grpcdc_bytes reqb, grpcdc_server_stream *raw) {\n" svc snake)
      (format "    ~aServerImpl *impl_ = (~aServerImpl *)impl;\n" svc svc)
      (format "    ~a req; memset(&req, 0, sizeof(req)); ~a_unmarshal(&req, reqb.data, reqb.len);\n" req req)
      (format "    ~a~aStream stream; stream.raw = raw;\n" svc mname)
      (format "    return impl_->~a(impl_->ctx, md, md_count, &req, &stream);\n}\n\n" snake))]
    [(client-streaming)
     (string-append
      (format "static grpcdc_status ~a_~a_cstream_adapter(void *impl, grpcdc_server_stream *raw, grpcdc_bytes *respb) {\n" svc snake)
      (format "    ~aServerImpl *impl_ = (~aServerImpl *)impl;\n" svc svc)
      (format "    ~a~aStream stream; stream.raw = raw;\n" svc mname)
      (format "    ~a resp; memset(&resp, 0, sizeof(resp));\n" resp)
      (format "    grpcdc_status st = impl_->~a(impl_->ctx, &stream, &resp);\n" snake)
      (format "    if (st.code == 0) { ~aBytes rb = ~a_marshal(&resp); respb->data = rb.data; respb->len = rb.len; }\n" resp-sup resp)
      "    return st;\n}\n\n")]
    [(bidi)
     (string-append
      (format "static grpcdc_status ~a_~a_bidi_adapter(void *impl, grpcdc_server_stream *raw) {\n" svc snake)
      (format "    ~aServerImpl *impl_ = (~aServerImpl *)impl;\n" svc svc)
      (format "    ~a~aStream stream; stream.raw = raw;\n" svc mname)
      (format "    return impl_->~a(impl_->ctx, &stream);\n}\n\n" snake))]))

(define (c-service model svc support)
  (define sname (hash-ref svc 'name))
  (parameterize ([current-service sname])
    (string-append
     (format "/* Service ~a (~a). */\n" sname (hash-ref svc 'full-name))
     (format "typedef struct { grpcdc_channel *channel; } ~aClient;\n\n" sname)
     (apply string-append (map (lambda (m) (c-client-method model m support)) (append (hash-ref svc 'methods) (alias-client-methods svc))))
     (apply string-append (map (lambda (m) (c-server-types model m support)) (hash-ref svc 'methods)))
     (format "typedef struct {\n    void *ctx;\n")
     (apply string-append (map (lambda (m) (c-server-impl-field model m)) (hash-ref svc 'methods)))
     (format "} ~aServerImpl;\n\n" sname)
     (apply string-append (map (lambda (m) (c-server-adapter model m support)) (hash-ref svc 'methods)))
     (format "static inline void ~aServer_register(grpcdc_server *srv, ~aServerImpl *impl) {\n" sname sname)
     (format "    static const grpcdc_method_desc methods[] = {\n")
     (apply string-append
            (map (lambda (m)
                   (define snake (snake-case (hash-ref m 'name)))
                   (case (hash-ref m 'kind)
                     [(unary) (format "        { ~s, 0, ~a_~a_unary_adapter, 0, 0, 0 },\n" (hash-ref m 'name) sname snake)]
                     [(server-streaming) (format "        { ~s, 1, 0, ~a_~a_sstream_adapter, 0, 0 },\n" (hash-ref m 'name) sname snake)]
                     [(client-streaming) (format "        { ~s, 2, 0, 0, ~a_~a_cstream_adapter, 0 },\n" (hash-ref m 'name) sname snake)]
                     [(bidi) (format "        { ~s, 3, 0, 0, 0, ~a_~a_bidi_adapter },\n" (hash-ref m 'name) sname snake)]))
                 (hash-ref svc 'methods)))
     "    };\n"
     (format "    grpcdc_server_add_service(srv, ~s, methods, sizeof(methods) / sizeof(methods[0]), impl);\n}\n\n" (hash-ref svc 'full-name)))))

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
