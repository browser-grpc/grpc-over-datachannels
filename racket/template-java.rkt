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

(define (java-pb-top-message model msg pkg support)
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
   (format "        ~a.Writer w = new ~a.Writer();\n" support support)
   (apply string-append (map (lambda (f) (java-pb-encode-guard model f (java-pb-encode-field model f support))) fields))
   "        w.raw(unknownFields);\n"
   "        return w.toBytes();\n    }\n\n"
   "    @Override\n    public void unmarshalDc(byte[] data) {\n"
   "        unknownFields = new byte[0];\n"
   (apply string-append
          (map (lambda (f) (format "        ~a = ~a;\n" (java-pb-field-name f) (java-pb-default model f))) fields))
   (format "        ~a.Reader r = new ~a.Reader(data);\n" support support)
   (format "        ~a.Field field;\n" support)
   "        while ((field = r.next()) != null) {\n            switch (field.number) {\n"
   (apply string-append (map (lambda (f) (java-pb-decode-case model f support)) fields))
   (format "                default -> { unknownFields = ~a.concatBytes(unknownFields, field.rawValue); }\n            }\n        }\n    }\n" support)
   (apply string-append (map (lambda (n) (java-pb-message-class model n support #t)) (hash-ref msg 'nested)))
   (apply string-append (map (lambda (e) (java-pb-nested-enum model msg e)) (hash-ref msg 'enums)))
   "}\n"))

(define (emit-java-pb-files file-model)
  (and (hash-has-key? file-model 'messages)
       (hash-has-key? file-model 'types)
       (emit-java-pb-files/inner file-model)))

(define (emit-java-pb-files/inner file-model)
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
                                 (java-pb-top-message file-model m pkg support)))
               (filter (lambda (m) (not (hash-ref m 'map-entry))) messages))
          (map (lambda (e) (cons (string-append (hash-ref e 'name) ".java")
                                 (java-pb-top-enum file-model e pkg)))
               enums)))))

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
              "    // Tracing (trace=hooks): register an observer via setTracer.\n"
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
  (define pb-files (emit-java-pb-files file-model))
  (if pb-files (cons stub pb-files) stub))
