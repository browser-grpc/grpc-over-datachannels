#lang racket

;;; template-csharp.rkt — emitter body spliced into
;;; protoc-gen-grpc-dc-csharp.
;;;
;;; Generated code is one static class <Base>GrpcDc in the proto
;;; package's PascalCase namespace, beside hand-written message types
;;; implementing Grpcdc.IMarshaler / Grpcdc.IUnmarshaler. Method names
;;; keep the proto spelling, mirroring the Go/Java stubs.

(require "spec.rkt" "desc.rkt" "segments.rkt")
(provide emit-csharp-file)

(define current-service (make-parameter ""))

(define (pascal sym) ; echo_service -> EchoService ; echo -> Echo
  (apply string-append
         (for/list ([part (in-list (string-split (symbol->string sym) "[_.-]"))])
           (if (string=? part "")
               ""
               (string-append (string (char-upcase (string-ref part 0)))
                              (substring part 1))))))





(define (csharp-client-method m)
  (run-segments cs-client-method-program m (current-service) #f (list "        ")))

(define (csharp-client-stream-class m)
  (run-segments cs-client-stream-class-program m (current-service)))



(define (csharp-server-iface-method m)
  (run-segments cs-server-iface-method-program m (current-service) #f (list "        ")))

(define (csharp-server-stream-ifaces m)
  (run-segments cs-server-stream-ifaces-program m (current-service)))

(define (csharp-register-method m)
  (run-segments cs-register-method-program m (current-service)))

(define (csharp-stream-impls m)
  (run-segments cs-stream-impls-program m (current-service)))


(define (csharp-client-async-method m)
  (run-segments cs-client-async-method-program m (current-service)))

(define (csharp-server-async-iface-method m)
  (run-segments cs-server-async-iface-method-program m (current-service)))

(define (csharp-server-async-adapter-method m)
  (run-segments cs-server-async-adapter-method-program m (current-service)))

(define (csharp-service svc)
  (run-segments cs-service-program svc (hash-ref svc 'name)))

;; ---------------------------------------------------------------------------
;; C# message types: one public class per top-level message and
;; one enum per top-level enum, plus an internal <Base>Pb wire
;; support class per proto file. Dependency-free (BCL only),
;; implementing Grpcdc.IMarshaler/IUnmarshaler. Mirrors the Java
;; emitter on the shared desc.rkt model.
;; ---------------------------------------------------------------------------



;; Generated field name: PascalCase, with a trailing underscore
;; when it would collide with a nested message/enum type of the
;; same message (C# forbids a field and a nested type sharing a
;; name, e.g. field `middle` next to nested class `Middle`).


;; Stub type reference for a method input/output: the simple class
;; name when the message lives in the stub file's own package,
;; namespace-qualified otherwise (C# cannot resolve a simple name
;; across namespaces). Generated message classes keep the proto
;; nesting under their file's namespace.
(define (cs-qualify-type pkg simple full)
  (cond [(or (not full) (string=? pkg "")
             (string-prefix? full (string-append pkg ".")))
         simple]
        [else (string-append (string (char-upcase (string-ref full 0)))
                             (substring full 1))]))

(define (cs-qualify-services pkg services)
  (for/list ([svc (in-list services)])
    (hash-set svc 'methods
              (for/list ([m (in-list (hash-ref svc 'methods))])
                (hash-set* m
                           'input (cs-qualify-type pkg (hash-ref m 'input)
                                                   (hash-ref m 'input-full #f))
                           'output (cs-qualify-type pkg (hash-ref m 'output)
                                                    (hash-ref m 'output-full #f)))))))

(define cs-pb-varint-types varint-scalar-types)
(define cs-pb-fixed (fixed-scalar-table 'csharp))

(define (cs-pb-resolve model type-name)
  (hash-ref (hash-ref model 'types) type-name
            (lambda () (error 'emit-csharp-pb-file "unresolved type ~a" type-name))))

(define (cs-pb-ns pkg)
  (if (string=? pkg "") "Proto" (pascal (string->symbol pkg))))







(define (cs-pb-type model f)
  (run-segments cs-pb-type-program f #f model))

(define (cs-pb-explicit-literal model f)
  (run-segments cs-pb-explicit-literal-program f #f model))

(define (cs-pb-default model f)
  (run-segments cs-pb-default-program f #f model))

(define (cs-pb-varint-expr f v)
  (run-segments cs-pb-varint-expr-program f #f #f (list v)))

(define (cs-pb-varint-decode f v)
  (run-segments cs-pb-varint-decode-program f #f #f (list v)))

(define (cs-pb-nonzero f v)
  (run-segments cs-pb-nonzero-program f #f #f (list v)))

(define (cs-pb-fixed-bits f v)
  (run-segments cs-pb-fixed-bits-program f #f #f (list v)))

(define (cs-pb-encode-singular model f v indent)
  (run-segments cs-pb-encode-singular-program f #f model (list v indent)))

(define (cs-pb-set-expr model sib)
  (run-segments cs-pb-set-expr-program sib #f model))

;; Encode-side oneof clearing: suppress f when a later sibling is
;; set, so only the winning member is written.


(define (cs-pb-encode-field model f support)
  (run-segments cs-pb-encode-field-program f #f model (list support)))

(define (cs-pb-decode-singular model f target src indent)
  (run-segments cs-pb-decode-singular-program f #f model (list target src indent)))

(define (cs-pb-oneof-clearing model f)
  (run-segments cs-pb-clearing-program f #f model))

(define (cs-pb-decode-case model f support)
  (run-segments cs-pb-decode-case-program f #f model (list support)))



(define (cs-pb-map-helpers model entry support)
  (run-segments cs-pb-map-helpers-program entry #f model (list support)))

(define (cs-pb-support-class base pkg)
  (string-append
   "// @generated by protoc-gen-grpc-dc-csharp. DO NOT EDIT.\n"
   "using System;\n\n"
   (format "namespace ~a;\n\n" (cs-pb-ns pkg))
   (format "internal static class ~aPb {\n" (pascal (string->symbol base)))
   "    internal sealed class Writer {\n"
   "        private readonly System.IO.MemoryStream _out = new();\n"
   "        public void Varint(long value) { ulong v = unchecked((ulong) value); while ((v & ~0x7fUL) != 0) { _out.WriteByte((byte) ((v & 0x7f) | 0x80)); v >>= 7; } _out.WriteByte((byte) v); }\n"
   "        public void Tag(int field, int wire) { Varint((field << 3) | wire); }\n"
   "        public void BytesField(int field, byte[] payload) { Tag(field, 2); Varint(payload.Length); _out.Write(payload, 0, payload.Length); }\n"
   "        public void StringField(int field, string value) { if (string.IsNullOrEmpty(value)) return; BytesField(field, System.Text.Encoding.UTF8.GetBytes(value)); }\n"
   "        public void Raw(byte[] payload) { _out.Write(payload, 0, payload.Length); }\n"
   "        public void FixedInt(int value) { _out.WriteByte((byte) value); _out.WriteByte((byte) (value >> 8)); _out.WriteByte((byte) (value >> 16)); _out.WriteByte((byte) (value >> 24)); }\n"
   "        public void FixedLong(long value) { for (int i = 0; i < 8; i++) _out.WriteByte((byte) (value >> (8 * i))); }\n"
   "        public void FixedFloat(float value) { FixedInt(BitConverter.ToInt32(BitConverter.GetBytes(value), 0)); }\n"
   "        public void FixedDouble(double value) { FixedLong(BitConverter.DoubleToInt64Bits(value)); }\n"
   "        public byte[] ToBytes() => _out.ToArray();\n"
   "    }\n\n"
   "    internal static byte[] ConcatBytes(byte[] a, byte[] b) { var o = new byte[a.Length + b.Length]; Array.Copy(a, o, a.Length); Array.Copy(b, 0, o, a.Length, b.Length); return o; }\n\n"
   "    internal sealed class Field {\n"
   "        public int Number { get; } public int Wire { get; } public long VarintValue { get; } public byte[] BytesValue { get; } public long FixedValue { get; } public byte[] RawValue { get; }\n"
   "        internal Field(int number, int wire, long varintValue, byte[] bytesValue, long fixedValue, byte[] rawValue) { Number = number; Wire = wire; VarintValue = varintValue; BytesValue = bytesValue; FixedValue = fixedValue; RawValue = rawValue; }\n"
   "    }\n\n"
   "    internal sealed class Reader {\n"
   "        private readonly byte[] _buf; private int _pos;\n"
   "        internal Reader(byte[] buf) { _buf = buf; }\n"
   "        public bool Done => _pos >= _buf.Length;\n"
   "        public long Varint() { long result = 0; int shift = 0; while (true) { if (_pos >= _buf.Length) throw new ArgumentException(\"truncated varint\"); int b = _buf[_pos++]; result |= (long) (b & 0x7f) << shift; if ((b & 0x80) == 0) return result; shift += 7; if (shift >= 64) throw new ArgumentException(\"varint too long\"); } }\n"
   "        public byte[] Take(int n) { if (_pos + n > _buf.Length) throw new ArgumentException(\"truncated field\"); var v = new byte[n]; Array.Copy(_buf, _pos, v, 0, n); _pos += n; return v; }\n"
   "        public byte[] TakeFrom(int start) { var v = new byte[_pos - start]; Array.Copy(_buf, start, v, 0, v.Length); return v; }\n"
   "        public int Fixed32() { var b = Take(4); return b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24); }\n"
   "        public long Fixed64() { var b = Take(8); long v = 0; for (int i = 0; i < 8; i++) v |= (long) b[i] << (8 * i); return v; }\n"
   "        public Field Next() {\n"
   "            if (_pos >= _buf.Length) return null;\n"
   "            int start = _pos;\n"
   "            long tag = Varint(); int number = (int) (tag >> 3); int wire = (int) (tag & 7);\n"
   "            switch (wire) {\n"
   "                case 0: { long v = Varint(); return new Field(number, wire, v, null, 0, TakeFrom(start)); }\n"
   "                case 2: { int n = (int) Varint(); var b = Take(n); return new Field(number, wire, 0, b, 0, TakeFrom(start)); }\n"
   "                case 1: { var b = Take(8); long v = 0; for (int i = 0; i < 8; i++) v |= (long) b[i] << (8 * i); return new Field(number, wire, 0, b, v, TakeFrom(start)); }\n"
   "                case 5: { var b = Take(4); int v = b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24); return new Field(number, wire, 0, b, v, TakeFrom(start)); }\n"
   "                default: throw new ArgumentException(\"bad wire type \" + wire);\n"
   "            }\n"
   "        }\n"
   "    }\n"
   "}\n"))

(define (cs-pb-message-class model msg support indent decl)
  (run-segments cs-pb-message-program msg #f model (list support indent decl)))

(define (cs-pb-nested-enum e indent)
  (run-segments cs-pb-nested-enum-program e #f #f (list indent)))

(define (cs-pb-top-enum model e pkg)
  (string-append
   "// @generated by protoc-gen-grpc-dc-csharp. DO NOT EDIT.\n"
   (format "namespace ~a;\n\n" (cs-pb-ns pkg))
   (format "public enum ~a {\n" (hash-ref e 'name))
   (string-join (map (lambda (v) (format "    ~a = ~a" (hash-ref v 'name) (hash-ref v 'number)))
                     (hash-ref e 'values)) ",\n")
   "\n}\n"))

(define (emit-csharp-pb-files file-model)
  (and (hash-has-key? file-model 'messages)
       (hash-has-key? file-model 'types)
       (emit-csharp-pb-files/inner file-model)))

(define (emit-csharp-pb-files/inner file-model)
  (define messages (hash-ref file-model 'messages))
  (define enums (hash-ref file-model 'enums))
  (and (or (pair? messages) (pair? enums))
       (let ()
         (define base (path->string (path-replace-extension
                                     (file-name-from-path (hash-ref file-model 'name)) "")))
         (define pkg (hash-ref file-model 'package))
         (define support (format "~aPb" (pascal (string->symbol base))))
         (define seen-maps (mutable-set))
         (define helpers '())
         (define (collect msg)
           (for ([f (in-list (hash-ref msg 'fields))])
             (when (= (hash-ref f 'type) 11)
               (define e (cs-pb-resolve file-model (hash-ref f 'type-name)))
               (when (and (eq? (hash-ref e 'kind) 'map)
                          (not (set-member? seen-maps (hash-ref (hash-ref e 'msg) 'full-name))))
                 (set-add! seen-maps (hash-ref (hash-ref e 'msg) 'full-name))
                 (set! helpers (cons (cs-pb-map-helpers file-model e support) helpers)))))
           (for ([n (in-list (hash-ref msg 'nested))]) (collect n)))
         (for ([m (in-list messages)]) (collect m))
         (define support-content
           (string-append
            "// @generated by protoc-gen-grpc-dc-csharp. DO NOT EDIT.\n"
            "using System;\nusing Grpcdc;\n\n"
            (format "namespace ~a;\n\n" (cs-pb-ns pkg))))
         (define support-full
           (let ([sc (cs-pb-support-class base pkg)])
             (if (null? helpers)
                 sc
                 (string-replace sc "    internal sealed class Writer {"
                                 (string-append (apply string-append (reverse helpers))
                                                "    internal sealed class Writer {")))))
         (append
          (list (cons (string-append support ".cs") support-full))
          (map (lambda (m)
                 (cons (string-append (hash-ref m 'name) ".cs")
                       (string-append
                        "// @generated by protoc-gen-grpc-dc-csharp. DO NOT EDIT.\n"
                        "using System;\nusing Grpcdc;\n\n"
                        (format "namespace ~a;\n\n" (cs-pb-ns pkg))
                        (cs-pb-message-class file-model m support "" "public sealed"))))
               (filter (lambda (m) (not (hash-ref m 'map-entry))) messages))
          (map (lambda (e) (cons (string-append (hash-ref e 'name) ".cs")
                                 (cs-pb-top-enum file-model e pkg)))
               enums)))))

(define (emit-csharp-file file-model params)
  (define base (path->string (path-replace-extension
                              (file-name-from-path (hash-ref file-model 'name)) "")))
  (define class-name (string-append (pascal (string->symbol base)) "GrpcDc"))
  (define pkg (hash-ref file-model 'package))
  (define ns (if (string=? pkg "") "Proto" (pascal (string->symbol pkg))))
  (define stub
    (cons (string-append class-name ".cs")
          (string-append
           "// @generated by protoc-gen-grpc-dc-csharp. DO NOT EDIT.\n"
         (format "// source: ~a\n\n" (hash-ref file-model 'name))
         "using System;\n"
         "using System.Collections.Generic;\n"
         "using System.Runtime.CompilerServices;\n"
         "using System.Threading;\n"
         "using System.Threading.Tasks;\n"
         "using Grpcdc;\n\n"
         (format "namespace ~a;\n\n" ns)
         (format "/// <summary>Generated gRPC-over-DataChannels stubs for ~a.</summary>\n" (hash-ref file-model 'name))
         (format "public static class ~a\n{\n" class-name)
         ;; trace=hooks: delegate the tracer registrar to Grpcdc.Tracing.
         (if (equal? (hash-ref params 'trace #f) "hooks")
             (string-append
              "    // Tracing (trace=hooks@@TRACING_BETA@@): register an observer via SetTracer.\n"
              "    public static void SetTracer(ITracer tracer) => Tracing.SetTracer(tracer);\n"
              "    public static void SetTraceFilter(string patterns) => Tracing.SetTraceFilter(patterns);\n"
              (let ([methods (hash-ref params 'trace_methods #f)])
                (if methods
                    (format "    static ~a() { Tracing.SetTraceFilter(~s); }\n" class-name methods)
                    ""))
              "\n")
             "")
         (apply string-append
                (map csharp-service
                     (cs-qualify-services pkg (hash-ref file-model 'services))))
         "}\n")))
  (define pb-files (emit-csharp-pb-files file-model))
  (if pb-files (cons stub pb-files) stub))
