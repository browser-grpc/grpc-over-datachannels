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
              "// Tracing (trace=hooks): register an observer via setTracer.\n"
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
  (define pb-file (emit-kotlin-pb-file file-model))
  (if pb-file (list stub pb-file) stub))

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
