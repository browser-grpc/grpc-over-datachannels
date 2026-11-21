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
  (define pb-files (parameterize ([seg-struct-codec (equal? (hash-ref params 'struct_codec #f) "true")])
                     (emit-csharp-pb-files file-model)))
  (define struct-files (emit-csharp-struct-files file-model params))
  (if (null? struct-files)
      (if pb-files (cons stub pb-files) stub)
      (append (cons stub pb-files) struct-files)))

;; ------------------------------------------------------------------
;; Struct codec (struct_codec=true): <Msg>Struct static class per
;; message with the packed layout from SPEC.md (byte-identical to
;; the other struct codecs; verified by conformance/struct).
(define (cs-struct-fingerprint s)
  (for/fold ([h 2166136261]) ([c (in-string s)])
    (modulo (* (bitwise-xor h (char->integer c)) 16777619) 4294967296)))

(define (cs-struct-fixed32-type? t) (member t '(2 7 15)))
(define (cs-struct-fixed64-type? t) (member t '(1 6 16)))

(define (cs-struct-slot-size f)
  (if (cs-struct-fixed32-type? (hash-ref f 'type)) 4 8))

(define (cs-struct-sorted-fields msg)
  (sort (hash-ref msg 'fields) < #:key (lambda (f) (hash-ref f 'number))))

(define (cs-struct-map-entry model f)
  (and (= (hash-ref f 'type) 11)
       (let ([e (cs-pb-resolve model (hash-ref f 'type-name))])
         (and (eq? (hash-ref e 'kind) 'map) e))))

(define (cs-struct-map-key-field model f)
  (define em (hash-ref (cs-struct-map-entry model f) 'msg))
  (findf (lambda (x) (= (hash-ref x 'number) 1)) (hash-ref em 'fields)))
(define (cs-struct-map-val-field model f)
  (define em (hash-ref (cs-struct-map-entry model f) 'msg))
  (findf (lambda (x) (= (hash-ref x 'number) 2)) (hash-ref em 'fields)))

(define (cs-struct-type-name model msg)
  (define full (hash-ref msg 'full-name))
  (define pkg (hash-ref model 'package))
  (define rel (if (and pkg (not (string=? pkg ""))
                       (string-prefix? full (string-append pkg ".")))
                  (substring full (add1 (string-length pkg)))
                  full))
  (string-join (string-split rel ".") "_"))

(define (cs-struct-class-name model f)
  (define e (cs-pb-resolve model (hash-ref f 'type-name)))
  (cs-struct-type-name model (hash-ref e 'msg)))

(define (cs-struct-companion model f)
  (string-append (cs-struct-class-name model f) "Struct"))

(define (cs-struct-bridge-name model)
  (string-append (pascal (string->symbol
                          (path->string (path-replace-extension
                                         (file-name-from-path (hash-ref model 'name)) ""))))
                 "StructDc"))

(define (cs-struct-field-name f)
  (seg-cs-pascal-struct (hash-ref f 'name)))

(define (seg-cs-pascal-struct s)
  (string-join
   (map (lambda (part)
          (if (string=? part "") "" (string-append (string (char-upcase (string-ref part 0))) (substring part 1))))
        (string-split s "_")) ""))

(define (cs-struct-present f cn)
  (define t (hash-ref f 'type))
  (cond [(cs-struct-map-entry (current-struct-model) f) (format "m.~a.Count > 0" cn)]
        [(= (hash-ref f 'label) 3) (format "m.~a.Count > 0" cn)]
        [(= t 11) (format "m.~a != null" cn)]
        [(= t 9) (format "m.~a.Length > 0" cn)]
        [(= t 12) (format "m.~a.Length > 0" cn)]
        [(= t 8) (format "m.~a" cn)]
        [(= t 14) (format "(int)m.~a != 0" cn)]
        [else (format "m.~a != 0" cn)]))

(define current-struct-model (make-parameter #f))

(define (cs-struct-scalar-encode f v)
  (define t (hash-ref f 'type))
  (cond [(cs-struct-fixed32-type? t)
         (if (= t 2)
             (format "Put32(buf, off, BitConverter.ToInt32(BitConverter.GetBytes(~a), 0));" v)
             (format "Put32(buf, off, (int)~a);" v))]
        [(cs-struct-fixed64-type? t)
         (if (= t 1)
             (format "Put64(buf, off, BitConverter.DoubleToInt64Bits(~a));" v)
             (format "Put64(buf, off, (long)~a);" v))]
        [(= t 8) (format "buf[off] = (byte)(~a ? 1 : 0);" v)]
        [(= t 14) (format "Put64(buf, off, (int)~a);" v)]
        [else (format "Put64(buf, off, (long)~a);" v)]))

(define (cs-struct-scalar-decode/off model f target offv)
  (define t (hash-ref f 'type))
  (cond [(cs-struct-fixed32-type? t)
         (if (= t 2)
             (format "~a = BitConverter.ToSingle(BitConverter.GetBytes(Get32(data, ~a)), 0);" target offv)
             (format "~a = Get32(data, ~a);" target offv))]
        [(cs-struct-fixed64-type? t)
         (if (= t 1)
             (format "~a = BitConverter.Int64BitsToDouble(Get64(data, ~a));" target offv)
             (format "~a = (~a)Get64(data, ~a);" target (cs-pb-type model (hash-set f 'label 1)) offv))]
        [(= t 8) (format "~a = data[~a] != 0;" target offv)]
        [(= t 14) (format "~a = (~a)(int)Get64(data, ~a);" target
                          (cs-pb-type model (hash-set f 'label 1)) offv)]
        [(member t '(5 17)) (format "~a = (int)Get64(data, ~a);" target offv)]
        [else (format "~a = (~a)Get64(data, ~a);" target (cs-pb-type model (hash-set f 'label 1)) offv)]))

(define (cs-struct-scalar-value/off model f offv)
  (define t (hash-ref f 'type))
  (cond [(cs-struct-fixed32-type? t)
         (if (= t 2) (format "BitConverter.ToSingle(BitConverter.GetBytes(Get32(data, ~a)), 0)" offv)
             (format "Get32(data, ~a)" offv))]
        [(cs-struct-fixed64-type? t)
         (if (= t 1) (format "BitConverter.Int64BitsToDouble(Get64(data, ~a))" offv)
             (format "Get64(data, ~a)" offv))]
        [(= t 8) (format "(data[~a] != 0)" offv)]
        [(= t 14) (format "(~a)(int)Get64(data, ~a)" (cs-pb-type model (hash-set f 'label 1)) offv)]
        [(member t '(5 17)) (format "(int)Get64(data, ~a)" offv)]
        [else (format "(~a)Get64(data, ~a)" (cs-pb-type model (hash-set f 'label 1)) offv)]))

(define (cs-struct-value-size model f v)
  (define t (hash-ref f 'type))
  (cond [(= t 9) (format "System.Text.Encoding.UTF8.GetBytes(~a).Length" v)]
        [(= t 12) (format "~a.Length" v)]
        [(= t 11) (format "(~a == null ? 0 : ~a.Size(~a))" v (cs-struct-companion model f) v)]
        [(cs-struct-fixed32-type? t) "4"]
        [else "8"]))

(define (cs-struct-message model msg)
  (parameterize ([current-struct-model model])
    (cs-struct-message/inner model msg)))

(define (cs-struct-message/inner model msg)
  (define type-name (cs-struct-type-name model msg))
  (define bridge (cs-struct-bridge-name model))
  (define out (open-output-string))
  (fprintf out "public static class ~aStruct {\n" type-name)
  (fprintf out "    public static int Size(~a m) => Marshal(m).Length;\n\n" type-name)
  (fprintf out "    public static byte[] Marshal(~a m) => ~a.Encode(\"~a\", m.MarshalDc());\n\n" type-name bridge (hash-ref msg 'full-name))
  (fprintf out "    public static ~a Unmarshal(byte[] data) {\n        var m = new ~a();\n        m.UnmarshalDc(~a.Decode(\"~a\", data));\n        return m;\n    }\n}\n" type-name type-name bridge (hash-ref msg 'full-name))
  (get-output-string out))

(define (cs-struct-value-write model f v)
  (define t (hash-ref f 'type))
  (define out (open-output-string))
  (cond [(= t 9)
         (fprintf out "                { var sb = System.Text.Encoding.UTF8.GetBytes(~a); System.Array.Copy(sb, 0, buf, vp, sb.Length); vp += sb.Length; }\n" v)]
        [(= t 12)
         (fprintf out "                System.Array.Copy(~a, 0, buf, vp, ~a.Length); vp += ~a.Length;\n" v v v)]
        [(= t 11)
         (fprintf out "                if (~a != null) { var nb = ~a.Marshal(~a); System.Array.Copy(nb, 0, buf, vp, nb.Length); vp += nb.Length; }\n" v (cs-struct-companion model f) v)]
        [else
         (fprintf out "                { int off = vp; ~a } vp += ~a;\n"
                  (cs-struct-scalar-encode f v) (if (cs-struct-fixed32-type? t) 4 8))])
  (get-output-string out))

(define (cs-struct-marshal-field model f off)
  (define cn (cs-struct-field-name f))
  (define t (hash-ref f 'type))
  (define out (open-output-string))
  (define mv (format "m.~a" cn))
  (cond [(cs-struct-map-entry model f)
         (define kf (cs-struct-map-key-field model f))
         (define vf (cs-struct-map-val-field model f))
         (fprintf out "        if (~a.Count > 0) {\n            Put32(buf, ~a, vp); Put32(buf, ~a, ~a.Count);\n" mv off (+ off 4) mv)
         (fprintf out "            var keys = new System.Collections.Generic.List<~a>(~a.Keys);\n            keys.Sort();\n"
                  (cs-pb-type model (hash-set kf 'label 1)) mv)
         (fprintf out "            foreach (var k in keys) {\n                var v = ~a[k];\n                Put32(buf, vp, ~a); Put32(buf, vp + 4, ~a); vp += 8;\n"
                  mv (cs-struct-value-size model kf "k") (cs-struct-value-size model vf "v"))
         (display (cs-struct-value-write model kf "k") out)
         (display (cs-struct-value-write model vf "v") out)
         (fprintf out "            }\n        }\n")]
        [(= (hash-ref f 'label) 3)
         (cond [(member t '(9 12))
                (fprintf out "        if (~a.Count > 0) {\n            Put32(buf, ~a, vp); Put32(buf, ~a, ~a.Count);\n            int doff = vp + 8 * ~a.Count;\n            foreach (var e in ~a) { Put32(buf, vp, doff); Put32(buf, vp + 4, ~a); doff += ~a; vp += 8; }\n            foreach (var e in ~a) { ~a }\n        }\n"
                         mv off (+ off 4) mv mv mv
                         (if (= t 9) "System.Text.Encoding.UTF8.GetBytes(e).Length" "e.Length")
                         (if (= t 9) "System.Text.Encoding.UTF8.GetBytes(e).Length" "e.Length")
                         mv
                         (if (= t 9) "var sb = System.Text.Encoding.UTF8.GetBytes(e); System.Array.Copy(sb, 0, buf, vp, sb.Length); vp += sb.Length;"
                             "System.Array.Copy(e, 0, buf, vp, e.Length); vp += e.Length;"))]
               [(= t 11)
                (fprintf out "        if (~a.Count > 0) {\n            Put32(buf, ~a, vp); Put32(buf, ~a, ~a.Count);\n            int doff = vp + 8 * ~a.Count;\n            foreach (var e in ~a) { int es = ~a.Size(e); Put32(buf, vp, doff); Put32(buf, vp + 4, es); doff += es; vp += 8; }\n            foreach (var e in ~a) { var nb = ~a.Marshal(e); System.Array.Copy(nb, 0, buf, vp, nb.Length); vp += nb.Length; }\n        }\n"
                         mv off (+ off 4) mv mv mv (cs-struct-companion model f)
                         mv (cs-struct-companion model f))]
               [else
                (fprintf out "        if (~a.Count > 0) {\n            Put32(buf, ~a, vp); Put32(buf, ~a, ~a.Count);\n            foreach (var e in ~a) { int off = vp; ~a vp += ~a; }\n        }\n"
                         mv off (+ off 4) mv
                         mv
                         (cs-struct-scalar-encode f "e")
                         (if (cs-struct-fixed32-type? t) 4 8))])]
        [(= t 11)
         (fprintf out "        if (~a != null) {\n            Put32(buf, ~a, vp); Put32(buf, ~a, ~a.Size(~a));\n            var nb = ~a.Marshal(~a); System.Array.Copy(nb, 0, buf, vp, nb.Length); vp += nb.Length;\n        }\n"
                  mv off (+ off 4) (cs-struct-companion model f) mv (cs-struct-companion model f) mv)]
        [(member t '(9 12))
         (fprintf out "        if (~a.Length > 0) {\n            Put32(buf, ~a, vp); Put32(buf, ~a, ~a);\n            ~a\n        }\n"
                  mv off (+ off 4)
                  (if (= t 9) (format "System.Text.Encoding.UTF8.GetBytes(~a).Length" mv) (format "~a.Length" mv))
                  (if (= t 9)
                      (format "var sb = System.Text.Encoding.UTF8.GetBytes(~a); System.Array.Copy(sb, 0, buf, vp, sb.Length); vp += sb.Length;" mv)
                      (format "System.Array.Copy(~a, 0, buf, vp, ~a.Length); vp += ~a.Length;" mv mv mv)))]
        [else
         (fprintf out "        { int off = ~a; ~a }\n" off (cs-struct-scalar-encode f mv))])
  (get-output-string out))

(define (cs-struct-value-read/off model f target lenvar offv)
  (define t (hash-ref f 'type))
  (cond [(= t 9) (format "~a = System.Text.Encoding.UTF8.GetString(data, ~a, ~a);" target offv lenvar)]
        [(= t 12) (format "~a = Slice(data, ~a, ~a);" target offv lenvar)]
        [(= t 11) (format "if (~a > 0) { ~a = ~a.Unmarshal(Slice(data, ~a, ~a)); } else { ~a = new ~a(); }" lenvar target (cs-struct-companion model f) offv lenvar target (cs-struct-class-name model f))]
        [else (cs-struct-scalar-decode/off model f target offv)]))

(define (cs-struct-decode-field model f foff)
  (define cn (cs-struct-field-name f))
  (define t (hash-ref f 'type))
  (define out (open-output-string))
  (define mv (format "m.~a" cn))
  (cond [(cs-struct-map-entry model f)
         (define kf (cs-struct-map-key-field model f))
         (define vf (cs-struct-map-val-field model f))
         (fprintf out "            int off = Get32(data, ~a); int n = Get32(data, ~a);\n" foff (+ foff 4))
         (fprintf out "            int p = off;\n            for (int i = 0; i < n; i++) {\n")
         (fprintf out "                Check(data, p, 8);\n                int kl = Get32(data, p); int vl = Get32(data, p + 4); p += 8;\n                Check(data, p, kl + vl);\n")
         (fprintf out "                ~a k; { int io = p; ~a }\n" (cs-pb-type model (hash-set kf 'label 1)) (cs-struct-value-read/off model kf "k" "kl" "io"))
         (fprintf out "                ~a v; { int io = p + kl; ~a }\n" (cs-pb-type model (hash-set vf 'label 1)) (cs-struct-value-read/off model vf "v" "vl" "io"))
         (fprintf out "                ~a[k] = v;\n                p += kl + vl;\n            }\n            if (p > vend) { vend = p; }\n" mv)]
        [(= (hash-ref f 'label) 3)
         (fprintf out "            int off = Get32(data, ~a); int n = Get32(data, ~a);\n" foff (+ foff 4))
         (cond [(member t '(9 12))
                (fprintf out "            for (int i = 0; i < n; i++) {\n                int eo = Get32(data, off + 8 * i); int el = Get32(data, off + 8 * i + 4);\n                Check(data, eo, el);\n                ~a.Add(~a);\n                if (eo + el > vend) { vend = eo + el; }\n            }\n"
                         mv (if (= t 9) "System.Text.Encoding.UTF8.GetString(data, eo, el)" "Slice(data, eo, el)"))]
               [(= t 11)
                (fprintf out "            for (int i = 0; i < n; i++) {\n                int eo = Get32(data, off + 8 * i); int el = Get32(data, off + 8 * i + 4);\n                if (el > 0) {\n                    Check(data, eo, el);\n                    ~a.Add(~a.Unmarshal(Slice(data, eo, el)));\n                    if (eo + el > vend) { vend = eo + el; }\n                } else { ~a.Add(null); }\n            }\n"
                         mv (cs-struct-companion model f) mv)]
               [else
                (define esz (if (cs-struct-fixed32-type? t) 4 8))
                (fprintf out "            Check(data, off, n * ~a);\n            for (int i = 0; i < n; i++) {\n                int eo = off + i * ~a;\n                ~a.Add(~a);\n            }\n            if (off + n * ~a > vend) { vend = off + n * ~a; }\n"
                         esz esz mv (cs-struct-scalar-value/off model f "eo") esz esz)])]
        [(= t 11)
         (fprintf out "            int off = Get32(data, ~a); int el = Get32(data, ~a);\n" foff (+ foff 4))
         (fprintf out "            Check(data, off, el);\n            ~a = ~a.Unmarshal(Slice(data, off, el));\n            if (off + el > vend) { vend = off + el; }\n" mv (cs-struct-companion model f))]
        [(member t '(9 12))
         (fprintf out "            int off = Get32(data, ~a); int el = Get32(data, ~a);\n" foff (+ foff 4))
         (fprintf out "            Check(data, off, el);\n")
         (if (= t 9)
             (fprintf out "            ~a = System.Text.Encoding.UTF8.GetString(data, off, el);\n" mv)
             (fprintf out "            ~a = Slice(data, off, el);\n" mv))
         (fprintf out "            if (off + el > vend) { vend = off + el; }\n")]
        [else
         (fprintf out "            int off = ~a;\n            ~a\n" foff
                  (cs-struct-scalar-decode/off model f mv "off"))])
  (get-output-string out))

(define (cs-struct-bridge-file model)
  (define pkg (hash-ref model 'package))
  (string-append
   "// @generated by protoc-gen-grpc-dc-csharp. DO NOT EDIT.\n"
   (format "// source: ~a\n\n" (hash-ref model 'name))
   "using System;\nusing System.Runtime.InteropServices;\n\n"
   (format "namespace ~a;\n\n" (cs-pb-ns pkg))
   (format "internal static class ~a {\n" (cs-struct-bridge-name model))
   (format "    private static readonly byte[] Descriptor = new byte[] {~a};\n\n"
           (string-join
            (for/list ([b (in-bytes (hash-ref model 'descriptor-set #""))])
              (format "0x~x" b))
            ","))
   "    [DllImport(\"grpc_dc\", EntryPoint = \"grpcdc_struct_encode\")]\n"
   "    private static extern int StructEncode(byte[] desc, UIntPtr descLen, byte[] typeName, UIntPtr typeLen, byte[] input, UIntPtr inputLen, out IntPtr output, out UIntPtr outputLen, out IntPtr error);\n\n"
   "    [DllImport(\"grpc_dc\", EntryPoint = \"grpcdc_struct_decode\")]\n"
   "    private static extern int StructDecode(byte[] desc, UIntPtr descLen, byte[] typeName, UIntPtr typeLen, byte[] input, UIntPtr inputLen, out IntPtr output, out UIntPtr outputLen, out IntPtr error);\n\n"
   "    [DllImport(\"grpc_dc\", EntryPoint = \"grpcdc_struct_free\")]\n"
   "    private static extern void StructFree(IntPtr ptr, UIntPtr len);\n\n"
   "    [DllImport(\"grpc_dc\", EntryPoint = \"grpcdc_struct_error_free\")]\n"
   "    private static extern void StructErrorFree(IntPtr ptr);\n\n"
   "    public static byte[] Encode(string typeName, byte[] pb) => Transcode(true, typeName, pb);\n\n"
   "    public static byte[] Decode(string typeName, byte[] data) => Transcode(false, typeName, data);\n\n"
   "    private static byte[] Transcode(bool encode, string typeName, byte[] input) {\n"
   "        var typeBytes = System.Text.Encoding.UTF8.GetBytes(typeName);\n"
   "        IntPtr output; UIntPtr outputLen; IntPtr error;\n"
   "        var rc = encode\n"
   "            ? StructEncode(Descriptor, (UIntPtr)Descriptor.Length, typeBytes, (UIntPtr)typeBytes.Length, input, (UIntPtr)input.Length, out output, out outputLen, out error)\n"
   "            : StructDecode(Descriptor, (UIntPtr)Descriptor.Length, typeBytes, (UIntPtr)typeBytes.Length, input, (UIntPtr)input.Length, out output, out outputLen, out error);\n"
   "        if (rc != 0) {\n"
   "            var msg = \"struct codec transcode failed\";\n"
   "            if (error != IntPtr.Zero) { var elen = 0; while (Marshal.ReadByte(error, elen) != 0) { elen++; } var ebytes = new byte[elen]; Marshal.Copy(error, ebytes, 0, elen); msg = System.Text.Encoding.UTF8.GetString(ebytes); StructErrorFree(error); }\n"
   "            throw new InvalidOperationException(msg);\n"
   "        }\n"
   "        var result = new byte[(int)outputLen];\n"
   "        Marshal.Copy(output, result, 0, result.Length);\n"
   "        StructFree(output, outputLen);\n"
   "        return result;\n"
   "    }\n"
   "}\n"))

(define (emit-csharp-struct-files file-model params)
  (if (equal? (hash-ref params 'struct_codec #f) "true")
      (let ()
        (define pkg (hash-ref file-model 'package))
        (define comps '())
        (define (emit-comp msg)
          (unless (hash-ref msg 'map-entry)
            (set! comps
                  (cons (cons (string-append (cs-struct-type-name file-model msg) "Struct.cs")
                              (string-append
                               "// @generated by protoc-gen-grpc-dc-csharp. DO NOT EDIT.\n"
                               (format "// source: ~a\n\n" (hash-ref file-model 'name))
                               "using System;\n\n"
                               (format "namespace ~a;\n\n" (cs-pb-ns pkg))
                               (cs-struct-message file-model msg)))
                        comps)))
          (for ([n (in-list (hash-ref msg 'nested))]) (emit-comp n)))
        (for ([m (in-list (hash-ref file-model 'messages))]) (emit-comp m))
        (cons (cons (string-append (cs-struct-bridge-name file-model) ".cs")
                    (cs-struct-bridge-file file-model))
              (reverse comps)))
      '()))
