#lang racket

;;; template-java.rkt — emitter body spliced into
;;; protoc-gen-grpc-dc-java.
;;;
;;; Generated code is one final class <Base>GrpcDc in the proto's
;;; package, beside hand-written message types implementing
;;; grpcdc.Marshaler / grpcdc.Unmarshaler, importing the runtime as
;;; grpcdc.*. Method names keep the proto spelling, mirroring Go.

(require "spec.rkt" "desc.rkt" "segments.rkt")
(provide emit-java-file)

(define current-service (make-parameter ""))

(define (pascal sym) ; echo_service -> EchoService
  (apply string-append
         (for/list ([part (in-list (string-split (symbol->string sym) "[_-]"))])
           (if (string=? part "")
               ""
               (string-append (string (char-upcase (string-ref part 0)))
                              (substring part 1))))))

(define (lower-first s)
  (string-append (string (char-downcase (string-ref s 0))) (substring s 1)))

;; Stub type reference for a method input/output: the simple class
;; name when the message lives in the stub file's own package,
;; fully qualified otherwise (Java cannot resolve a simple name
;; across packages). Generated message classes are top-level, one
;; per message, in their proto package.
(define (java-qualify-type pkg simple full)
  (cond [(or (not full) (string=? pkg "")
             (string-prefix? full (string-append pkg ".")))
         simple]
        [else
         (define parts (string-split full "."))
         (string-append (string-join (drop-right parts 1) ".") "." simple)]))

(define (java-qualify-services pkg services)
  (for/list ([svc (in-list services)])
    (hash-set svc 'methods
              (for/list ([m (in-list (hash-ref svc 'methods))])
                (hash-set* m
                           'input (java-qualify-type pkg (hash-ref m 'input)
                                                     (hash-ref m 'input-full #f))
                           'output (java-qualify-type pkg (hash-ref m 'output)
                                                      (hash-ref m 'output-full #f)))))))





(define (java-client-method m)
  (run-segments java-client-method-program m (current-service) #f (list "        ")))

(define (java-client-timeout-method m)
  (run-segments java-client-timeout-method-program m (current-service)))

(define (java-client-stream-class m)
  (run-segments java-client-stream-class-program m (current-service)))



(define (java-server-iface-method m)
  (run-segments java-server-iface-method-program m (current-service) #f (list "        ")))

(define (java-server-stream-ifaces m)
  (run-segments java-server-stream-ifaces-program m (current-service)))

(define (java-register-method m)
  (run-segments java-register-method-program m (current-service)))

(define (java-stream-impls m)
  (run-segments java-stream-impls-program m (current-service)))


(define (java-client-async-method m)
  (run-segments java-client-async-method-program m (current-service)))

(define (java-server-async-iface-method m)
  (run-segments java-server-async-iface-method-program m (current-service)))

(define (java-server-async-adapter-method m)
  (run-segments java-server-async-adapter-method-program m (current-service)))

(define (java-service svc)
  (run-segments java-service-program svc (hash-ref svc 'name)))

;; ---------------------------------------------------------------------------
;; Java message types: one public class per top-level message and
;; one enum per top-level enum, plus a package-private <Base>Pb
;; wire-support class per proto file. Dependency-free (JDK only),
;; implementing grpcdc.Marshaler/Unmarshaler. Mirrors the Python
;; emitter on the shared desc.rkt model.
;; ---------------------------------------------------------------------------

(define java-pb-varint-types varint-scalar-types)
(define java-pb-fixed (fixed-scalar-table 'java))





(define (java-pb-resolve model type-name)
  (hash-ref (hash-ref model 'types) type-name
            (lambda () (error 'emit-java-pb-file "unresolved type ~a" type-name))))

;; Java type reference for a registry entry, from file-model's
;; package: same package -> Outer.Inner; other package -> fully
;; qualified.






(define (java-pb-camel s)
  (define parts (string-split s "_"))
  (if (null? parts)
      s
      (apply string-append (car parts)
             (map (lambda (p) (if (string=? p "") "" (string-append (string (char-upcase (string-ref p 0))) (substring p 1))))
                  (cdr parts)))))

(define (java-pb-field-name f)
  (define jn (hash-ref f 'json-name ""))
  (if (and jn (not (string=? jn ""))) jn (java-pb-camel (hash-ref f 'name))))

(define (java-pb-type model f boxed?)
  (run-segments java-pb-type-program f #f model (list (if boxed? "boxed" ""))))

(define (java-pb-explicit-literal model f)
  (run-segments java-pb-explicit-literal-program f #f model))

(define (java-pb-default model f)
  (run-segments java-pb-default-program f #f model))

;; Default for a boxed local (map key/value): float/double cannot
;; take the primitive "0" literal.
(define (java-pb-boxed-default model f)
  (run-segments java-pb-boxed-default-program f #f model))

(define (java-pb-varint-expr f v)
  (run-segments java-pb-varint-expr-program f #f #f (list v)))

(define (java-pb-varint-decode f v)
  (run-segments java-pb-varint-decode-program f #f #f (list v)))

(define (java-pb-encode-singular model f v indent support)
  (run-segments java-pb-encode-singular-program f #f model (list v indent)))

(define (java-pb-nonzero f v)
  (run-segments java-pb-nonzero-program f #f #f (list v)))



(define (java-pb-set-expr sib)
  (run-segments java-pb-set-expr-program sib #f))

;; Encode-side oneof clearing: suppress f when a later sibling is
;; set, so only the winning member is written.


(define (java-pb-encode-guard model f code)
  (define later (oneof-later-siblings model f))
  (if (null? later)
      code
      (format "        if (!(~a)) {\n~a        }\n"
              (string-join (map java-pb-set-expr later) " || ")
              (if (string-suffix? code "\n") code (string-append code "\n")))))

(define (java-pb-encode-field model f support)
  (run-segments java-pb-encode-field-program f #f model (list support)))

(define (java-pb-decode-singular model f target src indent)
  (run-segments java-pb-decode-singular-program f #f model (list target src indent)))

(define (java-pb-oneof-clearing model f)
  (run-segments java-pb-clearing-program f #f model))

(define (java-pb-decode-case model f support)
  (run-segments java-pb-decode-case-program f #f model (list support)))



(define (java-pb-map-helpers model entry support)
  (run-segments java-pb-map-helpers-program entry #f model (list support)))

;; One-line decode statement (no trailing newline handling needed
;; by switch cases in map helpers).
(define (java-pb-decode-singular-stmt model f target)
  (run-segments java-pb-map-decode-stmt-program f #f model (list target)))

(define (java-pb-message-class model msg support nested?)
  (run-segments java-pb-message-program msg #f model (list support)))

(define (java-pb-enum-values e)
  (string-append
   (string-join (map (lambda (v) (format "        ~a(~a)" (hash-ref v 'name) (hash-ref v 'number)))
                     (hash-ref e 'values)) ",\n")
   ";\n"))

(define (java-pb-enum-body e indent)
  (string-append
   (format "~apublic final int number;\n" indent)
   (format "~a~a(int number) { this.number = number; }\n" indent (hash-ref e 'name))
   (format "~apublic static ~a fromNumber(int number) {\n" indent (hash-ref e 'name))
   (format "~a    switch (number) {\n" indent)
   (apply string-append
          (map (lambda (v) (format "~a        case ~a: return ~a;\n" indent (hash-ref v 'number) (hash-ref v 'name)))
               (hash-ref e 'values)))
   (format "~a        default: return ~a;\n    }\n}\n" indent (hash-ref (car (hash-ref e 'values)) 'name))))

(define (java-pb-nested-enum model msg e)
  (run-segments java-pb-nested-enum-program e #f model))

(define (java-pb-top-enum model e pkg)
  (string-append
   "// @generated by protoc-gen-grpc-dc-java. DO NOT EDIT.\n"
   (if (string=? pkg "") "" (format "package ~a;\n\n" pkg))
   (format "public enum ~a {\n" (hash-ref e 'name))
   (java-pb-enum-values e)
   (java-pb-enum-body e "    ")
   "}\n"))

(define (java-pb-top-message model msg pkg support struct?)
  (define name (hash-ref msg 'name))
  (define fields (hash-ref msg 'fields))
  (string-append
   "// @generated by protoc-gen-grpc-dc-java. DO NOT EDIT.\n"
   (if (string=? pkg "") "" (format "package ~a;\n\n" pkg))
   (format "public final class ~a implements grpcdc.Marshaler, grpcdc.Unmarshaler {\n" name)
   (apply string-append
          (map (lambda (f)
                 (format "    public ~a ~a = ~a;\n"
                         (java-pb-type model f #f) (java-pb-field-name f) (java-pb-default model f)))
               fields))
   "    public byte[] unknownFields = new byte[0];\n"
   (format "    public ~a() {}\n" name)
   (if (null? fields)
       ""
       (string-append
        (format "    public ~a(~a) {\n" name
                (string-join (map (lambda (f) (format "~a ~a" (java-pb-type model f #f) (java-pb-field-name f))) fields) ", "))
        (apply string-append
               (map (lambda (f) (format "        this.~a = ~a;\n" (java-pb-field-name f) (java-pb-field-name f))) fields))
        "    }\n"))
   "\n    @Override\n    public byte[] marshalDc() {\n"
   (format "        ~a.Writer pbW = new ~a.Writer();\n" support support)
   (apply string-append (map (lambda (f) (java-pb-encode-guard model f (java-pb-encode-field model f support))) fields))
   "        pbW.raw(unknownFields);\n"
   "        return pbW.toBytes();\n    }\n\n"
   "    @Override\n    public void unmarshalDc(byte[] data) {\n"
   "        unknownFields = new byte[0];\n"
   (apply string-append
          (map (lambda (f) (format "        ~a = ~a;\n" (java-pb-field-name f) (java-pb-default model f))) fields))
   (format "        ~a.Reader pbR = new ~a.Reader(data);\n" support support)
   (format "        ~a.Field pbField;\n" support)
   "        while ((pbField = pbR.next()) != null) {\n            switch (pbField.number) {\n"
   (apply string-append (map (lambda (f) (java-pb-decode-case model f support)) fields))
   (format "                default -> { unknownFields = ~a.concatBytes(unknownFields, pbField.rawValue); }\n            }\n        }\n    }\n" support)
   (if struct?
       (let ([companion (string-append (jv-struct-flat-name model (hash-ref msg 'full-name)) "Struct")]
             [type-name (jv-struct-type-name model msg)])
         (string-append
          "\n    @Override\n    public byte[] marshalStruct() {\n"
          (format "        return ~a.marshal(this);\n    }\n\n" companion)
          "    @Override\n    public void unmarshalStruct(byte[] data) {\n"
          (format "        ~a _s = ~a.unmarshal(data);\n" type-name companion)
          (apply string-append
                 (map (lambda (f) (format "        this.~a = _s.~a;\n" (java-pb-field-name f) (java-pb-field-name f))) fields))
          "        this.unknownFields = _s.unknownFields;\n    }\n"))
       "")
   (apply string-append (map (lambda (n) (java-pb-message-class model n support #t)) (hash-ref msg 'nested)))
   (apply string-append (map (lambda (e) (java-pb-nested-enum model msg e)) (hash-ref msg 'enums)))
   "}\n"))

(define (emit-java-pb-files file-model params)
  (and (hash-has-key? file-model 'messages)
       (hash-has-key? file-model 'types)
       (emit-java-pb-files/inner file-model params)))

(define (emit-java-pb-files/inner file-model params)
  (define messages (hash-ref file-model 'messages))
  (define enums (hash-ref file-model 'enums))
  (and (or (pair? messages) (pair? enums))
       (let ()
         (define base (path->string (path-replace-extension
                                     (file-name-from-path (hash-ref file-model 'name)) "")))
         (define pkg (hash-ref file-model 'package))
         (define support (format "~aPb" (pascal (string->symbol base))))
         ;; Collect this file's map helpers into the support class.
         (define seen-maps (mutable-set))
         (define helpers '())
         (define (collect msg)
           (for ([f (in-list (hash-ref msg 'fields))])
             (when (= (hash-ref f 'type) 11)
               (define e (java-pb-resolve file-model (hash-ref f 'type-name)))
               (when (and (eq? (hash-ref e 'kind) 'map)
                          (not (set-member? seen-maps (hash-ref (hash-ref e 'msg) 'full-name))))
                 (set-add! seen-maps (hash-ref (hash-ref e 'msg) 'full-name))
                 (set! helpers (cons (java-pb-map-helpers file-model e support) helpers)))))
           (for ([n (in-list (hash-ref msg 'nested))]) (collect n)))
         (for ([m (in-list messages)]) (collect m))
         (define support-content
           (if (null? helpers)
               (java-pb-support-class base pkg)
               (string-replace (java-pb-support-class base pkg)
                               "    static final class Writer {"
                               (string-append (apply string-append (reverse helpers))
                                              "    static final class Writer {"))))
         (append
          (list (cons (string-append support ".java") support-content))
          (map (lambda (m) (cons (string-append (hash-ref m 'name) ".java")
                                 (java-pb-top-message file-model m pkg support
                                                      (equal? (hash-ref params 'struct_codec #f) "true"))))
               (filter (lambda (m) (not (hash-ref m 'map-entry))) messages))
          (map (lambda (e) (cons (string-append (hash-ref e 'name) ".java")
                                 (java-pb-top-enum file-model e pkg)))
               enums)
          (if (equal? (hash-ref params 'struct_codec #f) "true")
              (let ()
                (define comps '())
                (define (emit-comp msg)
                  (unless (hash-ref msg 'map-entry)
                    (set! comps
                          (cons (cons (string-append (jv-struct-flat-name file-model (hash-ref msg 'full-name)) "Struct.java")
                                      (string-append
                                       "// @generated by protoc-gen-grpc-dc-java. DO NOT EDIT.\n"
                                       (format "// source: ~a\n\n" (hash-ref file-model 'name))
                                       (if (string=? pkg "") "" (format "package ~a;\n\n" pkg))
                                       (jv-struct-message file-model msg)))
                                comps)))
                  (for ([n (in-list (hash-ref msg 'nested))]) (emit-comp n)))
                (for ([m (in-list messages)]) (emit-comp m))
                (reverse comps))
              '())))))

(define (java-pb-support-class base pkg)
  (string-append
   "// @generated by protoc-gen-grpc-dc-java. DO NOT EDIT.\n"
   (if (string=? pkg "") "" (format "package ~a;\n\n" pkg))
   (format "final class ~aPb {\n" (pascal (string->symbol base)))
   "    private " (format "~aPb" (pascal (string->symbol base))) "() {}\n\n"
   "    static final class Writer {\n"
   "        private final java.io.ByteArrayOutputStream out = new java.io.ByteArrayOutputStream();\n"
   "        void varint(long value) { long v = value; while ((v & ~0x7fL) != 0) { out.write(((int) (v & 0x7f)) | 0x80); v >>>= 7; } out.write((int) v); }\n"
   "        void tag(int field, int wire) { varint((field << 3) | wire); }\n"
   "        void bytesField(int field, byte[] payload) { tag(field, 2); varint(payload.length); out.write(payload, 0, payload.length); }\n"
   "        void stringField(int field, String value) { if (value == null || value.isEmpty()) return; bytesField(field, value.getBytes(java.nio.charset.StandardCharsets.UTF_8)); }\n"
   "        void fixed32(int value) { out.write(value & 0xff); out.write((value >>> 8) & 0xff); out.write((value >>> 16) & 0xff); out.write((value >>> 24) & 0xff); }\n"
   "        void fixed64(long value) { for (int i = 0; i < 8; i++) out.write((int) ((value >>> (8 * i)) & 0xff)); }\n"
   "        void fixedInt(int value) { fixed32(value); }\n"
   "        void fixedLong(long value) { fixed64(value); }\n"
   "        void fixedFloat(float value) { fixed32(Float.floatToIntBits(value)); }\n"
   "        void fixedDouble(double value) { fixed64(Double.doubleToLongBits(value)); }\n"
   "        void raw(byte[] payload) { out.write(payload, 0, payload.length); }\n"
   "        byte[] toBytes() { return out.toByteArray(); }\n"
   "    }\n\n"
   "    static byte[] concatBytes(byte[] a, byte[] b) { byte[] out = java.util.Arrays.copyOf(a, a.length + b.length); System.arraycopy(b, 0, out, a.length, b.length); return out; }\n\n"
   "    static final class Field {\n"
   "        final int number; final int wire; final long varintValue; final byte[] bytesValue; final long fixedValue; final byte[] rawValue;\n"
   "        Field(int number, int wire, long varintValue, byte[] bytesValue, long fixedValue, byte[] rawValue) { this.number = number; this.wire = wire; this.varintValue = varintValue; this.bytesValue = bytesValue; this.fixedValue = fixedValue; this.rawValue = rawValue; }\n"
   "    }\n\n"
   "    static final class Reader {\n"
   "        private final byte[] buf; private int pos;\n"
   "        Reader(byte[] buf) { this.buf = buf; }\n"
   "        boolean done() { return pos >= buf.length; }\n"
   "        long varint() { long result = 0; int shift = 0; while (true) { if (pos >= buf.length) throw new IllegalArgumentException(\"truncated varint\"); int b = buf[pos++] & 0xff; result |= (long) (b & 0x7f) << shift; if ((b & 0x80) == 0) return result; shift += 7; if (shift >= 64) throw new IllegalArgumentException(\"varint too long\"); } }\n"
   "        byte[] take(int n) { if (pos + n > buf.length) throw new IllegalArgumentException(\"truncated field\"); byte[] v = new byte[n]; System.arraycopy(buf, pos, v, 0, n); pos += n; return v; }\n"
   "        int fixed32() { byte[] b = take(4); return (b[0] & 0xff) | ((b[1] & 0xff) << 8) | ((b[2] & 0xff) << 16) | ((b[3] & 0xff) << 24); }\n"
   "        long fixed64() { byte[] b = take(8); long v = 0; for (int i = 0; i < 8; i++) v |= (long) (b[i] & 0xff) << (8 * i); return v; }\n"
   "        Field next() {\n"
   "            if (pos >= buf.length) return null;\n"
   "            int start = pos;\n"
   "            long tag = varint(); int number = (int) (tag >> 3); int wire = (int) (tag & 7);\n"
   "            switch (wire) {\n"
   "                case 0: { long v = varint(); return new Field(number, wire, v, null, 0, java.util.Arrays.copyOfRange(buf, start, pos)); }\n"
   "                case 2: { int n = (int) varint(); byte[] b = take(n); return new Field(number, wire, 0, b, 0, java.util.Arrays.copyOfRange(buf, start, pos)); }\n"
   "                case 1: { byte[] b = take(8); long v = 0; for (int i = 0; i < 8; i++) v |= (long) (b[i] & 0xff) << (8 * i); return new Field(number, wire, 0, b, v, java.util.Arrays.copyOfRange(buf, start, pos)); }\n"
   "                case 5: { byte[] b = take(4); int v = (b[0] & 0xff) | ((b[1] & 0xff) << 8) | ((b[2] & 0xff) << 16) | ((b[3] & 0xff) << 24); return new Field(number, wire, 0, b, v, java.util.Arrays.copyOfRange(buf, start, pos)); }\n"
   "                default: throw new IllegalArgumentException(\"bad wire type \" + wire);\n"
   "            }\n"
   "        }\n"
   "    }\n"
   "}\n"))

(define (emit-java-file file-model params)
  (define base (path->string (path-replace-extension
                              (file-name-from-path (hash-ref file-model 'name)) "")))
  (define class-name (string-append (pascal (string->symbol base)) "GrpcDc"))
  (define pkg (hash-ref file-model 'package))
  (define stub
    (cons (string-append class-name ".java")
          (string-append
           "// @generated by protoc-gen-grpc-dc-java. DO NOT EDIT.\n"
         (format "// source: ~a\n\n" (hash-ref file-model 'name))
         (if (string=? pkg "") "" (format "package ~a;\n\n" pkg))
         "import grpcdc.Channel;\n"
         "import grpcdc.Endpoint;\n"
         "import grpcdc.Server;\n"
         "import grpcdc.StatusException;\n"
         "import grpcdc.Wire;\n"
         "import java.util.ArrayList;\n"
         "import java.util.List;\n"
         "import java.util.Map;\n"
         "import java.util.concurrent.CompletableFuture;\n"
         "import java.util.concurrent.CompletionException;\n\n"
         (format "/** Generated gRPC-over-DataChannels stubs for ~a. */\n" (hash-ref file-model 'name))
         (format "public final class ~a {\n    private ~a() {}\n\n" class-name class-name)
         ;; trace=hooks: delegate the tracer registrar to grpcdc.Tracing.
         (if (equal? (hash-ref params 'trace #f) "hooks")
             (string-append
              "    // Tracing (trace=hooks@@TRACING_BETA@@): register an observer via setTracer.\n"
              "    public static void setTracer(grpcdc.Tracing.Tracer t) { grpcdc.Tracing.setTracer(t); }\n"
              "    public static void setTraceFilter(String patterns) { grpcdc.Tracing.setTraceFilter(patterns); }\n"
              (let ([methods (hash-ref params 'trace_methods #f)])
                (if methods
                    (format "    static { grpcdc.Tracing.setTraceFilter(~s); }\n" methods)
                    ""))
              "\n")
             "")
         (apply string-append
                (map java-service
                     (java-qualify-services pkg (hash-ref file-model 'services))))
         "}\n")))
  (define pb-files (emit-java-pb-files file-model params))
  (if pb-files (cons stub pb-files) stub))

;; ------------------------------------------------------------------
;; Struct codec (struct_codec=true): companion <Msg>Struct class
;; per top-level message with the packed layout from SPEC.md
;; (byte-identical to the Go/Rust struct codecs).
(define (jv-descriptor-hex bstr)
  (apply string-append
         (for/list ([b (in-bytes bstr)])
           (let ([h (format "~x" b)])
             (if (= (string-length h) 1) (string-append "0" h) h)))))

(define (jv-struct-fingerprint s)
  (for/fold ([h 2166136261]) ([c (in-string s)])
    (modulo (* (bitwise-xor h (char->integer c)) 16777619) 4294967296)))

(define (jv-struct-varint-type? t) (member t '(3 4 5 8 13 14 17 18)))
(define (jv-struct-fixed32-type? t) (member t '(2 7 15)))
(define (jv-struct-fixed64-type? t) (member t '(1 6 16)))

(define (jv-struct-slot-size f)
  (define t (hash-ref f 'type))
  (cond [(jv-struct-varint-type? t) 8]
        [(jv-struct-fixed32-type? t) 4]
        [(jv-struct-fixed64-type? t) 8]
        [else 8]))

(define (jv-struct-sorted-fields msg)
  (sort (hash-ref msg 'fields) < #:key (lambda (f) (hash-ref f 'number))))

(define (jv-struct-map-entry model f)
  (and (= (hash-ref f 'type) 11)
       (let ([e (java-pb-resolve model (hash-ref f 'type-name))])
         (and (eq? (hash-ref e 'kind) 'map) e))))

(define (jv-struct-map-key-field model f)
  (define em (hash-ref (jv-struct-map-entry model f) 'msg))
  (findf (lambda (x) (= (hash-ref x 'number) 1)) (hash-ref em 'fields)))
(define (jv-struct-map-val-field model f)
  (define em (hash-ref (jv-struct-map-entry model f) 'msg))
  (findf (lambda (x) (= (hash-ref x 'number) 2)) (hash-ref em 'fields)))

(define (jv-struct-type-name model msg)
  ;; Java class name for a message: nested types are Outer.Inner.
  (define full (hash-ref msg 'full-name))
  (define pkg (hash-ref model 'package))
  (define rel (if (and pkg (not (string=? pkg ""))
                       (string-prefix? full (string-append pkg ".")))
                  (substring full (add1 (string-length pkg)))
                  full))
  (string-join (string-split rel ".") "."))

(define (jv-struct-flat-name model full)
  (define pkg (hash-ref model 'package))
  (define rel (if (and pkg (not (string=? pkg ""))
                       (string-prefix? full (string-append pkg ".")))
                  (substring full (add1 (string-length pkg)))
                  full))
  (string-join (string-split rel ".") "_"))

(define (jv-struct-companion model f)
  (define e (java-pb-resolve model (hash-ref f 'type-name)))
  (string-append (jv-struct-flat-name model (hash-ref (hash-ref e 'msg) 'full-name)) "Struct"))

(define (jv-struct-present f jn)
  (define t (hash-ref f 'type))
  (cond [(= (hash-ref f 'label) 3) (format "!m.~a.isEmpty()" jn)]
        [(= t 11) (format "m.~a != null" jn)]
        [(= t 9) (format "!m.~a.isEmpty()" jn)]
        [(= t 12) (format "m.~a.length > 0" jn)]
        [(= t 8) (format "m.~a" jn)]
        [(= t 14) (format "m.~a.number != 0" jn)]
        [(member t '(2 1)) (format "m.~a != 0" jn)]
        [else (format "m.~a != 0" jn)]))

(define (jv-struct-scalar-encode f v)
  (define t (hash-ref f 'type))
  (cond [(jv-struct-fixed32-type? t)
         (if (= t 2)
             (format "put32(buf, off, Float.floatToIntBits(~a));" v)
             (format "put32(buf, off, ~a);" v))]
        [(jv-struct-fixed64-type? t)
         (if (= t 1)
             (format "put64(buf, off, Double.doubleToLongBits(~a));" v)
             (format "put64(buf, off, ~a);" v))]
        [(= t 8) (format "buf[off] = (byte) (~a ? 1 : 0);" v)]
        [(= t 14) (format "put64(buf, off, ~a.number);" v)]
        [else (format "put64(buf, off, ~a);" v)]))

(define (jv-struct-scalar-decode/off model f target offv)
  (define t (hash-ref f 'type))
  (cond [(jv-struct-fixed32-type? t)
         (if (= t 2)
             (format "~a = Float.intBitsToFloat(get32(data, off));" target)
             (format "~a = get32(data, off);" target))]
        [(jv-struct-fixed64-type? t)
         (if (= t 1)
             (format "~a = Double.longBitsToDouble(get64(data, off));" target)
             (format "~a = get64(data, off);" target))]
        [(= t 8) (format "~a = data[off] != 0;" target)]
        [(= t 14) (format "~a = ~a.fromNumber((int) get64(data, ~a));" target
                        (java-pb-type model f "") offv)]
        [(member t '(5 17)) (format "~a = (int) get64(data, ~a);" target offv)]
        [else (format "~a = get64(data, ~a);" target offv)]))
(define (jv-struct-scalar-decode model f target)
  (jv-struct-scalar-decode/off model f target "off"))

(define (jv-struct-value-size model f v)
  (define t (hash-ref f 'type))
  (cond [(= t 9) (format "~a.getBytes(java.nio.charset.StandardCharsets.UTF_8).length" v)]
        [(= t 12) (format "~a.length" v)]
        [(= t 11) (format "(~a == null ? 0 : ~a.size(~a))" v (jv-struct-companion model f) v)]
        [(jv-struct-fixed32-type? t) "4"]
        [else "8"]))

(define (jv-struct-message model msg)
  (define type-name (jv-struct-type-name model msg))
  (define simple (car (reverse (string-split type-name "."))))
  (define out (open-output-string))
  (fprintf out "public final class ~aStruct {\n" simple)
  (fprintf out "    public static final int FINGERPRINT = 0x~x;\n\n"
           (jv-struct-fingerprint (hash-ref msg 'full-name)))
  (fprintf out "    private static final byte[] DESCRIPTOR = java.util.HexFormat.of().parseHex(\"~a\");\n\n"
           (jv-descriptor-hex (hash-ref model 'descriptor-set #"")))
  (fprintf out "    private ~aStruct() {}\n\n" simple)
  (fprintf out "    public static int size(~a m) { return marshal(m).length; }\n\n" type-name)
  (fprintf out "    public static byte[] marshal(~a m) { return grpcdc.StructDc.encode(DESCRIPTOR, \"~a\", m.marshalDc()); }\n\n"
           type-name (hash-ref msg 'full-name))
  (fprintf out "    public static ~a unmarshal(byte[] data) {\n        ~a m = new ~a();\n        m.unmarshalDc(grpcdc.StructDc.decode(DESCRIPTOR, \"~a\", data));\n        return m;\n    }\n}\n"
           type-name type-name type-name (hash-ref msg 'full-name))
  (get-output-string out))

(define (jv-struct-marshal-field model f off)
  (define jn (java-pb-field-name f))
  (define t (hash-ref f 'type))
  (define out (open-output-string))
  (define mv (format "m.~a" jn))
  (cond [(jv-struct-map-entry model f)
         (define kf (jv-struct-map-key-field model f))
         (define vf (jv-struct-map-val-field model f))
         (fprintf out "        if (!~a.isEmpty()) {\n            put32(buf, ~a, vp); put32(buf, ~a, ~a.size());\n" mv off (+ off 4) mv)
         (fprintf out "            java.util.List<~a> keys = new java.util.ArrayList<>(~a.keySet());\n            java.util.Collections.sort(keys);\n"
                  (java-pb-type model kf "boxed") mv)
         (fprintf out "            for (~a k : keys) {\n                ~a v = ~a.get(k);\n                put32(buf, vp, ~a); put32(buf, vp + 4, ~a); vp += 8;\n"
                  (java-pb-type model kf "boxed") (java-pb-type model vf "boxed") mv
                  (jv-struct-value-size model kf "k") (jv-struct-value-size model vf "v"))
         (display (jv-struct-value-write model kf "k") out)
         (display (jv-struct-value-write model vf "v") out)
         (fprintf out "            }\n        }\n")]
        [(= (hash-ref f 'label) 3)
         (cond [(member t '(9 12))
                (fprintf out "        if (!~a.isEmpty()) {\n            put32(buf, ~a, vp); put32(buf, ~a, ~a.size());\n            int doff = vp + 8 * ~a.size();\n            for (~a e : ~a) { put32(buf, vp, doff); put32(buf, vp + 4, ~a); doff += ~a; vp += 8; }\n            for (~a e : ~a) { ~a }\n        }\n"
                         mv off (+ off 4) mv mv
                         (java-pb-type model (hash-set f 'label 1) "boxed") mv
                         (if (= t 9) "e.getBytes(java.nio.charset.StandardCharsets.UTF_8).length" "e.length")
                         (if (= t 9) "e.getBytes(java.nio.charset.StandardCharsets.UTF_8).length" "e.length")
                         (java-pb-type model (hash-set f 'label 1) "boxed") mv
                         (if (= t 9) "System.arraycopy(e.getBytes(java.nio.charset.StandardCharsets.UTF_8), 0, buf, vp, e.getBytes(java.nio.charset.StandardCharsets.UTF_8).length); vp += e.getBytes(java.nio.charset.StandardCharsets.UTF_8).length;"
                             "System.arraycopy(e, 0, buf, vp, e.length); vp += e.length;"))]
               [(= t 11)
                (fprintf out "        if (!~a.isEmpty()) {\n            put32(buf, ~a, vp); put32(buf, ~a, ~a.size());\n            int doff = vp + 8 * ~a.size();\n            for (~a e : ~a) { int es = ~a.size(e); put32(buf, vp, doff); put32(buf, vp + 4, es); doff += es; vp += 8; }\n            for (~a e : ~a) { byte[] nb = ~a.marshal(e); System.arraycopy(nb, 0, buf, vp, nb.length); vp += nb.length; }\n        }\n"
                         mv off (+ off 4) mv mv
                         (java-pb-type model (hash-set f 'label 1) "") mv (jv-struct-companion model f)
                         (java-pb-type model (hash-set f 'label 1) "") mv (jv-struct-companion model f))]
               [else
                (fprintf out "        if (!~a.isEmpty()) {\n            put32(buf, ~a, vp); put32(buf, ~a, ~a.size());\n            for (~a e : ~a) { int off = vp; ~a vp += ~a; }\n        }\n"
                         mv off (+ off 4) mv
                         (java-pb-type model (hash-set f 'label 1) "boxed") mv
                         (jv-struct-scalar-encode f "e")
                         (if (jv-struct-fixed32-type? t) 4 8))])]
        [(= t 11)
         (fprintf out "        if (~a != null) {\n            put32(buf, ~a, vp); put32(buf, ~a, ~a.size(~a));\n            byte[] nb = ~a.marshal(~a); System.arraycopy(nb, 0, buf, vp, nb.length); vp += nb.length;\n        }\n"
                  mv off (+ off 4) (jv-struct-companion model f) mv (jv-struct-companion model f) mv)]
        [(member t '(9 12))
         (fprintf out "        if (~a) {\n            put32(buf, ~a, vp); put32(buf, ~a, ~a);\n            ~a\n        }\n"
                  (if (= t 9) (format "!~a.isEmpty()" mv) (format "~a.length > 0" mv))
                  off (+ off 4)
                  (if (= t 9) (format "~a.getBytes(java.nio.charset.StandardCharsets.UTF_8).length" mv) (format "~a.length" mv))
                  (if (= t 9)
                      (format "byte[] sb = ~a.getBytes(java.nio.charset.StandardCharsets.UTF_8); System.arraycopy(sb, 0, buf, vp, sb.length); vp += sb.length;" mv)
                      (format "System.arraycopy(~a, 0, buf, vp, ~a.length); vp += ~a.length;" mv mv mv)))]
        [else
         (fprintf out "        { int off = ~a; ~a }\n" off (jv-struct-scalar-encode f mv))])
  (get-output-string out))

(define (jv-struct-value-write model f v)
  (define t (hash-ref f 'type))
  (define out (open-output-string))
  (cond [(= t 9)
         (fprintf out "                byte[] sb = ~a.getBytes(java.nio.charset.StandardCharsets.UTF_8); System.arraycopy(sb, 0, buf, vp, sb.length); vp += sb.length;\n" v)]
        [(= t 12)
         (fprintf out "                System.arraycopy(~a, 0, buf, vp, ~a.length); vp += ~a.length;\n" v v v)]
        [(= t 11)
         (fprintf out "                if (~a != null) { byte[] nb = ~a.marshal(~a); System.arraycopy(nb, 0, buf, vp, nb.length); vp += nb.length; }\n" v (jv-struct-companion model f) v)]
        [else
         (fprintf out "                { int off = vp; ~a }\n                vp += ~a;\n"
                  (jv-struct-scalar-encode f v) (if (jv-struct-fixed32-type? t) 4 8))])
  (get-output-string out))

(define (jv-struct-decode-field model f foff)
  (define jn (java-pb-field-name f))
  (define t (hash-ref f 'type))
  (define out (open-output-string))
  (define mv (format "m.~a" jn))
  (cond [(jv-struct-map-entry model f)
         (define kf (jv-struct-map-key-field model f))
         (define vf (jv-struct-map-val-field model f))
         (define kt (java-pb-type model kf "boxed"))
         (define vt (java-pb-type model vf "boxed"))
         (fprintf out "            int off = get32(data, ~a); int n = get32(data, ~a);\n" foff (+ foff 4))
         (fprintf out "            int p = off;\n            for (int i = 0; i < n; i++) {\n")
         (fprintf out "                check(data, p, 8);\n                int kl = get32(data, p); int vl = get32(data, p + 4); p += 8;\n                check(data, p, kl + vl);\n")
         (fprintf out "                ~a k; { int io = p; ~a }\n" kt (jv-struct-value-read/off model kf "k" "kl" "io"))
         (fprintf out "                ~a v; { int io = p + kl; ~a }\n" vt (jv-struct-value-read/off model vf "v" "vl" "io"))
         (fprintf out "                ~a.put(k, v);\n                p += kl + vl;\n            }\n            if (p > vend) { vend = p; }\n" mv)]
        [(= (hash-ref f 'label) 3)
         (fprintf out "            int off = get32(data, ~a); int n = get32(data, ~a);\n" foff (+ foff 4))
         (cond [(member t '(9 12))
                (fprintf out "            for (int i = 0; i < n; i++) {\n                int eo = get32(data, off + 8 * i); int el = get32(data, off + 8 * i + 4);\n                check(data, eo, el);\n                ~a.add(~a);\n                if (eo + el > vend) { vend = eo + el; }\n            }\n"
                         mv (if (= t 9) "new String(data, eo, el, java.nio.charset.StandardCharsets.UTF_8)" "java.util.Arrays.copyOfRange(data, eo, eo + el)"))]
               [(= t 11)
                (fprintf out "            for (int i = 0; i < n; i++) {\n                int eo = get32(data, off + 8 * i); int el = get32(data, off + 8 * i + 4);\n                if (el > 0) {\n                    check(data, eo, el);\n                    ~a.add(~a.unmarshal(java.util.Arrays.copyOfRange(data, eo, eo + el)));\n                    if (eo + el > vend) { vend = eo + el; }\n                } else { ~a.add(null); }\n            }\n"
                         mv (jv-struct-companion model f) mv)]
               [else
                (define esz (if (jv-struct-fixed32-type? t) 4 8))
                (fprintf out "            check(data, off, n * ~a);\n            for (int i = 0; i < n; i++) {\n                int eo = off + i * ~a;\n                ~a.add(~a);\n            }\n            if (off + n * ~a > vend) { vend = off + n * ~a; }\n"
                         esz esz mv (jv-struct-scalar-value/off model f "eo") esz esz)])]
        [(= t 11)
         (fprintf out "            int off = get32(data, ~a); int el = get32(data, ~a);\n" foff (+ foff 4))
         (fprintf out "            check(data, off, el);\n            ~a = ~a.unmarshal(java.util.Arrays.copyOfRange(data, off, off + el));\n            if (off + el > vend) { vend = off + el; }\n" mv (jv-struct-companion model f))]
        [(member t '(9 12))
         (fprintf out "            int off = get32(data, ~a); int el = get32(data, ~a);\n" foff (+ foff 4))
         (fprintf out "            check(data, off, el);\n")
         (if (= t 9)
             (fprintf out "            ~a = new String(data, off, el, java.nio.charset.StandardCharsets.UTF_8);\n" mv)
             (fprintf out "            ~a = java.util.Arrays.copyOfRange(data, off, off + el);\n" mv))
         (fprintf out "            if (off + el > vend) { vend = off + el; }\n")]
        [else
         (fprintf out "            int off = ~a;\n            ~a\n" foff
                  (jv-struct-scalar-decode model f mv))])
  (get-output-string out))

(define (jv-struct-scalar-value/off model f offv)
  ;; A Java expression reading the scalar at data[off:] as a
  ;; boxed value (for repeated-field adds).
  (define t (hash-ref f 'type))
  (cond [(jv-struct-fixed32-type? t)
         (if (= t 2) (format "Float.intBitsToFloat(get32(data, ~a))" offv) (format "get32(data, ~a)" offv))]
        [(jv-struct-fixed64-type? t)
         (if (= t 1) (format "Double.longBitsToDouble(get64(data, ~a))" offv) (format "get64(data, ~a)" offv))]
        [(= t 8) (format "data[~a] != 0" offv)]
        [(= t 14) (format "~a.fromNumber((int) get64(data, ~a))" (java-pb-type model f "") offv)]
        [(member t '(5 17)) (format "(int) get64(data, ~a)" offv)]
        [else (format "get64(data, ~a)" offv)]))

(define (jv-struct-scalar-value model f)
  (jv-struct-scalar-value/off model f "off"))

(define (jv-struct-value-read model f target lenvar)
  (jv-struct-value-read/off model f target lenvar "off"))

(define (jv-struct-value-read/off model f target lenvar offv)
  (define t (hash-ref f 'type))
  (cond [(= t 9) (format "~a = new String(data, ~a, ~a, java.nio.charset.StandardCharsets.UTF_8);" target offv lenvar)]
        [(= t 12) (format "~a = java.util.Arrays.copyOfRange(data, ~a, ~a + ~a);" target offv offv lenvar)]
        [(= t 11) (format "if (~a > 0) { ~a = ~a.unmarshal(java.util.Arrays.copyOfRange(data, ~a, ~a + ~a)); } else { ~a = new ~a(); }" lenvar target (jv-struct-companion model f) offv offv lenvar target (java-pb-type model f ""))]
        [else (jv-struct-scalar-decode/off model f target offv)]))
