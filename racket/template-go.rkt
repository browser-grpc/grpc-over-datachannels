#lang racket

;;; template-go.rkt — emitter body spliced into protoc-gen-grpc-dc-go.
;;;
;;; Generated code lives in the proto's Go package (plugin parameter
;;; `go_package` overrides) alongside hand-written message types that
;;; implement grpcdc.Marshaler / grpcdc.Unmarshaler (MarshalDC /
;;; UnmarshalDC), and imports the runtime as grpcdc.

(require "spec.rkt" "desc.rkt" "segments.rkt")
(provide emit-go-file)

(define (go-package file-model params)
  (define override (hash-ref params 'go_package #f))
  (cond [override override]
        [else
         (define pkg (hash-ref file-model 'package))
         (define parts (string-split pkg "."))
         (if (null? parts) "proto" (last parts))]))

;; The client-method emitter needs the service name; bind it dynamically
;; per service instead of threading it through every format call.
(define current-service (make-parameter ""))

(define (go-deprecated m)
  (run-segments go-deprecated-program m (current-service)))

(define (go-client-method* m)
  (run-segments go-client-method-program m (current-service)))

(define (go-server-iface-method/deprecated m)
  (run-segments go-server-iface-method-deprecated-program m (current-service)))

(define (go-server-iface-method m)
  (run-segments go-server-iface-method-program m (current-service)))

(define (go-stream-ifaces m)
  (run-segments go-stream-ifaces-program m (current-service)))

(define (go-register-method m)
  ;; Emission lives in segments.rkt (go-register-method-program),
  ;; shared with the browser generators; edit it there.
  (run-segments go-register-method-program m (current-service)))

(define (go-stream-impls m)
  (run-segments go-stream-impls-program m (current-service)))

(define (go-service svc)
  ;; Emission lives in segments.rkt (go-service-program and the
  ;; per-method programs it calls), shared with the browser
  ;; generators; edit them there.
  (run-segments go-service-program svc (hash-ref svc 'name)))

(define go-pb-varint-types varint-scalar-types)
(define go-pb-fixed (fixed-scalar-table 'go))

(define go-pb-preamble
  (string-append
   "func appendVarint(out []byte, v uint64) []byte {\n\tfor v > 0x7f {\n\t\tout = append(out, byte(v&0x7f)|0x80)\n\t\tv >>= 7\n\t}\n\treturn append(out, byte(v))\n}\n\n"
   "func appendTag(out []byte, field int, wire int) []byte {\n\treturn appendVarint(out, uint64(field<<3|wire))\n}\n\n"
   "func appendBytesField(out []byte, field int, payload []byte) []byte {\n\tout = appendTag(out, field, 2)\n\tout = appendVarint(out, uint64(len(payload)))\n\treturn append(out, payload...)\n}\n\n"
   "func appendStringField(out []byte, field int, value string) []byte {\n\tif value == \"\" {\n\t\treturn out\n\t}\n\treturn appendBytesField(out, field, []byte(value))\n}\n\n"
   "func zz32(v int32) uint64 { return uint64(uint32((v << 1) ^ (v >> 31))) }\n\nfunc zz64(v int64) uint64 { return uint64((v << 1) ^ (v >> 63)) }\n\n"
   "func unzz32(v uint64) int32 { return int32(uint32(v>>1) ^ uint32(-int32(v&1))) }\n\nfunc unzz64(v uint64) int64 { return int64(v>>1) ^ -int64(v&1) }\n\n"
   "type pbReader struct {\n\tbuf []byte\n\tpos int\n}\n\n"
   "func (r *pbReader) varint() (uint64, error) {\n\tvar result uint64\n\tvar shift uint\n\tfor {\n\t\tif r.pos >= len(r.buf) {\n\t\t\treturn 0, errors.New(\"truncated varint\")\n\t\t}\n\t\tb := r.buf[r.pos]\n\t\tr.pos++\n\t\tresult |= uint64(b&0x7f) << shift\n\t\tif b&0x80 == 0 {\n\t\t\treturn result, nil\n\t\t}\n\t\tshift += 7\n\t\tif shift >= 64 {\n\t\t\treturn 0, errors.New(\"varint too long\")\n\t\t}\n\t}\n}\n\n"
   "func (r *pbReader) take(n int) ([]byte, error) {\n\tif r.pos+n > len(r.buf) {\n\t\treturn nil, errors.New(\"truncated field\")\n\t}\n\tv := r.buf[r.pos : r.pos+n]\n\tr.pos += n\n\treturn v, nil\n}\n\n"
   "// field returns (number, value, done, error); value is uint64 for\n// varints and []byte for length-delimited/fixed fields.\n"
   "func (r *pbReader) field() (int, int, any, []byte, bool, error) {\n\tif r.pos >= len(r.buf) {\n\t\treturn 0, 0, nil, nil, true, nil\n\t}\n\tstart := r.pos\n\ttag, err := r.varint()\n\tif err != nil {\n\t\treturn 0, 0, nil, nil, false, err\n\t}\n\tnum := int(tag >> 3)\n\twire := int(tag & 7)\n\tswitch wire {\n\tcase 0:\n\t\tv, err := r.varint()\n\t\treturn num, wire, v, r.buf[start:r.pos], false, err\n\tcase 2:\n\t\tn, err := r.varint()\n\t\tif err != nil {\n\t\t\treturn 0, 0, nil, nil, false, err\n\t\t}\n\t\tv, err := r.take(int(n))\n\t\treturn num, wire, v, r.buf[start:r.pos], false, err\n\tcase 1:\n\t\tv, err := r.take(8)\n\t\treturn num, wire, v, r.buf[start:r.pos], false, err\n\tcase 5:\n\t\tv, err := r.take(4)\n\t\treturn num, wire, v, r.buf[start:r.pos], false, err\n\tdefault:\n\t\treturn 0, 0, nil, nil, false, errors.New(\"bad wire type\")\n\t}\n}\n\n"))

(define (go-pb-pascal s)
  (string-join
   (map (lambda (part)
          (if (string=? part "") "" (string-append (string (char-upcase (string-ref part 0))) (substring part 1))))
        (string-split s "_")) ""))

(define (go-pb-flat pkg full)
  (define rel (if (and pkg (not (string=? pkg ""))
                       (string-prefix? full (string-append pkg ".")))
                  (substring full (add1 (string-length pkg)))
                  full))
  (string-join (string-split rel ".") "_"))

(define (go-pb-resolve model type-name)
  (hash-ref (hash-ref model 'types) type-name
            (lambda () (error 'emit-go-pb-file "unresolved type ~a" type-name))))

(define (go-pb-entry-type entry)
  (go-pb-flat (hash-ref entry 'pkg)
              (if (eq? (hash-ref entry 'kind) 'enum)
                  ;; 'full is the fully-qualified name, parent
                  ;; message included: nested enums must not
                  ;; collide on their simple name (registry enum
                  ;; entries carry no parent in 'msg).
                  (hash-ref entry 'full)
                  (hash-ref (hash-ref entry 'msg) 'full-name))))

(define (go-pb-scalar-type f) (scalar-type-entry 'go (hash-ref f 'type)))

(define (go-pb-field-type model f)
  (define type (hash-ref f 'type))
  (define base
    (cond [(= type 11)
           (define entry (go-pb-resolve model (hash-ref f 'type-name)))
           (if (eq? (hash-ref entry 'kind) 'map)
               (let* ([entry-msg (hash-ref entry 'msg)]
                      [kf (findf (lambda (x) (= (hash-ref x 'number) 1)) (hash-ref entry-msg 'fields))]
                      [vf (findf (lambda (x) (= (hash-ref x 'number) 2)) (hash-ref entry-msg 'fields))])
                 (format "map[~a]~a" (go-pb-field-type model (hash-set kf 'label 1))
                         (go-pb-field-type model (hash-set vf 'label 1))))
               (string-append "*" (go-pb-entry-type entry)))]
          [(= type 14) (go-pb-entry-type (go-pb-resolve model (hash-ref f 'type-name)))]
          [else (go-pb-scalar-type f)]))
  (if (= (hash-ref f 'label) 3)
      (if (and (= type 11)
               (eq? (hash-ref (go-pb-resolve model (hash-ref f 'type-name)) 'kind) 'map))
          base
          (string-append "[]" base))
      base))

(define (go-pb-varint-expr f v)
  (run-segments go-pb-varint-expr-program f "" #f (list v)))

(define (go-pb-varint-decode f v)
  (run-segments go-pb-varint-decode-program f "" #f (list v)))

(define (go-pb-encode-singular model f v indent)
  (run-segments go-pb-encode-singular-program f "" model (list v indent)))

(define (go-pb-encode-field model f)
  (run-segments go-pb-encode-field-program f "" model))

(define go-pb-error-stmt (make-parameter "return err"))

(define (go-pb-decode-singular model f target src indent)
  (run-segments go-pb-decode-singular-program f "" model (list target src indent) (go-pb-error-stmt)))

(define (go-pb-decode-case model f)
  (run-segments go-pb-decode-case-program f "" model))

(define (go-pb-map-helpers model entry)
  (run-segments go-pb-map-helpers-program entry "" model '() "return key, value, err"))

(define (go-pb-enum entry)
  (run-segments go-pb-enum-program entry "" #f (list (go-pb-entry-type entry))))

(define (go-pb-constructor model msg)
  (run-segments go-pb-constructor-program msg "" model))

(define (go-pb-message model msg)
  ;; Emission lives in segments.rkt (go-pb-message-program and
  ;; the field programs it calls), shared with the browser
  ;; generators; edit them there.
  (run-segments go-pb-message-program msg "" model))

(define (go-pb-apply-prefix content prefix)
  ;; Helper identifiers are file-scoped so several generated
  ;; <base>_pb.go files can share one Go package.
  (for/fold ([s content])
            ([pair (in-list '(("appendVarint" "AppendVarint")
                              ("appendTag" "AppendTag")
                              ("appendBytesField" "AppendBytesField")
                              ("appendStringField" "AppendStringField")
                              ("boolToUint64" "BoolToUint64")
                              ("fixed32Bytes" "Fixed32Bytes")
                              ("fixed64Bytes" "Fixed64Bytes")
                              ("pbFloat32Bits" "Float32Bits")
                              ("pbFloat32FromBits" "Float32FromBits")
                              ("pbFloat64Bits" "Float64Bits")
                              ("pbFloat64FromBits" "Float64FromBits")
                              ("pbReader" "Reader")
                              ("structCheck" "StructCheck")
                              ("structdcTranscode" "StructdcTranscode")
                              ("structdcDescriptor" "StructdcDescriptor")
                              ("unzz32" "Unzz32")
                              ("unzz64" "Unzz64")
                              ("zz32" "Zz32")
                              ("zz64" "Zz64")))])
    (regexp-replace* (pregexp (string-append "\\b" (car pair) "\\b")) s
                     (string-append prefix (cadr pair)))))

(define (emit-go-pb-file file-model params)
  (and (hash-has-key? file-model 'messages)
       (hash-has-key? file-model 'types)
       (emit-go-pb-file/inner file-model params)))

(define (emit-go-pb-file/inner file-model params)
  (define messages (hash-ref file-model 'messages))
  (and (or (pair? messages) (pair? (hash-ref file-model 'enums)))
       (let ()
         (define base (path->string (path-replace-extension
                                     (file-name-from-path (hash-ref file-model 'name)) "")))
         (define out (open-output-string))
         (fprintf out "// @generated by protoc-gen-grpc-dc-go. DO NOT EDIT.\n")
         (fprintf out "// source: ~a\n\n" (hash-ref file-model 'name))
         (fprintf out "package ~a\n\n" (go-package file-model params))
         (fprintf out "import (\n\t\"encoding/binary\"\n\t\"errors\"\n\t\"math\"~a\n)\n\n"
                  (if (for*/or ([msg (in-list messages)] [f (in-list (hash-ref msg 'fields))])
                        (and (= (hash-ref f 'type) 11)
                             (eq? (hash-ref (go-pb-resolve file-model (hash-ref f 'type-name)) 'kind) 'map)))
                      "\n\t\"sort\"" ""))
         (fprintf out "func boolToUint64(b bool) uint64 {\n\tif b {\n\t\treturn 1\n\t}\n\treturn 0\n}\n\n")
         (fprintf out "func fixed32Bytes(v uint32) []byte {\n\tvar b [4]byte\n\tbinary.LittleEndian.PutUint32(b[:], v)\n\treturn b[:]\n}\n\n")
         (fprintf out "func fixed64Bytes(v uint64) []byte {\n\tvar b [8]byte\n\tbinary.LittleEndian.PutUint64(b[:], v)\n\treturn b[:]\n}\n\n")
         (fprintf out "func pbFloat32Bits(f float32) uint32 { return math.Float32bits(f) }\n\nfunc pbFloat32FromBits(u uint32) float32 { return math.Float32frombits(u) }\n\nfunc pbFloat64Bits(f float64) uint64 { return math.Float64bits(f) }\n\nfunc pbFloat64FromBits(u uint64) float64 { return math.Float64frombits(u) }\n\n")
         (display go-pb-preamble out)
         (define (all-enum-entries)
           (define acc '())
           (define (walk msg)
             (for ([e (in-list (hash-ref msg 'enums))])
               (set! acc (cons (hash-ref (hash-ref file-model 'types)
                                         (format "~a.~a" (hash-ref msg 'full-name) (hash-ref e 'name)) #f) acc)))
             (for ([n (in-list (hash-ref msg 'nested))]) (walk n)))
           (for ([m (in-list messages)]) (walk m))
           (for ([e (in-list (hash-ref file-model 'enums))])
             (set! acc (cons (hash-ref (hash-ref file-model 'types)
                                       (if (string=? (hash-ref file-model 'package) "")
                                           (hash-ref e 'name)
                                           (format "~a.~a" (hash-ref file-model 'package) (hash-ref e 'name))) #f) acc)))
           (reverse acc))
         (for ([e (in-list (all-enum-entries))]) (when e (display (go-pb-enum e) out)))
         (define seen-maps (mutable-set))
         (define (emit-map-helpers msg)
           (for ([f (in-list (hash-ref msg 'fields))])
             (when (= (hash-ref f 'type) 11)
               (define e (go-pb-resolve file-model (hash-ref f 'type-name)))
               (when (and (eq? (hash-ref e 'kind) 'map)
                          ;; Skip when the entry's own file is
                          ;; generated too and emits the helpers
                          ;; itself: Go helpers are package-level
                          ;; and would collide.
                          (not (map-entry-emitted-in-own-file? file-model e))
                          (not (set-member? seen-maps (hash-ref (hash-ref e 'msg) 'full-name))))
                 (set-add! seen-maps (hash-ref (hash-ref e 'msg) 'full-name))
                 (display (go-pb-map-helpers file-model e) out))))
           (for ([n (in-list (hash-ref msg 'nested))]) (emit-map-helpers n)))
         (for ([m (in-list messages)]) (emit-map-helpers m))
         (define (emit-msg msg)
           (unless (hash-ref msg 'map-entry)
             (display (go-pb-message file-model msg) out)
             (for ([n (in-list (hash-ref msg 'nested))]) (emit-msg n))))
         (for ([m (in-list messages)]) (emit-msg m))
         (when (equal? (hash-ref params 'struct_codec #f) "true")
           (fprintf out "var structdcDescriptor = []byte{~a}\n\n"
                   (string-join
                    (for/list ([b (in-bytes (hash-ref file-model 'descriptor-set #""))])
                      (format "0x~x" b))
                    ","))
           (define (emit-struct msg)
             (unless (hash-ref msg 'map-entry)
               (display (go-struct-message file-model msg) out))
             (for ([n (in-list (hash-ref msg 'nested))]) (emit-struct n)))
           (for ([m (in-list messages)]) (emit-struct m)))
         (cons (string-append base "_pb.go")
               (go-pb-apply-prefix (get-output-string out)
                                   (string-append (go-pb-pascal base) "Pb"))))))

;; ------------------------------------------------------------------
;; Struct codec (struct_codec=true plugin param): Cap'n-Proto-style
;; layout for low-latency internal paths; protobuf stays the
;; interop format. Layout v1 (packed, little-endian):
;;   header: magic "DCS1" (4), total length u32, schema
;;     fingerprint u32 (FNV-1a of the message full name),
;;     presence words (ceil(nfields/32) u32s; bit i = field i in
;;     field-number order is present)
;;   fixed area: one slot per field in field-number order:
;;     varint family / fixed64 / double / sfixed64: 8 bytes
;;     fixed32 / sfixed32 / float: 4 bytes
;;     string/bytes/message/repeated/map: u32 offset + u32 length
;;     (repeated scalar: offset + count; map: offset + count)
;;   variable area in field order: raw string/bytes, nested
;;     struct encodings, packed repeated scalars, repeated
;;     element tables (u32 off/len per element), map entries
;;     (keys sorted; per entry klen u32, vlen u32, key bytes,
;;     value bytes)
;;   tail: unknown-fields bytes (whatever remains after the
;;     last variable element named by the slots)
(define (go-struct-fingerprint s)
  (for/fold ([h 2166136261]) ([c (in-string s)])
    (modulo (* (bitwise-xor h (char->integer c)) 16777619) 4294967296)))

(define (go-struct-varint-type? t) (member t '(3 4 5 8 13 14 17 18)))
(define (go-struct-fixed32-type? t) (member t '(2 7 15)))
(define (go-struct-fixed64-type? t) (member t '(1 6 16)))

(define (go-struct-slot-size f)
  (define t (hash-ref f 'type))
  (cond [(go-struct-varint-type? t) 8]
        [(go-struct-fixed32-type? t) 4]
        [(go-struct-fixed64-type? t) 8]
        [else 8])) ; string/bytes/message/repeated/map: off+len

(define (go-struct-sorted-fields msg)
  (sort (hash-ref msg 'fields) < #:key (lambda (f) (hash-ref f 'number))))

(define (go-struct-elem-type model f)
  (if (= (hash-ref f 'type) 14)
      (go-pb-entry-type (go-pb-resolve model (hash-ref f 'type-name)))
      (go-pb-scalar-type f)))

(define (go-struct-map-entry model f)
  (and (= (hash-ref f 'type) 11)
       (let ([e (go-pb-resolve model (hash-ref f 'type-name))])
         (and (eq? (hash-ref e 'kind) 'map) e))))

(define (go-struct-present-expr f gn)
  (define t (hash-ref f 'type))
  (cond [(= (hash-ref f 'label) 3) (format "len(m.~a) > 0" gn)]
        [(= t 11) (format "m.~a != nil" gn)]
        [(member t '(9 12)) (format "len(m.~a) > 0" gn)]
        [(= t 8) (format "m.~a" gn)]
        [else (format "m.~a != 0" gn)]))

(define (go-struct-scalar-encode f v)
  (define t (hash-ref f 'type))
  (cond [(go-struct-fixed32-type? t)
         (if (= t 2)
             (format "binary.LittleEndian.PutUint32(buf[off:], math.Float32bits(~a))" v)
             (format "binary.LittleEndian.PutUint32(buf[off:], uint32(~a))" v))]
        [(go-struct-fixed64-type? t)
         (if (= t 1)
             (format "binary.LittleEndian.PutUint64(buf[off:], math.Float64bits(~a))" v)
             (format "binary.LittleEndian.PutUint64(buf[off:], uint64(~a))" v))]
        [(= t 8) (format "if ~a { buf[off] = 1 }" v)]
        [(= t 14) (format "binary.LittleEndian.PutUint64(buf[off:], uint64(int64(~a)))" v)]
        [else (format "binary.LittleEndian.PutUint64(buf[off:], uint64(~a))" v)]))

(define (go-struct-scalar-decode model f target)
  ;; Reads the slot at data[off:]; target is a Go lvalue.
  (define t (hash-ref f 'type))
  (cond [(go-struct-fixed32-type? t)
         (if (= t 2)
             (format "~a = math.Float32frombits(binary.LittleEndian.Uint32(data[off:]))" target)
             (format "~a = ~a(binary.LittleEndian.Uint32(data[off:]))" target
                     (go-pb-scalar-type f)))]
        [(go-struct-fixed64-type? t)
         (if (= t 1)
             (format "~a = math.Float64frombits(binary.LittleEndian.Uint64(data[off:]))" target)
             (format "~a = ~a(binary.LittleEndian.Uint64(data[off:]))" target
                     (go-pb-scalar-type f)))]
        [(= t 8) (format "~a = data[off] != 0" target)]
        [(= t 14) (format "~a = ~a(int32(int64(binary.LittleEndian.Uint64(data[off:]))))" target
                        (go-pb-entry-type (go-pb-resolve model (hash-ref f 'type-name))))]
        [(member t '(3 17 18))
         (format "~a = ~a(int64(binary.LittleEndian.Uint64(data[off:])))" target
                 (go-pb-scalar-type f))]
        [else (format "~a = ~a(binary.LittleEndian.Uint64(data[off:]))" target
                      (go-pb-scalar-type f))]))

(define (go-struct-value-size model f v)
  ;; Go expression (int) for the variable-area size of value v.
  (define t (hash-ref f 'type))
  (cond [(member t '(9 12)) (format "len(~a)" v)]
        [(= t 11) (format "func() int { if ~a == nil { return 0 }; return ~a.structSizeDC() }()" v v)]
        [(go-struct-fixed32-type? t) "4"]
        [else "8"]))

(define (go-struct-value-write model f v)
  ;; Writes value v at buf[vp:], advancing vp by its size.
  (define t (hash-ref f 'type))
  (cond [(member t '(9 12)) (format "vp += copy(buf[vp:], ~a)" v)]
        [(= t 11) (format "if ~a != nil { ~a.marshalStructAt(buf[vp:]); vp += ~a.structSizeDC() }" v v v)]
        [else (format "~a; vp += ~a" (go-struct-elem-write-at f v "vp")
                      (if (go-struct-fixed32-type? t) 4 8))]))

(define (go-struct-elem-write-at f v at)
  (define t (hash-ref f 'type))
  (cond [(go-struct-fixed32-type? t)
         (if (= t 2)
             (format "binary.LittleEndian.PutUint32(buf[~a:], math.Float32bits(~a))" at v)
             (format "binary.LittleEndian.PutUint32(buf[~a:], uint32(~a))" at v))]
        [(go-struct-fixed64-type? t)
         (if (= t 1)
             (format "binary.LittleEndian.PutUint64(buf[~a:], math.Float64bits(~a))" at v)
             (format "binary.LittleEndian.PutUint64(buf[~a:], uint64(~a))" at v))]
        [(= t 8) (format "if ~a { buf[~a] = 1 }" v at)]
        [(= t 14) (format "binary.LittleEndian.PutUint64(buf[~a:], uint64(int64(~a)))" at v)]
        [else (format "binary.LittleEndian.PutUint64(buf[~a:], uint64(~a))" at v)]))

(define (go-struct-map-key-field model f)
  (define em (hash-ref (go-struct-map-entry model f) 'msg))
  (findf (lambda (x) (= (hash-ref x 'number) 1)) (hash-ref em 'fields)))
(define (go-struct-map-val-field model f)
  (define em (hash-ref (go-struct-map-entry model f) 'msg))
  (findf (lambda (x) (= (hash-ref x 'number) 2)) (hash-ref em 'fields)))

(define (go-struct-message model msg)
  (define type-name
    (go-pb-entry-type (hash-ref (hash-ref model 'types) (hash-ref msg 'full-name))))
  (define out (open-output-string))
  (fprintf out "func (m *~a) MarshalStructDC() []byte {\n" type-name)
  (fprintf out "\tout, err := structdcTranscode(true, \"~a\", m.MarshalDC())\n" (hash-ref msg 'full-name))
  (fprintf out "\tif err != nil { panic(err) }\n\treturn out\n}\n\n")
  (fprintf out "func (m *~a) UnmarshalStructDC(data []byte) error {\n" type-name)
  (fprintf out "\tpb, err := structdcTranscode(false, \"~a\", data)\n" (hash-ref msg 'full-name))
  (fprintf out "\tif err != nil { return err }\n\treturn m.UnmarshalDC(pb)\n}\n\n")
  (get-output-string out))

(define (go-struct-value-read model f target lenvar)
  ;; Reads a value of field f's type at data[off:], where off is a
  ;; Go int variable; advances via the returned size expression.
  (define t (hash-ref f 'type))
  (cond [(member t '(9 12))
         (format "~a = ~a(data[off : off+~a])" target (if (= t 9) "string" "") lenvar)]
        [(= t 11)
         (format "if ~a > 0 { ~a = &~a{}; if err := ~a.UnmarshalStructDC(data[off:off+~a]); err != nil { return err } }" lenvar
                 target (go-pb-entry-type (go-pb-resolve model (hash-ref f 'type-name))) target lenvar)]
        [else (go-struct-scalar-decode model f target)]))

(define (go-struct-decode-field model f gn foff)
  (define t (hash-ref f 'type))
  (define out (open-output-string))
  (define slot (format "int(binary.LittleEndian.Uint32(data[~a:]))" foff))
  (define slot4 (format "int(binary.LittleEndian.Uint32(data[~a:]))" (+ foff 4)))
  (cond [(go-struct-map-entry model f)
         (define kf (go-struct-map-key-field model f))
         (define vf (go-struct-map-val-field model f))
         (define kt (go-pb-field-type model (hash-set kf 'label 1)))
         (define vt (go-pb-field-type model (hash-set vf 'label 1)))
         (fprintf out "\t\toff := ~a; n := ~a\n" slot slot4)
         (fprintf out "\t\tm.~a = make(map[~a]~a, n)\n\t\tp := off\n" gn kt vt)
         (fprintf out "\t\tfor i := 0; i < n; i++ {\n\t\t\tif err := structCheck(data, p, 8); err != nil { return err }\n")
         (fprintf out "\t\t\tkl := int(binary.LittleEndian.Uint32(data[p:])); vl := int(binary.LittleEndian.Uint32(data[p+4:])); p += 8\n")
         (fprintf out "\t\t\tif err := structCheck(data, p, kl+vl); err != nil { return err }\n")
         (fprintf out "\t\t\tvar k ~a\n\t\t\t{ off := p; ~a }\n" kt (go-struct-value-read model kf "k" "kl"))
         (fprintf out "\t\t\tvar v ~a\n\t\t\t{ off := p + kl; ~a }\n" vt (go-struct-value-read model vf "v" "vl"))
         (fprintf out "\t\t\tm.~a[k] = v\n\t\t\tp += kl + vl\n\t\t}\n\t\tif p > vend { vend = p }\n" gn)]
        [(= (hash-ref f 'label) 3)
         (fprintf out "\t\toff := ~a; n := ~a\n" slot slot4)
         (cond [(member t '(9 12))
                (fprintf out "\t\tm.~a = make([]~a, n)\n\t\tfor i := 0; i < n; i++ {\n\t\t\teo := int(binary.LittleEndian.Uint32(data[off+8*i:])); el := int(binary.LittleEndian.Uint32(data[off+8*i+4:]))\n\t\t\tif err := structCheck(data, eo, el); err != nil { return err }\n\t\t\tm.~a[i] = ~a(data[eo : eo+el])\n\t\t\tif eo+el > vend { vend = eo + el }\n\t\t}\n"
                         gn (go-pb-scalar-type f) gn (if (= t 9) "string" ""))]
               [(= t 11)
                (fprintf out "\t\tm.~a = make([]~a, n)\n\t\tfor i := 0; i < n; i++ {\n\t\t\teo := int(binary.LittleEndian.Uint32(data[off+8*i:])); el := int(binary.LittleEndian.Uint32(data[off+8*i+4:]))\n\t\t\tif el > 0 {\n\t\t\t\tif err := structCheck(data, eo, el); err != nil { return err }\n\t\t\t\te := &~a{}\n\t\t\t\tif err := e.UnmarshalStructDC(data[eo : eo+el]); err != nil { return err }\n\t\t\t\tm.~a[i] = e\n\t\t\t\tif eo+el > vend { vend = eo + el }\n\t\t\t}\n\t\t}\n"
                         gn (go-pb-field-type model (hash-set f 'label 1))
                         (go-pb-entry-type (go-pb-resolve model (hash-ref f 'type-name))) gn)]
               [else
                (define esz (if (go-struct-fixed32-type? t) 4 8))
                (fprintf out "\t\tif err := structCheck(data, off, n*~a); err != nil { return err }\n\t\tm.~a = make([]~a, n)\n\t\tfor i := 0; i < n; i++ {\n\t\t\toff := off + i*~a\n\t\t\t~a\n\t\t}\n\t\tif off+n*~a > vend { vend = off + n*~a }\n"
                         esz gn (go-struct-elem-type model f) esz
                         (go-struct-scalar-decode model f (format "m.~a[i]" gn)) esz esz)])]
        [(= t 11)
         (fprintf out "\t\toff := ~a; el := ~a\n" slot slot4)
         (fprintf out "\t\tif err := structCheck(data, off, el); err != nil { return err }\n")
         (fprintf out "\t\tm.~a = &~a{}\n\t\tif err := m.~a.UnmarshalStructDC(data[off : off+el]); err != nil { return err }\n\t\tif off+el > vend { vend = off + el }\n"
                  gn (go-pb-entry-type (go-pb-resolve model (hash-ref f 'type-name))) gn)]
        [(member t '(9 12))
         (fprintf out "\t\toff := ~a; el := ~a\n" slot slot4)
         (fprintf out "\t\tif err := structCheck(data, off, el); err != nil { return err }\n")
         (if (= t 9)
             (fprintf out "\t\tm.~a = string(data[off : off+el])\n" gn)
             (fprintf out "\t\tm.~a = data[off : off+el]\n" gn))
         (fprintf out "\t\tif off+el > vend { vend = off + el }\n")]
        [else
         (fprintf out "\t\toff := ~a\n\t\t~a\n" foff
                  (go-struct-scalar-decode model f (format "m.~a" gn)))])
  (get-output-string out))

(define (emit-go-file file-model params)
  (define base (path->string (path-replace-extension
                              (file-name-from-path (hash-ref file-model 'name)) "")))
  (define stub
    (cons (string-append base "_grpc_dc.go")
          (string-append
           "// @generated by protoc-gen-grpc-dc-go. DO NOT EDIT.\n"
           (format "// source: ~a\n\n" (hash-ref file-model 'name))
           (format "package ~a\n\n" (go-package file-model params))
           (if (null? (hash-ref file-model 'services))
               ""
               (format "import (\n\t\"context\"\n\n\tgrpcdc \"~a\"\n)\n\n" go-module-path))
           ;; trace=hooks: re-export the runtime tracer registrar;
           ;; trace_methods bakes the filter in at init.
           (if (and (pair? (hash-ref file-model 'services))
                    (equal? (hash-ref params 'trace #f) "hooks"))
               (string-append
                "// Tracing (trace=hooks@@TRACING_BETA@@): register an observer with\n"
                "// grpcdc.SetTracer, e.g. via the alias below.\n"
                "var SetTracer = grpcdc.SetTracer\n\n"
                "var SetTraceFilter = grpcdc.SetTraceFilter\n\n"
                (let ([methods (hash-ref params 'trace_methods #f)])
                  (if methods
                      (format "func init() { grpcdc.SetTraceFilter(~s) }\n\n" methods)
                      "")))
               "")
           (apply string-append
                  (map go-service (hash-ref file-model 'services))))))
  (define pb-file (emit-go-pb-file file-model params))
  (if (and pb-file (equal? (hash-ref params 'struct_codec #f) "true"))
      (append (list stub pb-file) (go-struct-bridge-files file-model params base))
      (if pb-file (list stub pb-file) stub)))

;; Call-in bridge for the shared Rust struct codec: generated
;; MarshalStructDC/UnmarshalStructDC delegate to libgrpc_dc via
;; cgo (dlopen, no link-time dependency). Without cgo the same
;; signatures exist and fail loudly when called.
(define (go-struct-bridge-files file-model params base)
  (define prefix (string-append (go-pb-pascal base) "Pb"))
  (define pkg (go-package file-model params))
  (define (bridge build-tag body)
    (string-append
     "// @generated by protoc-gen-grpc-dc-go. DO NOT EDIT.\n"
     (format "// source: ~a\n\n" (hash-ref file-model 'name))
     (format "//go:build ~a\n\n" build-tag)
     (format "package ~a\n\n" pkg)
     body))
  (define cgo-body
    (go-pb-apply-prefix
     (string-append
      "/*\n"
      "#cgo LDFLAGS: -ldl\n\n"
      "#include <stdlib.h>\n#include <stdint.h>\n#include <string.h>\n#include <dlfcn.h>\n\n"
      "typedef int (*grpcdc_transcode_fn)(const uint8_t*, size_t, const uint8_t*, size_t, const uint8_t*, size_t, uint8_t**, size_t*, char**);\n"
      "typedef void (*grpcdc_free_fn)(uint8_t*, size_t);\n"
      "typedef void (*grpcdc_errfree_fn)(char*);\n\n"
      "static void* grpcdc_struct_lib(void) {\n"
      "\tstatic void* h;\n"
      "\tif (h) return h;\n"
      "\tconst char* path = getenv(\"GRPCDC_STRUCTDC_LIB\");\n"
      "\tif (path && *path) h = dlopen(path, RTLD_NOW);\n"
      "\tif (!h) h = dlopen(\"libgrpc_dc.so\", RTLD_NOW);\n"
      "\treturn h;\n}\n\n"
      "static int grpcdc_struct_call(int encode, const uint8_t* desc, size_t desc_len, const uint8_t* type, size_t type_len, const uint8_t* in, size_t in_len, uint8_t** out, size_t* out_len, char** err) {\n"
      "\tvoid* h = grpcdc_struct_lib();\n"
      "\tif (!h) return -1;\n"
      "\tgrpcdc_transcode_fn fn = (grpcdc_transcode_fn)dlsym(h, encode ? \"grpcdc_struct_encode\" : \"grpcdc_struct_decode\");\n"
      "\tif (!fn) return -1;\n"
      "\treturn fn(desc, desc_len, type, type_len, in, in_len, out, out_len, err);\n}\n\n"
      "static void grpcdc_struct_free_bytes(uint8_t* p, size_t n) {\n"
      "\tvoid* h = grpcdc_struct_lib();\n"
      "\tif (!h) return;\n"
      "\tgrpcdc_free_fn fn = (grpcdc_free_fn)dlsym(h, \"grpcdc_struct_free\");\n"
      "\tif (fn) fn(p, n);\n}\n\n"
      "static void grpcdc_struct_free_err(char* p) {\n"
      "\tvoid* h = grpcdc_struct_lib();\n"
      "\tif (!h) return;\n"
      "\tgrpcdc_errfree_fn fn = (grpcdc_errfree_fn)dlsym(h, \"grpcdc_struct_error_free\");\n"
      "\tif (fn) fn(p);\n}\n"
      "*/\n"
      "import \"C\"\n\n"
      "import (\n\t\"errors\"\n\t\"unsafe\"\n)\n\n"
      "// structdcTranscode runs one protobuf <-> struct transcode\n"
      "// through the shared Rust struct codec (libgrpc_dc).\n"
      "func structdcTranscode(encode bool, typeName string, in []byte) ([]byte, error) {\n"
      "\tvar out *C.uint8_t;\n\tvar outLen C.size_t;\n\tvar errPtr *C.char;\n"
      "\tenc := C.int(0);\n\tif (encode) { enc = 1 };\n"
      "\tvar inPtr *C.uint8_t;\n\tif (len(in) > 0) { inPtr = (*C.uint8_t)(unsafe.Pointer(&in[0])) };\n"
      "\tvar descPtr *C.uint8_t;\n\tif (len(structdcDescriptor) > 0) { descPtr = (*C.uint8_t)(unsafe.Pointer(&structdcDescriptor[0])) };\n"
      "\trc := C.grpcdc_struct_call(enc, descPtr, C.size_t(len(structdcDescriptor)), (*C.uint8_t)(unsafe.Pointer(unsafe.StringData(typeName))), C.size_t(len(typeName)), inPtr, C.size_t(len(in)), &out, &outLen, &errPtr);\n"
      "\tif (rc != 0) {\n"
      "\t\tmsg := \"struct codec transcode failed (libgrpc_dc unavailable?)\";\n"
      "\t\tif (errPtr != nil) { msg = C.GoString(errPtr); C.grpcdc_struct_free_err(errPtr) };\n"
      "\t\treturn nil, errors.New(msg)\n\t};\n"
      "\tres := C.GoBytes(unsafe.Pointer(out), C.int(outLen));\n"
      "\tC.grpcdc_struct_free_bytes(out, outLen);\n"
      "\treturn res, nil\n}\n")
     prefix))
  (define nocgo-body
    (go-pb-apply-prefix
     (string-append
      "import \"errors\"\n\n"
      "// structdcTranscode requires cgo: the struct codec lives in\n"
      "// the shared Rust core (libgrpc_dc).\n"
      "func structdcTranscode(encode bool, typeName string, in []byte) ([]byte, error) {\n"
      "\treturn nil, errors.New(\"struct codec requires cgo (libgrpc_dc not linked)\")\n}\n")
     prefix))
  (list (cons (string-append base "_structdc.go") (bridge "cgo" cgo-body))
        (cons (string-append base "_structdc_nocgo.go") (bridge "!cgo" nocgo-body))))
