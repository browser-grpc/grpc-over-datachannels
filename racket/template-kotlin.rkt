#lang racket

;;; template-kotlin.rkt — emitter body spliced into
;;; protoc-gen-grpc-dc-kotlin.
;;;
;;; Generated code is one object <Base>GrpcDc in the proto package,
;;; beside hand-written message types implementing Marshaler /
;;; Unmarshaler. Method names keep the proto spelling, mirroring the
;;; other language stubs.

(require "spec.rkt" "desc.rkt" "segments.rkt")
(provide emit-kotlin-file emit-wasm-kotlin-native-file)

(define kotlin-wasm-mode (make-parameter #f))



;; Stub type reference for a method input/output: the simple class
;; name when the message lives in the stub file's own package,
;; fully qualified otherwise (Kotlin cannot resolve a simple name
;; across packages).
(define (kotlin-qualify-type pkg simple full)
  (cond [(or (not full) (string=? pkg "")
             (string-prefix? full (string-append pkg ".")))
         simple]
        [else full]))

(define (kotlin-qualify-services pkg services)
  (for/list ([svc (in-list services)])
    (hash-set svc 'methods
              (for/list ([m (in-list (hash-ref svc 'methods))])
                (hash-set* m
                           'input (kotlin-qualify-type pkg (hash-ref m 'input)
                                                       (hash-ref m 'input-full #f))
                           'output (kotlin-qualify-type pkg (hash-ref m 'output)
                                                        (hash-ref m 'output-full #f)))))))

(define current-service (make-parameter ""))

(define (pascal sym) ; echo_service -> EchoService ; echo -> Echo
  (apply string-append
         (for/list ([part (in-list (string-split (symbol->string sym) "[_.-]"))])
           (if (string=? part "")
               ""
               (string-append (string (char-upcase (string-ref part 0)))
                              (substring part 1))))))





(define (kotlin-client-method m)
  (run-segments kotlin-client-method-program m (current-service) #f (list "        ")))

(define (kotlin-client-stream-class m)
  (run-segments kotlin-client-stream-class-program m (current-service)))

(define (kotlin-client-async-method m)
  (run-segments kotlin-client-async-method-program m (current-service)))

(define (kotlin-server-stream-iface m)
  (run-segments kotlin-server-stream-iface-program m (current-service)))



(define (kotlin-server-iface-method m)
  (run-segments kotlin-server-iface-method-program m (current-service) #f (list "        ")))

(define (kotlin-server-async-iface-method m)
  (run-segments kotlin-server-async-iface-method-program m (current-service)))

(define (kotlin-server-async-adapter-method m)
  (run-segments kotlin-server-async-adapter-method-program m (current-service)))

(define (kotlin-stream-impl m)
  (run-segments kotlin-stream-impl-program m (current-service)))

(define (kotlin-register-method m)
  (run-segments kotlin-register-method-program m (current-service)))

(define (kotlin-service svc)
  (parameterize ([seg-kotlin-wasm-mode (kotlin-wasm-mode)])
    (run-segments kotlin-service-program svc (hash-ref svc 'name))))

;; ---------------------------------------------------------------------------
;; Kotlin message types (<Base>Messages.kt): classes implementing
;; grpcdc.Marshaler/Unmarshaler plus a <Base>Pb wire-support object
;; per proto file. Dependency-free (JDK only). Mirrors the Swift
;; emitter on the shared desc.rkt model.
;; ---------------------------------------------------------------------------

(define kt-pb-varint-types varint-scalar-types)
(define kt-pb-fixed (fixed-scalar-table 'kotlin))





(define (kt-pb-resolve model type-name)
  (hash-ref (hash-ref model 'types) type-name
            (lambda () (error 'emit-kotlin-pb-file "unresolved type ~a" type-name))))







(define (kt-pb-type model f)
  (run-segments kt-pb-type-program f #f model))

(define (kt-pb-explicit-literal model f)
  (run-segments kt-pb-explicit-literal-program f #f model))

(define (kt-pb-default model f)
  (run-segments kt-pb-default-program f #f model))

(define (kt-pb-varint-expr f v)
  (run-segments kt-pb-varint-expr-program f #f #f (list v)))

(define (kt-pb-varint-decode f v)
  (run-segments kt-pb-varint-decode-program f #f #f (list v)))

(define (kt-pb-nonzero f v)
  (run-segments kt-pb-nonzero-program f #f #f (list v)))

(define (kt-pb-encode-singular model f v indent)
  (run-segments kt-pb-encode-singular-program f #f model (list v indent)))

(define (kt-pb-set-expr sib)
  (run-segments kt-pb-set-expr-program sib #f))

;; Encode-side oneof clearing: suppress f when a later sibling is
;; set, so only the winning member is written.


(define (kt-pb-encode-field model f support)
  (run-segments kt-pb-encode-field-program f #f model (list support)))

(define (kt-pb-decode-singular model f target src indent support)
  (run-segments kt-pb-decode-singular-program f #f model (list target src indent support)))

(define (kt-pb-oneof-clearing model f)
  (run-segments kt-pb-clearing-program f #f model))

(define (kt-pb-decode-case model f support)
  (run-segments kt-pb-decode-case-program f #f model (list support)))



(define (kt-pb-map-helpers model entry support)
  (run-segments kt-pb-map-helpers-program entry #f model (list support)))

(define (kt-pb-support base pkg helpers)
  (string-append
   "// @generated by protoc-gen-grpc-dc-kotlin. DO NOT EDIT.\n"
   (format "package ~a\n\n" (if (string=? pkg "") "proto" pkg))
   "import grpcdc.Marshaler\nimport grpcdc.Unmarshaler\n\n"
   (format "object ~aPb {\n" (pascal (string->symbol base)))
   "    class Writer {\n"
   "        private val out = java.io.ByteArrayOutputStream()\n"
   "        fun varint(value: Long) { var v = value; while ((v and -0x80L) != 0L) { out.write(((v and 0x7f) or 0x80).toInt()); v = v ushr 7 }; out.write(v.toInt()) }\n"
   "        fun varint(value: ULong) { varint(value.toLong()) }\n"
   "        fun tag(field: Int, wire: Int) { varint(((field shl 3) or wire).toLong()) }\n"
   "        fun bytesField(field: Int, payload: ByteArray) { tag(field, 2); varint(payload.size.toLong()); out.write(payload) }\n"
   "        fun stringField(field: Int, value: String) { if (value.isEmpty()) return; bytesField(field, value.toByteArray(Charsets.UTF_8)) }\n"
   "        fun fixedInt(value: Int) { for (i in 0 until 4) out.write((value shr (8 * i)) and 0xff) }\n"
   "        fun fixedUInt(value: UInt) { fixedInt(value.toInt()) }\n"
   "        fun fixedLong(value: Long) { for (i in 0 until 8) out.write(((value shr (8 * i)) and 0xff).toInt()) }\n"
   "        fun fixedULong(value: ULong) { fixedLong(value.toLong()) }\n"
   "        fun fixedFloat(value: Float) { fixedInt(value.toBits()) }\n"
   "        fun fixedDouble(value: Double) { fixedLong(value.toBits()) }\n"
   "        fun raw(payload: ByteArray) { out.write(payload) }\n"
   "        fun toBytes(): ByteArray = out.toByteArray()\n"
   "    }\n\n"
   "    fun bitsToFloat(u: UInt): Float = Float.fromBits(u.toInt())\n"
   "    fun bitsToDouble(u: ULong): Double = Double.fromBits(u.toLong())\n\n"
   "    class Field(val number: Int, val wire: Int, val varintValue: Long, val bytesValue: ByteArray, val fixedValue: Long, val rawValue: ByteArray)\n\n"
   "    class Reader(private val buf: ByteArray) {\n"
   "        private var pos = 0\n"
   "        fun done(): Boolean = pos >= buf.size\n"
   "        fun varint(): Long { var result = 0L; var shift = 0; while (true) { if (pos >= buf.size) throw IllegalArgumentException(\"truncated varint\"); val b = buf[pos++].toInt() and 0xff; result = result or ((b and 0x7f).toLong() shl shift); if ((b and 0x80) == 0) return result; shift += 7; if (shift >= 64) throw IllegalArgumentException(\"varint too long\") } }\n"
   "        fun take(n: Int): ByteArray { if (pos + n > buf.size) throw IllegalArgumentException(\"truncated field\"); val v = buf.copyOfRange(pos, pos + n); pos += n; return v }\n"
   "        fun fixed32(): UInt { val b = take(4); return (b[0].toInt() and 0xff).toUInt() or ((b[1].toInt() and 0xff).toUInt() shl 8) or ((b[2].toInt() and 0xff).toUInt() shl 16) or ((b[3].toInt() and 0xff).toUInt() shl 24) }\n"
   "        fun fixed64(): ULong { val b = take(8); var v = 0UL; for (i in 0 until 8) v = v or ((b[i].toInt() and 0xff).toULong() shl (8 * i)); return v }\n"
   "        fun next(): Field? {\n"
   "            if (pos >= buf.size) return null\n"
   "            val start = pos\n"
   "            val tag = varint(); val number = (tag shr 3).toInt(); val wire = (tag and 7).toInt()\n"
   "            return when (wire) {\n"
   "                0 -> { val v = varint(); Field(number, wire, v, ByteArray(0), 0, buf.copyOfRange(start, pos)) }\n"
   "                2 -> { val n = varint().toInt(); val b = take(n); Field(number, wire, 0, b, 0, buf.copyOfRange(start, pos)) }\n"
   "                1 -> { val b = take(8); var v = 0L; for (i in 0 until 8) v = v or ((b[i].toInt() and 0xff).toLong() shl (8 * i)); Field(number, wire, 0, b, v, buf.copyOfRange(start, pos)) }\n"
   "                5 -> { val b = take(4); val v = (b[0].toInt() and 0xff) or ((b[1].toInt() and 0xff) shl 8) or ((b[2].toInt() and 0xff) shl 16) or ((b[3].toInt() and 0xff) shl 24); Field(number, wire, 0, b, v.toLong(), buf.copyOfRange(start, pos)) }\n"
   "                else -> throw IllegalArgumentException(\"bad wire type \" + wire)\n"
   "            }\n"
   "        }\n"
   "    }\n\n"
   helpers
   "}\n\n"))

(define (kt-pb-message-class model msg support indent decl)
  (run-segments kt-pb-message-program msg #f model (list support indent decl)))

(define (kt-pb-nested-enum e indent)
  (run-segments kt-pb-nested-enum-program e #f #f (list indent)))

(define (emit-kotlin-pb-file file-model)
  (and (hash-has-key? file-model 'messages)
       (hash-has-key? file-model 'types)
       (emit-kotlin-pb-file/inner file-model)))

(define (emit-kotlin-pb-file/inner file-model)
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
               (define e (kt-pb-resolve file-model (hash-ref f 'type-name)))
               (when (and (eq? (hash-ref e 'kind) 'map)
                          (not (set-member? seen-maps (hash-ref (hash-ref e 'msg) 'full-name))))
                 (set-add! seen-maps (hash-ref (hash-ref e 'msg) 'full-name))
                 (set! helpers (cons (kt-pb-map-helpers file-model e support) helpers)))))
           (for ([n (in-list (hash-ref msg 'nested))]) (collect n)))
         (for ([m (in-list messages)]) (collect m))
         (define content
           (string-append
            (kt-pb-support base pkg (apply string-append (reverse helpers)))
            (apply string-append
                   (map (lambda (e)
                          (string-append
                           (format "enum class ~a(val number: Int) {\n" (hash-ref e 'name))
                           (string-join (map (lambda (v) (format "    ~a(~a)" (hash-ref v 'name) (hash-ref v 'number)))
                                             (hash-ref e 'values)) ",\n")
                           ";\n    companion object {\n"
                           (format "        fun fromNumber(number: Int): ~a =\n" (hash-ref e 'name))
                           "            when (number) {\n"
                           (apply string-append
                                  (map (lambda (v) (format "                ~a -> ~a\n" (hash-ref v 'number) (hash-ref v 'name)))
                                       (hash-ref e 'values)))
                           (format "                else -> ~a\n            }\n    }\n}\n\n" (hash-ref (car (hash-ref e 'values)) 'name))))
                        enums))
            (apply string-append
                   (map (lambda (m) (kt-pb-message-class file-model m support "" ""))
                        (filter (lambda (m) (not (hash-ref m 'map-entry))) messages)))))
         (cons (string-append (pascal (string->symbol base)) "Messages.kt") content))))

(define (emit-kotlin-file file-model params)
  (define base (path->string (path-replace-extension
                              (file-name-from-path (hash-ref file-model 'name)) "")))
  (define object-name (string-append (pascal (string->symbol base)) "GrpcDc"))
  (define pkg (hash-ref file-model 'package))
  (define stub
    (cons (string-append object-name ".kt")
          (string-append
           "// @generated by protoc-gen-grpc-dc-kotlin. DO NOT EDIT.\n"
         (format "// source: ~a\n" (hash-ref file-model 'name))
         (format "package ~a\n\n" (if (string=? pkg "") "proto" pkg))
         "import grpcdc.AsyncPump\n"
         "import grpcdc.Channel\n"
         "import grpcdc.Endpoint\n"
         "import grpcdc.Server\n"
         "import grpcdc.StatusException\n"
         "import grpcdc.Wire\n"
         "import java.io.EOFException\n"
         "import java.util.concurrent.CompletableFuture\n\n"
         ;; trace=hooks: delegate the tracer registrar to grpcdc.Tracing.
         (if (equal? (hash-ref params 'trace #f) "hooks")
             (string-append
              "// Tracing (trace=hooks@@TRACING_BETA@@): register an observer via setTracer.\n"
              "fun setTracer(t: grpcdc.Tracing.Tracer?) = grpcdc.Tracing.setTracer(t)\n"
              "fun setTraceFilter(patterns: String) = grpcdc.Tracing.setTraceFilter(patterns)\n"
              (let ([methods (hash-ref params 'trace_methods #f)])
                (if methods
                    (format "private val _grpcdcTraceFilterApplied: Boolean = run { grpcdc.Tracing.setTraceFilter(~s); true }\n" methods)
                    ""))
              "\n")
             "")
         (format "/** Generated gRPC-over-DataChannels stubs for ~a. */\n" (hash-ref file-model 'name))
         (format "object ~a {\n" object-name)
         (apply string-append
                (map kotlin-service
                     (kotlin-qualify-services pkg (hash-ref file-model 'services))))
         "}\n")))
  (define pb-file (parameterize ([seg-struct-codec (equal? (hash-ref params 'struct_codec #f) "true")])
                    (emit-kotlin-pb-file file-model)))
  (define struct-files (emit-kotlin-struct-files file-model params pkg))
  (if (null? struct-files)
      (if pb-file (list stub pb-file) stub)
      (append (list stub pb-file) struct-files)))

;; ---------------------------------------------------------------------------
;; Kotlin/Wasm native stubs: the same template over the Wasm
;; runtime variant -- no CompletableFuture/async surface,
;; timeouts as Long nanoseconds, EOF from grpcdc.
;; ---------------------------------------------------------------------------

(define (emit-wasm-kotlin-native-file file-model params)
  (define result
    (parameterize ([kotlin-wasm-mode #t])
      (emit-kotlin-file file-model params)))
  (define files (if (and (pair? result) (string? (car result))) (list result) result))
  (cons (cons (caar files)
              (for/fold ([text (cdar files)])
                  ([pair (in-list (list
                                   (cons "import grpcdc.AsyncPump\n" "")
                                   (cons "import java.util.concurrent.CompletableFuture\n" "")
                                   (cons "import java.io.EOFException\n" "import grpcdc.EOFException\n")
                                   (cons "java.time.Duration?" "Long?")
                                   (cons "protoc-gen-grpc-dc-kotlin" "protoc-gen-grpc-dc-kotlin-native")))])
          ;; Schemas without services legitimately lack the import
          ;; and Duration patterns; rewrite what is present.
          (if (string-contains? text (car pair))
              (string-replace text (car pair) (cdr pair))
              text)))
        (cdr files)))

;; ------------------------------------------------------------------
;; Struct codec (struct_codec=true): <Msg>Struct object per message
;; with the packed layout from SPEC.md (byte-identical to the
;; Go/Rust/Java struct codecs; verified by conformance/struct).
(define (kt-descriptor-hex bstr)
  (apply string-append
         (for/list ([b (in-bytes bstr)])
           (let ([h (format "~x" b)])
             (if (= (string-length h) 1) (string-append "0" h) h)))))

(define (kt-struct-fingerprint s)
  (for/fold ([h 2166136261]) ([c (in-string s)])
    (modulo (* (bitwise-xor h (char->integer c)) 16777619) 4294967296)))

(define (kt-struct-fixed32-type? t) (member t '(2 7 15)))
(define (kt-struct-fixed64-type? t) (member t '(1 6 16)))

(define (kt-struct-slot-size f)
  (define t (hash-ref f 'type))
  (cond [(kt-struct-fixed32-type? t) 4] [else 8]))

(define (kt-struct-sorted-fields msg)
  (sort (hash-ref msg 'fields) < #:key (lambda (f) (hash-ref f 'number))))

(define (kt-struct-resolve model type-name)
  (hash-ref (hash-ref model 'types) type-name
            (lambda () (error 'emit-kotlin-struct "unresolved type ~a" type-name))))

(define (kt-struct-map-entry model f)
  (and (= (hash-ref f 'type) 11)
       (let ([e (kt-struct-resolve model (hash-ref f 'type-name))])
         (and (eq? (hash-ref e 'kind) 'map) e))))

(define (kt-struct-map-key-field model f)
  (define em (hash-ref (kt-struct-map-entry model f) 'msg))
  (findf (lambda (x) (= (hash-ref x 'number) 1)) (hash-ref em 'fields)))
(define (kt-struct-map-val-field model f)
  (define em (hash-ref (kt-struct-map-entry model f) 'msg))
  (findf (lambda (x) (= (hash-ref x 'number) 2)) (hash-ref em 'fields)))

(define (kt-struct-simple-name full)
  (car (reverse (string-split full "."))))

(define (kt-struct-type-name model msg)
  (kt-struct-simple-name (hash-ref msg 'full-name)))

(define (kt-struct-companion model f)
  (define e (kt-struct-resolve model (hash-ref f 'type-name)))
  (string-append (kt-struct-simple-name (hash-ref (hash-ref e 'msg) 'full-name)) "Struct"))

(define (kt-struct-field-name f)
  (define jn (hash-ref f 'json-name ""))
  (if (string=? jn "") (hash-ref f 'name) jn))

(define (kt-struct-zero f)
  (case (hash-ref f 'type)
    [(1) "0.0"] [(2) "0f"] [(3 16 18) "0L"] [(4 6) "0uL"] [(7 13) "0u"]
    [else "0"]))

(define (kt-struct-present f kn)
  (define t (hash-ref f 'type))
  (cond [(= (hash-ref f 'label) 3) (format "m.~a.isNotEmpty()" kn)]
        [(= t 11) (format "m.~a != null" kn)]
        [(= t 9) (format "m.~a.isNotEmpty()" kn)]
        [(= t 12) (format "m.~a.isNotEmpty()" kn)]
        [(= t 8) (format "m.~a" kn)]
        [(= t 14) (format "m.~a.number != 0" kn)]
        [else (format "m.~a != ~a" kn (kt-struct-zero f))]))

;; put32/put64 statements writing v (in a slot at `off`)
(define (kt-struct-scalar-encode f v)
  (define t (hash-ref f 'type))
  (cond [(kt-struct-fixed32-type? t)
         (cond [(= t 2) (format "put32(buf, off, ~a.toBits())" v)]
               [(= t 7) (format "put32(buf, off, ~a.toInt())" v)]
               [else (format "put32(buf, off, ~a)" v)])]
        [(kt-struct-fixed64-type? t)
         (cond [(= t 1) (format "put64(buf, off, ~a.toBits())" v)]
               [(= t 6) (format "put64(buf, off, ~a.toLong())" v)]
               [else (format "put64(buf, off, ~a)" v)])]
        [(= t 8) (format "buf[off] = if (~a) 1 else 0" v)]
        [(= t 14) (format "put64(buf, off, ~a.number.toLong())" v)]
        [(member t '(4)) (format "put64(buf, off, ~a.toLong())" v)]
        [(member t '(5 17)) (format "put64(buf, off, ~a.toLong())" v)]
        [else (format "put64(buf, off, ~a)" v)]))

;; expression reading a scalar of field f's type at data[offv]
(define (kt-struct-scalar-value/off model f offv)
  (define t (hash-ref f 'type))
  (cond [(kt-struct-fixed32-type? t)
         (cond [(= t 2) (format "Float.fromBits(get32(data, ~a))" offv)]
               [(= t 7) (format "get32(data, ~a).toUInt()" offv)]
               [else (format "get32(data, ~a)" offv)])]
        [(kt-struct-fixed64-type? t)
         (cond [(= t 1) (format "Double.fromBits(get64(data, ~a))" offv)]
               [(= t 6) (format "get64(data, ~a).toULong()" offv)]
               [else (format "get64(data, ~a)" offv)])]
        [(= t 8) (format "(data[~a].toInt() != 0)" offv)]
        [(= t 14) (format "~a.fromNumber(get64(data, ~a).toInt())"
                        (kt-pb-type model (hash-set f 'label 1)) offv)]
        [(member t '(5 17)) (format "get64(data, ~a).toInt()" offv)]
        [(member t '(7 13)) (format "get64(data, ~a).toUInt()" offv)]
        [(= t 4) (format "get64(data, ~a).toULong()" offv)]
        [else (format "get64(data, ~a)" offv)]))

(define (kt-struct-value-size model f v)
  (define t (hash-ref f 'type))
  (cond [(= t 9) (format "~a.toByteArray(Charsets.UTF_8).size" v)]
        [(= t 12) (format "~a.size" v)]
        [(= t 11) (format "(if (~a == null) 0 else ~a.size(~a))" v (kt-struct-companion model f) v)]
        [(kt-struct-fixed32-type? t) "4"]
        [else "8"]))

(define (kt-struct-message model msg)
  (define type-name (kt-struct-type-name model msg))
  (define fp (kt-struct-fingerprint (hash-ref msg 'full-name)))
  (define fp-dec (if (>= fp 2147483648) (- fp 4294967296) fp))
  (define out (open-output-string))
  (fprintf out "object ~aStruct {\n" type-name)
  (fprintf out "    const val FINGERPRINT: Int = ~a\n\n" fp-dec)
  (fprintf out "    private val descriptor: ByteArray = java.util.HexFormat.of().parseHex(\"~a\")\n\n"
           (kt-descriptor-hex (hash-ref model 'descriptor-set #"")))
  (fprintf out "    fun size(m: ~a): Int = marshal(m).size\n\n" type-name)
  (fprintf out "    fun marshal(m: ~a): ByteArray = grpcdc.StructDc.encode(descriptor, \"~a\", m.marshalDc())\n\n"
           type-name (hash-ref msg 'full-name))
  (fprintf out "    fun unmarshal(data: ByteArray): ~a {\n        val m = ~a()\n        m.unmarshalDc(grpcdc.StructDc.decode(descriptor, \"~a\", data))\n        return m\n    }\n}\n"
           type-name type-name (hash-ref msg 'full-name))
  (get-output-string out))

(define (kt-struct-value-write model f v)
  (define t (hash-ref f 'type))
  (define out (open-output-string))
  (cond [(= t 9)
         (fprintf out "                val sb = ~a.toByteArray(Charsets.UTF_8); sb.copyInto(buf, vp); vp += sb.size\n" v)]
        [(= t 12)
         (fprintf out "                ~a.copyInto(buf, vp); vp += ~a.size\n" v v)]
        [(= t 11)
         (fprintf out "                if (~a != null) { val nb = ~a.marshal(~a); nb.copyInto(buf, vp); vp += nb.size }\n" v (kt-struct-companion model f) v)]
        [else
         (fprintf out "                run { val off = vp; ~a }; vp += ~a\n"
                  (kt-struct-scalar-encode f v) (if (kt-struct-fixed32-type? t) 4 8))])
  (get-output-string out))

(define (kt-struct-marshal-field model f off)
  (define kn (kt-struct-field-name f))
  (define t (hash-ref f 'type))
  (define out (open-output-string))
  (define mv (format "m.~a" kn))
  (cond [(kt-struct-map-entry model f)
         (define kf (kt-struct-map-key-field model f))
         (define vf (kt-struct-map-val-field model f))
         (fprintf out "        if (~a.isNotEmpty()) {\n            put32(buf, ~a, vp); put32(buf, ~a, ~a.size)\n" mv off (+ off 4) mv)
         (fprintf out "            val keys = ~a.keys.sorted()\n" mv)
         (fprintf out "            for (k in keys) {\n                val v = ~a.getValue(k)\n                put32(buf, vp, ~a); put32(buf, vp + 4, ~a); vp += 8\n"
                  mv (kt-struct-value-size model kf "k") (kt-struct-value-size model vf "v"))
         (display (kt-struct-value-write model kf "k") out)
         (display (kt-struct-value-write model vf "v") out)
         (fprintf out "            }\n        }\n")]
        [(= (hash-ref f 'label) 3)
         (cond [(member t '(9 12))
                (fprintf out "        if (~a.isNotEmpty()) {\n            put32(buf, ~a, vp); put32(buf, ~a, ~a.size)\n            var doff = vp + 8 * ~a.size\n            for (e in ~a) { put32(buf, vp, doff); put32(buf, vp + 4, ~a); doff += ~a; vp += 8 }\n            for (e in ~a) { ~a }\n        }\n"
                         mv off (+ off 4) mv mv mv
                         (if (= t 9) "e.toByteArray(Charsets.UTF_8).size" "e.size")
                         (if (= t 9) "e.toByteArray(Charsets.UTF_8).size" "e.size")
                         mv
                         (if (= t 9) "val sb = e.toByteArray(Charsets.UTF_8); sb.copyInto(buf, vp); vp += sb.size"
                             "e.copyInto(buf, vp); vp += e.size"))]
               [(= t 11)
                (fprintf out "        if (~a.isNotEmpty()) {\n            put32(buf, ~a, vp); put32(buf, ~a, ~a.size)\n            var doff = vp + 8 * ~a.size\n            for (e in ~a) { val es = ~a.size(e); put32(buf, vp, doff); put32(buf, vp + 4, es); doff += es; vp += 8 }\n            for (e in ~a) { val nb = ~a.marshal(e); nb.copyInto(buf, vp); vp += nb.size }\n        }\n"
                         mv off (+ off 4) mv mv mv (kt-struct-companion model f)
                         mv (kt-struct-companion model f))]
               [else
                (fprintf out "        if (~a.isNotEmpty()) {\n            put32(buf, ~a, vp); put32(buf, ~a, ~a.size)\n            for (e in ~a) { val off = vp; ~a; vp += ~a }\n        }\n"
                         mv off (+ off 4) mv
                         mv
                         (kt-struct-scalar-encode f "e")
                         (if (kt-struct-fixed32-type? t) 4 8))])]
        [(= t 11)
         (fprintf out "        val sv~a = ~a\n        if (sv~a != null) {\n            put32(buf, ~a, vp); put32(buf, ~a, ~a.size(sv~a))\n            val nb = ~a.marshal(sv~a); nb.copyInto(buf, vp); vp += nb.size\n        }\n"
                  off mv off off (+ off 4) (kt-struct-companion model f) off (kt-struct-companion model f) off)]
        [(member t '(9 12))
         (fprintf out "        if (~a.isNotEmpty()) {\n            put32(buf, ~a, vp); put32(buf, ~a, ~a)\n            ~a\n        }\n"
                  mv off (+ off 4)
                  (if (= t 9) (format "~a.toByteArray(Charsets.UTF_8).size" mv) (format "~a.size" mv))
                  (if (= t 9)
                      (format "val sb = ~a.toByteArray(Charsets.UTF_8); sb.copyInto(buf, vp); vp += sb.size" mv)
                      (format "~a.copyInto(buf, vp); vp += ~a.size" mv mv)))]
        [else
         (fprintf out "        run { val off = ~a; ~a }\n" off (kt-struct-scalar-encode f mv))])
  (get-output-string out))

(define (kt-struct-value-read/off model f target lenvar offv)
  (define t (hash-ref f 'type))
  (cond [(= t 9) (format "~a = String(data, ~a, ~a, Charsets.UTF_8)" target offv lenvar)]
        [(= t 12) (format "~a = data.copyOfRange(~a, ~a + ~a)" target offv offv lenvar)]
        [(= t 11) (format "if (~a > 0) { ~a = ~a.unmarshal(data.copyOfRange(~a, ~a + ~a)) } else { ~a = ~a() }"
                          lenvar target (kt-struct-companion model f) offv offv lenvar
                          target (kt-struct-simple-name (hash-ref f 'type-name)))]
        [else (format "~a = ~a" target (kt-struct-scalar-value/off model f offv))]))

(define (kt-struct-value-expr/off model f lenvar offv)
  (define t (hash-ref f 'type))
  (cond [(= t 9) (format "String(data, ~a, ~a, Charsets.UTF_8)" offv lenvar)]
        [(= t 12) (format "data.copyOfRange(~a, ~a + ~a)" offv offv lenvar)]
        [(= t 11) (format "if (~a > 0) ~a.unmarshal(data.copyOfRange(~a, ~a + ~a)) else ~a()"
                          lenvar (kt-struct-companion model f) offv offv lenvar
                          (kt-struct-simple-name (hash-ref f 'type-name)))]
        [else (kt-struct-scalar-value/off model f offv)]))

(define (kt-struct-decode-field model f foff)
  (define kn (kt-struct-field-name f))
  (define t (hash-ref f 'type))
  (define out (open-output-string))
  (define mv (format "m.~a" kn))
  (cond [(kt-struct-map-entry model f)
         (define kf (kt-struct-map-key-field model f))
         (define vf (kt-struct-map-val-field model f))
         (fprintf out "            val off = get32(data, ~a); val n = get32(data, ~a)\n" foff (+ foff 4))
         (fprintf out "            var p = off\n            for (i in 0 until n) {\n")
         (fprintf out "                check(data, p, 8)\n                val kl = get32(data, p); val vl = get32(data, p + 4); p += 8\n                check(data, p, kl + vl)\n")
         (fprintf out "                val k = run { val io = p; ~a }\n" (kt-struct-value-expr/off model kf "kl" "io"))
         (fprintf out "                val v = run { val io = p + kl; ~a }\n" (kt-struct-value-expr/off model vf "vl" "io"))
         (fprintf out "                ~a[k] = v\n                p += kl + vl\n            }\n            if (p > vend) { vend = p }\n" mv)]
        [(= (hash-ref f 'label) 3)
         (fprintf out "            val off = get32(data, ~a); val n = get32(data, ~a)\n" foff (+ foff 4))
         (cond [(member t '(9 12))
                (fprintf out "            for (i in 0 until n) {\n                val eo = get32(data, off + 8 * i); val el = get32(data, off + 8 * i + 4)\n                check(data, eo, el)\n                ~a.add(~a)\n                if (eo + el > vend) { vend = eo + el }\n            }\n"
                         mv (if (= t 9) "String(data, eo, el, Charsets.UTF_8)" "data.copyOfRange(eo, eo + el)"))]
               [(= t 11)
                (fprintf out "            for (i in 0 until n) {\n                val eo = get32(data, off + 8 * i); val el = get32(data, off + 8 * i + 4)\n                if (el > 0) {\n                    check(data, eo, el)\n                    ~a.add(~a.unmarshal(data.copyOfRange(eo, eo + el)))\n                    if (eo + el > vend) { vend = eo + el }\n                }\n            }\n"
                         mv (kt-struct-companion model f))]
               [else
                (define esz (if (kt-struct-fixed32-type? t) 4 8))
                (fprintf out "            check(data, off, n * ~a)\n            for (i in 0 until n) {\n                val eo = off + i * ~a\n                ~a.add(~a)\n            }\n            if (off + n * ~a > vend) { vend = off + n * ~a }\n"
                         esz esz mv (kt-struct-scalar-value/off model f "eo") esz esz)])]
        [(= t 11)
         (fprintf out "            val off = get32(data, ~a); val el = get32(data, ~a)\n" foff (+ foff 4))
         (fprintf out "            check(data, off, el)\n            ~a = ~a.unmarshal(data.copyOfRange(off, off + el))\n            if (off + el > vend) { vend = off + el }\n" mv (kt-struct-companion model f))]
        [(member t '(9 12))
         (fprintf out "            val off = get32(data, ~a); val el = get32(data, ~a)\n" foff (+ foff 4))
         (fprintf out "            check(data, off, el)\n")
         (if (= t 9)
             (fprintf out "            ~a = String(data, off, el, Charsets.UTF_8)\n" mv)
             (fprintf out "            ~a = data.copyOfRange(off, off + el)\n" mv))
         (fprintf out "            if (off + el > vend) { vend = off + el }\n")]
        [else
         (fprintf out "            val off = ~a\n            ~a = ~a\n" foff mv
                  (kt-struct-scalar-value/off model f "off"))])
  (get-output-string out))

(define (emit-kotlin-struct-files file-model params pkg)
  (if (equal? (hash-ref params 'struct_codec #f) "true")
      (let ()
        (define comps '())
        (define (emit-comp msg)
          (unless (hash-ref msg 'map-entry)
            (set! comps
                  (cons (cons (string-append (kt-struct-type-name file-model msg) "Struct.kt")
                              (string-append
                               "// @generated by protoc-gen-grpc-dc-kotlin. DO NOT EDIT.\n"
                               (format "// source: ~a\n\n" (hash-ref file-model 'name))
                               (format "package ~a\n\n" (if (string=? pkg "") "proto" pkg))
                               (kt-struct-message file-model msg)))
                        comps)))
          (for ([n (in-list (hash-ref msg 'nested))]) (emit-comp n)))
        (for ([m (in-list (hash-ref file-model 'messages))]) (emit-comp m))
        (reverse comps))
      '()))
