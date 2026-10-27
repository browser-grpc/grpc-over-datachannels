#lang racket

;;; template-js.rkt — emitter body spliced into protoc-gen-grpc-dc-js.
;;;
;;; Generated code imports message classes from `./<base>_pb.js` (override
;;; with the protoc plugin parameter `pb_import`).  A message class must
;;; expose `static encode(msg) -> Uint8Array` and `static decode(bytes)`.

(require "spec.rkt" "desc.rkt" "segments.rkt")
(provide emit-js-file)

(define (js-deprecated m indent)
  (run-segments js-deprecated-program m "" #f (list indent)))
(define (js-client-method m)
  (run-segments js-client-method-program m ""))
(define (js-method-table-entry m)
  (run-segments js-method-table-entry-program m ""))
(define (js-service svc)
  (run-segments js-service-program svc (hash-ref svc 'name)))
(define js-pb-preamble
  (string-append
   "function varintBytes(value) {\n  let n = BigInt.asUintN(64, BigInt(value));\n  const out = [];\n  while (n > 0x7fn) {\n    out.push(Number((n & 0x7fn) | 0x80n));\n    n >>= 7n;\n  }\n  out.push(Number(n));\n  return out;\n}\n\n"
   "function zz64(v) {\n  const b = BigInt(v);\n  return (b << 1n) ^ (b >> 63n);\n}\n\nfunction unzz64(v) {\n  return (v >> 1n) ^ (-(v & 1n));\n}\n\n"
   "class Reader {\n  constructor(bytes) {\n    this.bytes = bytes;\n    this.pos = 0;\n  }\n  get done() {\n    return this.pos >= this.bytes.length;\n  }\n"
   "  varint() {\n    let result = 0n;\n    let shift = 0n;\n    for (;;) {\n      if (this.pos >= this.bytes.length) throw new Error(\"truncated varint\");\n      const byte = this.bytes[this.pos++];\n      result |= BigInt(byte & 0x7f) << shift;\n      if ((byte & 0x80) === 0) return result;\n      shift += 7n;\n      if (shift >= 64n) throw new Error(\"varint too long\");\n    }\n  }\n"
   "  take(n) {\n    const value = this.bytes.slice(this.pos, this.pos + n);\n    if (value.length !== n) throw new Error(\"truncated field\");\n    this.pos += n;\n    return value;\n  }\n"
   "  field() {\n    if (this.done) return null;\n    const start = this.pos;\n    const tag = this.varint();\n    const field = Number(tag >> 3n);\n    const wire = Number(tag & 7n);\n    switch (wire) {\n      case 0:\n        return [field, wire, this.varint(), this.bytes.slice(start, this.pos)];\n      case 2: {\n        const len = Number(this.varint());\n        const v = this.take(len);\n        return [field, wire, v, this.bytes.slice(start, this.pos)];\n      }\n      case 1: {\n        const v = this.take(8);\n        return [field, wire, v, this.bytes.slice(start, this.pos)];\n      }\n      case 5: {\n        const v = this.take(4);\n        return [field, wire, v, this.bytes.slice(start, this.pos)];\n      }\n      default:\n        throw new Error(\"bad wire type \" + wire);\n    }\n  }\n}\n\n"
   "function concatBytes(a, b) {\n  const out = new Uint8Array(a.length + b.length);\n  out.set(a);\n  out.set(b, a.length);\n  return out;\n}\n\n"
   "function putRaw(out, bytes) {\n  for (let i = 0; i < bytes.length; i++) out.push(bytes[i]);\n}\n\n"
   "function putTag(out, num, wire) {\n  out.push(...varintBytes((BigInt(num) << 3n) | BigInt(wire)));\n}\n\n"
   "function putVarintField(out, num, value) {\n  if (value === 0n) return;\n  putTag(out, num, 0);\n  out.push(...varintBytes(value));\n}\n\n"
   "function putBytesField(out, num, payload) {\n  putTag(out, num, 2);\n  putRaw(out, varintBytes(payload.length));\n  putRaw(out, payload);\n}\n\n"
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

(define (js-pb-varint-expr f v)
  (run-segments js-pb-varint-expr-program f "" #f (list v)))
(define (js-pb-varint-decode f v)
  (run-segments js-pb-varint-decode-program f "" #f (list v)))
(define (js-pb-explicit-literal model f)
  (define lit (run-segments js-pb-explicit-literal-program f "" model))
  (and (not (string=? lit "")) lit))
(define (js-pb-default f model)
  (run-segments js-pb-default-program f "" model))
(define (js-pb-resolve model type-name)
  (hash-ref (hash-ref model 'types) type-name
            (lambda () (error 'emit-js-pb-file "unresolved type ~a" type-name))))

(define (js-pb-entry-flat entry)
  (js-pb-flat (hash-ref entry 'pkg)
              (if (eq? (hash-ref entry 'kind) 'enum)
                  ;; 'full includes the parent message: nested
                  ;; enums must not collide on their simple name.
                  (hash-ref entry 'full)
                  (hash-ref (hash-ref entry 'msg) 'full-name))))

(define (js-pb-encode-singular model f v indent)
  (run-segments js-pb-encode-singular-program f "" model (list v indent)))
(define (js-pb-encode-field model f)
  (run-segments js-pb-encode-field-program f "" model))
(define (js-pb-decode-singular model f target src)
  (run-segments js-pb-decode-singular-program f "" model (list target (or src "value"))))
(define (js-pb-oneof-clearing model f)
  (run-segments js-pb-oneof-clearing-program f "" model))
(define (js-pb-decode-case model f)
  (run-segments js-pb-decode-case-program f "" model))
(define (js-pb-map-helpers model entry)
  (run-segments js-pb-map-helpers-program entry "" model))
(define (js-pb-enum-const entry)
  (run-segments js-pb-enum-const-program entry ""))
(define (js-pb-message-class model msg)
  (run-segments js-pb-message-program msg "" model))
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
         (fprintf out "// @generated by protoc-gen-grpc-dc-js. DO NOT EDIT.\n")
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
           "// @generated by protoc-gen-grpc-dc-js. DO NOT EDIT.\n"
           (format "// source: ~a\n" (hash-ref file-model 'name))
           (if (null? types)
               ""
               (format "import { ~a } from ~s;\n\n" (string-join types ", ") pb-import))
           (apply string-append
                  (map js-service (hash-ref file-model 'services))))))
  (define pb-file (emit-js-pb-file file-model))
  (if pb-file (list stub pb-file) stub))
