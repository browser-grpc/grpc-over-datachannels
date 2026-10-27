#lang racket

;;; template-go.rkt — emitter body spliced into protoc-gen-grpc-dc-go.
;;;
;;; Generated code lives in the proto's Go package (plugin parameter
;;; `go_package` overrides) alongside hand-written message types that
;;; implement grpcdc.Marshaler / grpcdc.Unmarshaler (MarshalDC /
;;; UnmarshalDC), and imports the runtime as grpcdc.

(require "spec.rkt" "desc.rkt")
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
  (and (pair? messages)
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
         (cons (string-append base "_pb.go")
               (go-pb-apply-prefix (get-output-string out)
                                   (string-append (go-pb-pascal base) "Pb"))))))

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
                "// Tracing (trace=hooks): register an observer with\n"
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
  (if pb-file (list stub pb-file) stub))
