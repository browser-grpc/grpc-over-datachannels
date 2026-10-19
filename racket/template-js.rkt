#lang racket

;;; template-js.rkt — emitter body spliced into protoc-gen-grpc-dc-js.
;;;
;;; Generated code imports message classes from `./<base>_pb.js` (override
;;; with the protoc plugin parameter `pb_import`).  A message class must
;;; expose `static encode(msg) -> Uint8Array` and `static decode(bytes)`.

(require "spec.rkt" "desc.rkt")
(provide emit-js-file)

(define (lower-first s)
  (if (string=? s "")
      s
      (string-append (string (char-downcase (string-ref s 0))) (substring s 1))))

(define (js-deprecated m indent)
  (if (hash-ref m 'deprecated #f)
      (format "~a/** @deprecated deprecated in the proto schema */\n" indent)
      ""))

(define (js-client-method m)
  (define fn-name (lower-first (hash-ref m 'name)))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define path (hash-ref m 'path))
  (define depr (js-deprecated m "  "))
  (case (hash-ref m 'kind)
    [(unary)
     (format "~a  async ~a(request, options) {\n    return this.#channel.unary(~s, request, ~a, ~a, options);\n  }\n"
             depr fn-name path req resp)]
    [(server-streaming)
     (format "~a  ~a(request, options) {\n    return this.#channel.serverStream(~s, request, ~a, ~a, options);\n  }\n"
             depr fn-name path req resp)]
    [(client-streaming)
     (format "~a  async ~a(requests, options) {\n    return this.#channel.clientStream(~s, requests, ~a, ~a, options);\n  }\n"
             depr fn-name path req resp)]
    [(bidi)
     (format "~a  ~a(requests, options) {\n    return this.#channel.bidi(~s, requests, ~a, ~a, options);\n  }\n"
             depr fn-name path req resp)]))

(define (js-method-table-entry m)
  (format "    ~a: { path: ~s, kind: ~s, requestType: ~a, responseType: ~a, handler: handlers.~a },\n"
          (hash-ref m 'name) (hash-ref m 'path)
          (symbol->string (hash-ref m 'kind))
          (hash-ref m 'input) (hash-ref m 'output)
          (lower-first (method-impl-name m))))

(define (js-service svc)
  (define sname (hash-ref svc 'name))
  (define methods (hash-ref svc 'methods))
  (string-append
   (format "export class ~aClient {\n  #channel;\n  constructor(channel) { this.#channel = channel; }\n" sname)
   (apply string-append (map js-client-method (append methods (alias-client-methods svc))))
   "}\n\n"
   (format "export function create~aService(handlers) {\n  return {\n    name: ~s,\n    methods: {\n"
           sname (hash-ref svc 'full-name))
   (apply string-append (map js-method-table-entry (append methods (alias-server-methods svc))))
   "    },\n  };\n}\n"))

;; ---------------------------------------------------------------------------
;; JS message classes (<base>_pb.js), mirroring the Python emitter
;; (template-python.rkt) and the web generator's emitJsPbFile:
;; dependency-free classes with static encode/decode. Wire format
;; is genuine protobuf (proto3 semantics; oneof fields are plain
;; fields). Returns (cons name content) or #f when the model has
;; no message metadata or nothing to emit.
;; ---------------------------------------------------------------------------

(define js-pb-varint-types '(5 3 13 4 17 18 8 14))
(define js-pb-fixed '((2 4 "Float32") (1 8 "Float64") (7 4 "Uint32") (15 4 "Int32") (6 8 "BigUint64") (16 8 "BigInt64")))
(define js-pb-bigint-types '(3 4 18 6 16))

(define js-pb-preamble
  (string-append
   "function varintBytes(value) {\n  let n = BigInt.asUintN(64, BigInt(value));\n  const out = [];\n  while (n > 0x7fn) {\n    out.push(Number((n & 0x7fn) | 0x80n));\n    n >>= 7n;\n  }\n  out.push(Number(n));\n  return out;\n}\n\n"
   "function zz64(v) {\n  const b = BigInt(v);\n  return (b << 1n) ^ (b >> 63n);\n}\n\nfunction unzz64(v) {\n  return (v >> 1n) ^ (-(v & 1n));\n}\n\n"
   "class Reader {\n  constructor(bytes) {\n    this.bytes = bytes;\n    this.pos = 0;\n  }\n  get done() {\n    return this.pos >= this.bytes.length;\n  }\n"
   "  varint() {\n    let result = 0n;\n    let shift = 0n;\n    for (;;) {\n      if (this.pos >= this.bytes.length) throw new Error(\"truncated varint\");\n      const byte = this.bytes[this.pos++];\n      result |= BigInt(byte & 0x7f) << shift;\n      if ((byte & 0x80) === 0) return result;\n      shift += 7n;\n      if (shift >= 64n) throw new Error(\"varint too long\");\n    }\n  }\n"
   "  take(n) {\n    const value = this.bytes.slice(this.pos, this.pos + n);\n    if (value.length !== n) throw new Error(\"truncated field\");\n    this.pos += n;\n    return value;\n  }\n"
   "  field() {\n    if (this.done) return null;\n    const start = this.pos;\n    const tag = this.varint();\n    const field = Number(tag >> 3n);\n    const wire = Number(tag & 7n);\n    switch (wire) {\n      case 0:\n        return [field, wire, this.varint(), this.bytes.slice(start, this.pos)];\n      case 2: {\n        const len = Number(this.varint());\n        const v = this.take(len);\n        return [field, wire, v, this.bytes.slice(start, this.pos)];\n      }\n      case 1: {\n        const v = this.take(8);\n        return [field, wire, v, this.bytes.slice(start, this.pos)];\n      }\n      case 5: {\n        const v = this.take(4);\n        return [field, wire, v, this.bytes.slice(start, this.pos)];\n      }\n      default:\n        throw new Error(\"bad wire type \" + wire);\n    }\n  }\n}\n\n"
   "function concatBytes(a, b) {\n  const out = new Uint8Array(a.length + b.length);\n  out.set(a);\n  out.set(b, a.length);\n  return out;\n}\n\n"
   "function putTag(out, num, wire) {\n  out.push(...varintBytes((BigInt(num) << 3n) | BigInt(wire)));\n}\n\n"
   "function putVarintField(out, num, value) {\n  if (value === 0n) return;\n  putTag(out, num, 0);\n  out.push(...varintBytes(value));\n}\n\n"
   "function putBytesField(out, num, payload) {\n  putTag(out, num, 2);\n  out.push(...varintBytes(payload.length), ...payload);\n}\n\n"
   "function putStringField(out, num, value) {\n  if (!value) return;\n  putBytesField(out, num, new TextEncoder().encode(value));\n}\n\n"
   "function putFixedField(out, num, payload) {\n  putTag(out, num, payload.length === 8 ? 1 : 5);\n  out.push(...payload);\n}\n\n"
   "function fixedBytes(value, size, write) {\n  const bytes = new Uint8Array(size);\n  write(new DataView(bytes.buffer), value);\n  return bytes;\n}\n\n"
   "function readFixed(bytes, read) {\n  return read(new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength));\n}\n\n"))

(define (js-pb-flat pkg full)
  (define rel (if (and pkg (not (string=? pkg ""))
                       (string-prefix? full (string-append pkg ".")))
                  (substring full (add1 (string-length pkg)))
                  full))
  (string-join (string-split rel ".") "_"))

(define (js-pb-name f)
  (define jn (hash-ref f 'json-name ""))
  (if (and jn (not (string=? jn "")))
      jn
      (regexp-replace* #rx"_([a-zA-Z0-9])" (hash-ref f 'name)
                       (lambda (all c) (string-upcase c)))))

(define (js-pb-fixed-info type)
  (assv type js-pb-fixed))

(define (js-pb-varint-expr f v)
  (case (hash-ref f 'type)
    [(8) (format "(~a ? 1n : 0n)" v)]
    [(17) (format "BigInt(((~a << 1) ^ (~a >> 31)) >>> 0)" v v)]
    [(18) (format "zz64(~a)" v)]
    [else (format "BigInt(~a)" v)]))

(define (js-pb-varint-decode f v)
  (case (hash-ref f 'type)
    [(5 14) (format "Number(BigInt.asIntN(32, ~a))" v)]
    [(13) (format "Number(BigInt.asUintN(32, ~a))" v)]
    [(3) (format "BigInt.asIntN(64, ~a)" v)]
    [(4) (format "BigInt.asUintN(64, ~a)" v)]
    [(8) (format "~a !== 0n" v)]
    [(17) (format "Number(unzz64(BigInt.asUintN(32, ~a)))" v)]
    [(18) (format "unzz64(~a)" v)]))

(define (js-pb-explicit-literal model f)
  (define d (field-explicit-default f))
  (and d
       (case (hash-ref f 'type)
         [(9) (format "~s" d)]
         [(8) d]
         [(14) (format "~a" (enum-default-number model f))]
         [(2) (format "~a" d)]
         [else d])))

(define (js-pb-default f model)
  (cond [(js-pb-explicit-literal model f) => (lambda (lit) lit)]
        [(= (hash-ref f 'label) 3)
         (define t (and (= (hash-ref f 'type) 11)
                        (hash-ref (hash-ref model 'types) (hash-ref f 'type-name) #f)))
         (if (and t (eq? (hash-ref t 'kind) 'map)) "new Map()" "[]")]
        [else
         (case (hash-ref f 'type)
           [(9) "\"\""]
           [(12) "new Uint8Array(0)"]
           [(8) "false"]
           [(11 10) "undefined"]
           [else (if (memv (hash-ref f 'type) js-pb-bigint-types) "0n" "0")])]))

(define (js-pb-resolve model type-name)
  (hash-ref (hash-ref model 'types) type-name
            (lambda () (error 'emit-js-pb-file "unresolved type ~a" type-name))))

(define (js-pb-entry-flat entry)
  (js-pb-flat (hash-ref entry 'pkg)
              (if (eq? (hash-ref entry 'kind) 'enum)
                  (let ([e (hash-ref entry 'enum)])
                    (format "~a~a" (if (hash-ref entry 'msg)
                                       (string-append (hash-ref (hash-ref entry 'msg) 'full-name) ".")
                                       (if (string=? (hash-ref entry 'pkg) "") "" (string-append (hash-ref entry 'pkg) ".")))
                            (hash-ref e 'name)))
                  (hash-ref (hash-ref entry 'msg) 'full-name))))

(define (js-pb-encode-singular model f v indent)
  (define n (hash-ref f 'number))
  (define type (hash-ref f 'type))
  ;; Proto2 optional/required fields have explicit presence: they
  ;; are written even when equal to the default.
  (define proto2? (equal? (hash-ref model 'syntax "") "proto2"))
  (cond [(memv type js-pb-varint-types)
         (if proto2?
             (format "~aputTag(out, ~a, 0); out.push(...varintBytes(~a));\n" indent n (js-pb-varint-expr f v))
             (format "~aputVarintField(out, ~a, ~a);\n" indent n (js-pb-varint-expr f v)))]
        [(js-pb-fixed-info type)
         => (lambda (info)
              (if proto2?
                  (format "~aputFixedField(out, ~a, fixedBytes(~a, ~a, (dv, x) => dv.set~a(0, x, true)));\n"
                          indent n v (second info) (third info))
                  (format "~aif (~a) putFixedField(out, ~a, fixedBytes(~a, ~a, (dv, x) => dv.set~a(0, x, true)));\n"
                          indent v n v (second info) (third info))))]
        [(= type 9)
         (if proto2?
             (format "~aputBytesField(out, ~a, new TextEncoder().encode(~a));\n" indent n v)
             (format "~aputStringField(out, ~a, ~a);\n" indent n v))]
        [(= type 12)
         (if proto2?
             (format "~aputBytesField(out, ~a, ~a);\n" indent n v)
             (format "~aif (~a && ~a.length) putBytesField(out, ~a, ~a);\n" indent v v n v))]
        [(= type 11)
         (define entry (js-pb-resolve model (hash-ref f 'type-name)))
         (define ref (js-pb-flat (hash-ref entry 'pkg) (hash-ref (hash-ref entry 'msg) 'full-name)))
         (format "~aif (~a) putBytesField(out, ~a, ~a.encode(~a));\n" indent v n ref v)]
        [else (error 'emit-js-pb-file "unsupported field type ~a (groups)" type)]))

(define (js-pb-encode-field model f)
  (define v (format "msg.~a" (js-pb-name f)))
  (define n (hash-ref f 'number))
  (define type (hash-ref f 'type))
  (cond [(and (= type 11)
              (eq? (hash-ref (js-pb-resolve model (hash-ref f 'type-name)) 'kind) 'map))
         (define entry (js-pb-resolve model (hash-ref f 'type-name)))
         (define helper (string-append (js-pb-flat (hash-ref entry 'pkg) (hash-ref (hash-ref entry 'msg) 'full-name)) "Encode"))
         (format "    if (~a) for (const [k, val] of ~a) putBytesField(out, ~a, ~a(k, val));\n" v v n helper)]
        [(not (= (hash-ref f 'label) 3)) (js-pb-encode-singular model f v "    ")]
        [(memv type js-pb-varint-types)
         (string-append
          (format "    if (~a && ~a.length) {\n      const payload = [];\n" v v)
          (format "      for (const x of ~a) payload.push(...varintBytes(~a));\n" v (js-pb-varint-expr f "x"))
          (format "      putBytesField(out, ~a, payload);\n    }\n" n))]
        [(js-pb-fixed-info type)
         => (lambda (info)
              (string-append
               (format "    if (~a && ~a.length) {\n" v v)
               (format "      const payload = new Uint8Array(~a.length * ~a);\n" v (second info))
               "      const dv = new DataView(payload.buffer);\n"
               (format "      ~a.forEach((x, i) => dv.set~a(i * ~a, x, true));\n" v (third info) (second info))
               (format "      putBytesField(out, ~a, payload);\n    }\n" n)))]
        [(= type 9)
         (format "    if (~a) for (const v of ~a) putBytesField(out, ~a, new TextEncoder().encode(v));\n" v v n)]
        [(= type 12)
         (format "    if (~a) for (const v of ~a) putBytesField(out, ~a, v);\n" v v n)]
        [(= type 11)
         (define entry (js-pb-resolve model (hash-ref f 'type-name)))
         (define ref (js-pb-flat (hash-ref entry 'pkg) (hash-ref (hash-ref entry 'msg) 'full-name)))
         (format "    if (~a) for (const v of ~a) putBytesField(out, ~a, ~a.encode(v));\n" v v n ref)]
        [else (error 'emit-js-pb-file "unsupported repeated field type ~a" type)]))

(define (js-pb-decode-singular model f target src)
  (define type (hash-ref f 'type))
  (define value (or src "value"))
  (cond [(memv type js-pb-varint-types)
         (format "~a = ~a;" target (js-pb-varint-decode f value))]
        [(js-pb-fixed-info type)
         => (lambda (info)
              (format "~a = readFixed(~a, (dv) => dv.get~a(0, true));" target value (third info)))]
        [(= type 9) (format "~a = new TextDecoder().decode(~a);" target value)]
        [(= type 12) (format "~a = ~a;" target value)]
        [(= type 11)
         (define entry (js-pb-resolve model (hash-ref f 'type-name)))
         (format "~a = ~a.decode(~a);" target
                 (js-pb-flat (hash-ref entry 'pkg) (hash-ref (hash-ref entry 'msg) 'full-name)) value)]
        [else (error 'emit-js-pb-file "unsupported field type ~a" type)]))

(define (js-pb-oneof-clearing model f)
  (apply string-append
         (map (lambda (sib)
                (format "msg.~a = ~a; " (js-pb-name sib) (js-pb-default sib model)))
              (oneof-siblings model f))))

(define (js-pb-set-expr sib)
  (define v (format "msg.~a" (js-pb-name sib)))
  (case (hash-ref sib 'type)
    [(11 10) v]
    [(9) (format "~a !== \"\"" v)]
    [(12) (format "(~a && ~a.length > 0)" v v)]
    [(8) v]
    [else (if (memv (hash-ref sib 'type) js-pb-bigint-types)
              (format "~a !== 0n" v)
              (format "~a !== 0" v))]))

;; Encode-side oneof clearing: suppress f when a later sibling is
;; set, so only the winning member is written.
(define (js-pb-encode-guard model f code)
  (define later (oneof-later-siblings model f))
  (if (null? later)
      code
      (format "    if (!(~a)) {\n~a    }\n"
              (string-join (map js-pb-set-expr later) " || ")
              (if (string-suffix? code "\n") code (string-append code "\n")))))

(define (js-pb-decode-case model f)
  (define target (format "msg.~a" (js-pb-name f)))
  (define head (format "      case ~a: " (hash-ref f 'number)))
  (define clearing (js-pb-oneof-clearing model f))
  (define type (hash-ref f 'type))
  (cond [(and (= type 11)
              (eq? (hash-ref (js-pb-resolve model (hash-ref f 'type-name)) 'kind) 'map))
         (define entry (js-pb-resolve model (hash-ref f 'type-name)))
         (define helper (string-append (js-pb-flat (hash-ref entry 'pkg) (hash-ref (hash-ref entry 'msg) 'full-name)) "Decode"))
         (format "~a{ const [k, val] = ~a(value); ~a.set(k, val); break; }\n" head helper target)]
        [(not (= (hash-ref f 'label) 3))
         (format "~a~a~a break;\n" head clearing (js-pb-decode-singular model f target #f))]
        [(memv type js-pb-varint-types)
         (format "~a~aif (wire === 2) { const r = new Reader(value); while (!r.done) ~a.push(~a); } else ~a.push(~a); break;\n"
                 head clearing target (js-pb-varint-decode f "r.varint()") target (js-pb-varint-decode f "value"))]
        [(js-pb-fixed-info type)
         => (lambda (info)
              (format "~aif (wire === 2) { const r = new Reader(value); while (!r.done) ~a.push(readFixed(r.take(~a), (dv) => dv.get~a(0, true))); } else ~a.push(readFixed(value, (dv) => dv.get~a(0, true))); break;\n"
                      head target (second info) (third info) target (third info)))]
        [else
         (format "~a~a.push(~a); break;\n" head target
                 (cond [(= type 9) "new TextDecoder().decode(value)"]
                       [(= type 12) "value"]
                       [else
                        (define entry (js-pb-resolve model (hash-ref f 'type-name)))
                        (format "~a.decode(value)" (js-pb-flat (hash-ref entry 'pkg) (hash-ref (hash-ref entry 'msg) 'full-name)))]))]))

(define (js-pb-map-helpers model entry)
  (define msg (hash-ref entry 'msg))
  (define base (js-pb-flat (hash-ref entry 'pkg) (hash-ref msg 'full-name)))
  (define key-f (findf (lambda (x) (= (hash-ref x 'number) 1)) (hash-ref msg 'fields)))
  (define val-f (findf (lambda (x) (= (hash-ref x 'number) 2)) (hash-ref msg 'fields)))
  (unless (and key-f val-f) (error 'emit-js-pb-file "map entry ~a lacks key/value fields" (hash-ref msg 'full-name)))
  (string-append
   (format "function ~aEncode(key, value) {\n  const out = [];\n" base)
   (js-pb-encode-singular model key-f "key" "  ")
   (js-pb-encode-singular model val-f "value" "  ")
   "  return new Uint8Array(out);\n}\n\n"
   (format "function ~aDecode(bytes) {\n" base)
   (format "  let key = ~a;\n  let value = ~a;\n" (js-pb-default key-f model) (js-pb-default val-f model))
   "  const reader = new Reader(bytes);\n  let f;\n  while ((f = reader.field()) !== null) {\n    const [num, wire, raw] = f;\n    switch (num) {\n"
   (format "      case ~a: ~a break;\n" (hash-ref key-f 'number) (js-pb-decode-singular model key-f "key" "raw"))
   (format "      case ~a: ~a break;\n" (hash-ref val-f 'number) (js-pb-decode-singular model val-f "value" "raw"))
   "    }\n  }\n  return [key, value];\n}\n\n"))

(define (js-pb-enum-const entry)
  (define e (hash-ref entry 'enum))
  (unless e (error 'emit-js-pb-file "enum entry without enum"))
  (define full (if (hash-ref entry 'msg)
                   (format "~a.~a" (hash-ref (hash-ref entry 'msg) 'full-name) (hash-ref e 'name))
                   (if (string=? (hash-ref entry 'pkg) "") (hash-ref e 'name)
                       (format "~a.~a" (hash-ref entry 'pkg) (hash-ref e 'name)))))
  (format "export const ~a = { ~a };\n\n"
          (js-pb-flat (hash-ref entry 'pkg) full)
          (string-join (map (lambda (v) (format "~a: ~a" (hash-ref v 'name) (hash-ref v 'number)))
                            (hash-ref e 'values)) ", ")))

(define (js-pb-message-class model msg)
  (define name (js-pb-flat (hash-ref model 'package) (hash-ref msg 'full-name)))
  (define params (string-join (map (lambda (f) (format "~a = ~a" (js-pb-name f) (js-pb-default f model)))
                                   (hash-ref msg 'fields)) ", "))
  (string-append
   (format "export class ~a {\n" name)
   (format "  constructor({ ~a } = {}) {\n" params)
   (apply string-append (map (lambda (f) (format "    this.~a = ~a;\n" (js-pb-name f) (js-pb-name f))) (hash-ref msg 'fields)))
   "    this.unknownFields = new Uint8Array(0);\n"
   "  }\n"
   "  static encode(msg) {\n    const out = [];\n"
   (apply string-append (map (lambda (f) (js-pb-encode-guard model f (js-pb-encode-field model f))) (hash-ref msg 'fields)))
   "    out.push(...msg.unknownFields);\n"
   "    return new Uint8Array(out);\n  }\n"
   (format "  static decode(bytes) {\n    const msg = new ~a();\n" name)
   "    const reader = new Reader(bytes);\n    let f;\n    while ((f = reader.field()) !== null) {\n      const [num, wire, value, raw] = f;\n      switch (num) {\n"
   (apply string-append (map (lambda (f) (js-pb-decode-case model f)) (hash-ref msg 'fields)))
   "        default: msg.unknownFields = concatBytes(msg.unknownFields, raw); break;\n"
   "      }\n    }\n    return msg;\n  }\n}\n\n"))

(define (emit-js-pb-file file-model)
  (and (hash-has-key? file-model 'messages)
       (hash-has-key? file-model 'types)
       (emit-js-pb-file/inner file-model)))

(define (emit-js-pb-file/inner file-model)
  (define messages (hash-ref file-model 'messages))
  (define service-types
    (remove-duplicates
     (append-map (lambda (svc)
                   (append-map (lambda (m) (list (hash-ref m 'input-full) (hash-ref m 'output-full)))
                               (hash-ref svc 'methods)))
                 (hash-ref file-model 'services))))
  (define imports (make-hash))
  (define reexports (make-hash))
  (define (add-import! entry also-export?)
    (unless (equal? (hash-ref entry 'file) (hash-ref file-model 'name))
      (define flat (js-pb-entry-flat entry))
      (define dep (hash-ref entry 'file))
      (hash-update! imports dep (lambda (s) (set-add s flat)) (set))
      (when also-export?
        (hash-update! reexports dep (lambda (s) (set-add s flat)) (set)))))
  (define (scan-fields msg)
    (for ([f (in-list (hash-ref msg 'fields))])
      (when (memv (hash-ref f 'type) '(11 14))
        (define e (js-pb-resolve file-model (hash-ref f 'type-name)))
        (add-import! e #f)
        (when (and (= (hash-ref f 'type) 11) (eq? (hash-ref e 'kind) 'map))
          (for ([ef (in-list (hash-ref (hash-ref e 'msg) 'fields))])
            (when (memv (hash-ref ef 'type) '(11 14))
              (add-import! (js-pb-resolve file-model (hash-ref ef 'type-name)) #f))))))
    (for ([n (in-list (hash-ref msg 'nested))]) (scan-fields n)))
  (for ([m (in-list messages)]) (scan-fields m))
  (for ([t (in-list service-types)])
    (define e (hash-ref (hash-ref file-model 'types) t #f))
    (when (and e (not (eq? (hash-ref e 'kind) 'enum))) (add-import! e #t)))
  (and (or (pair? messages) (positive? (hash-count reexports)))
       (let ()
         (define base (path->string (path-replace-extension
                                     (file-name-from-path (hash-ref file-model 'name)) "")))
         (define out (open-output-string))
         (fprintf out "// @generated by protoc-gen-grpc-dc-js (Racket metaprogram). DO NOT EDIT.\n")
         (fprintf out "// source: ~a\n\n" (hash-ref file-model 'name))
         (for ([dep (in-list (sort (hash-keys imports) string<?))])
           (fprintf out "import { ~a } from \"./~a_pb.js\";\n"
                    (string-join (sort (set->list (hash-ref imports dep)) string<?) ", ")
                    (path->string (path-replace-extension (file-name-from-path dep) ""))))
         (when (positive? (hash-count imports)) (fprintf out "\n"))
         (display js-pb-preamble out)
         (define exported (mutable-set))
         (define enum-entries '())
         (define (collect-enums msg)
           (for ([e (in-list (hash-ref msg 'enums))])
             (set! enum-entries
                   (cons (hash-ref (hash-ref file-model 'types)
                                   (format "~a.~a" (hash-ref msg 'full-name) (hash-ref e 'name)) #f)
                         enum-entries)))
           (for ([n (in-list (hash-ref msg 'nested))]) (collect-enums n)))
         (for ([m (in-list messages)]) (collect-enums m))
         (for ([e (in-list (hash-ref file-model 'enums))])
           (set! enum-entries
                 (cons (hash-ref (hash-ref file-model 'types)
                                 (if (string=? (hash-ref file-model 'package) "")
                                     (hash-ref e 'name)
                                     (format "~a.~a" (hash-ref file-model 'package) (hash-ref e 'name))) #f)
                       enum-entries)))
         (for ([e (in-list (reverse enum-entries))])
           (when e
             (define name (js-pb-entry-flat e))
             (unless (set-member? exported name)
               (set-add! exported name)
               (display (js-pb-enum-const e) out))))
         (define seen-maps (mutable-set))
         (define (emit-map-helpers msg)
           (for ([f (in-list (hash-ref msg 'fields))])
             (when (= (hash-ref f 'type) 11)
               (define e (js-pb-resolve file-model (hash-ref f 'type-name)))
               (when (and (eq? (hash-ref e 'kind) 'map)
                          (not (set-member? seen-maps (hash-ref (hash-ref e 'msg) 'full-name))))
                 (set-add! seen-maps (hash-ref (hash-ref e 'msg) 'full-name))
                 (display (js-pb-map-helpers file-model e) out))))
           (for ([n (in-list (hash-ref msg 'nested))]) (emit-map-helpers n)))
         (for ([m (in-list messages)]) (emit-map-helpers m))
         (define (emit-msg msg)
           (unless (hash-ref msg 'map-entry)
             (display (js-pb-message-class file-model msg) out)
             (set-add! exported (js-pb-flat (hash-ref file-model 'package) (hash-ref msg 'full-name)))
             (for ([n (in-list (hash-ref msg 'nested))]) (emit-msg n))))
         (for ([m (in-list messages)]) (emit-msg m))
         (define (emit-aliases msg)
           (for ([n (in-list (hash-ref msg 'nested))])
             (when (and (not (hash-ref n 'map-entry))
                        (not (set-member? exported (hash-ref n 'name))))
               (fprintf out "export const ~a = ~a;\n" (hash-ref n 'name)
                        (js-pb-flat (hash-ref file-model 'package) (hash-ref n 'full-name)))
               (set-add! exported (hash-ref n 'name)))
             (emit-aliases n)))
         (for ([m (in-list messages)]) (emit-aliases m))
         (for ([dep (in-list (sort (hash-keys reexports) string<?))])
           (define fresh (filter (lambda (n) (not (set-member? exported n)))
                                 (sort (set->list (hash-ref reexports dep)) string<?)))
           (when (pair? fresh)
             (fprintf out "export { ~a } from \"./~a_pb.js\";\n" (string-join fresh ", ")
                      (path->string (path-replace-extension (file-name-from-path dep) "")))))
         (cons (string-append base "_pb.js") (get-output-string out)))))

(define (emit-js-file file-model params)
  (define base (path->string (path-replace-extension
                              (file-name-from-path (hash-ref file-model 'name)) "")))
  (define pb-import (hash-ref params 'pb_import (format "./~a_pb.js" base)))
  (define types
    (remove-duplicates
     (append-map (lambda (s)
                   (append-map (lambda (m) (list (hash-ref m 'input) (hash-ref m 'output)))
                               (hash-ref s 'methods)))
                 (hash-ref file-model 'services))))
  (define stub
    (cons (string-append base "_grpc_dc.js")
          (string-append
           "// @generated by protoc-gen-grpc-dc-js (Racket metaprogram). DO NOT EDIT.\n"
           (format "// source: ~a\n" (hash-ref file-model 'name))
           (if (null? types)
               ""
               (format "import { ~a } from ~s;\n\n" (string-join types ", ") pb-import))
           (apply string-append
                  (map js-service (hash-ref file-model 'services))))))
  (define pb-file (emit-js-pb-file file-model))
  (if pb-file (list stub pb-file) stub))
