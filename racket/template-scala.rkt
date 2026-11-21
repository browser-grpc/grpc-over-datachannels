#lang racket

;;; template-scala.rkt — emitter body spliced into
;;; protoc-gen-grpc-dc-scala.
;;;
;;; Generated stubs live in the proto package beside hand-written
;;; message types (marshalDc/unmarshalDc), mirroring the Kotlin
;;; stub: a sync client plus a scala.concurrent.Future surface
;;; (grpcdc.Futures), and a service trait + register function.
;;; Method names keep the proto spelling (Unary, ServerStream...).

(require "spec.rkt" "desc.rkt" "segments.rkt")
(provide emit-scala-file)

(define current-service (make-parameter ""))

(define (pascal sym) ; echo_service -> EchoService ; echo -> Echo
  (apply string-append
         (for/list ([part (in-list (string-split (symbol->string sym) "_"))])
           (if (string=? part "")
               ""
               (string-append (string (char-upcase (string-ref part 0)))
                              (substring part 1))))))


(define (scala-client-method m)
  (run-segments scala-client-method-program m "" #f
                (list (scala-client-stream-name (current-service) 'server-streaming (hash-ref m 'output))
                      (scala-client-stream-name (current-service) 'bidi (hash-ref m 'output)))))
(define (scala-future-method m)
  (run-segments scala-future-method-program m ""))
(define (scala-server-iface-method m)
  (run-segments scala-server-iface-method-program m "" #f (list (scala-ss-trait-name (current-service) (hash-ref m 'output))
                      (scala-pair-trait-name (current-service) 'client-streaming (hash-ref m 'input) (hash-ref m 'output) "ClientStreamServer")
                      (scala-pair-trait-name (current-service) 'bidi (hash-ref m 'input) (hash-ref m 'output) "BidiServer"))))
(define (scala-register-method m)
  (run-segments scala-register-method-program m "" #f (list (scala-ss-trait-name (current-service) (hash-ref m 'output))
                      (scala-pair-trait-name (current-service) 'client-streaming (hash-ref m 'input) (hash-ref m 'output) "ClientStreamServer")
                      (scala-pair-trait-name (current-service) 'bidi (hash-ref m 'input) (hash-ref m 'output) "BidiServer"))))
(define (scala-server-async-iface-method m)
  (run-segments scala-server-async-iface-method-program m "" #f (list (scala-ss-trait-name (current-service) (hash-ref m 'output))
                      (scala-pair-trait-name (current-service) 'client-streaming (hash-ref m 'input) (hash-ref m 'output) "ClientStreamServer")
                      (scala-pair-trait-name (current-service) 'bidi (hash-ref m 'input) (hash-ref m 'output) "BidiServer"))))
(define (scala-server-async-adapter-method m)
  (run-segments scala-server-async-adapter-method-program m "" #f (list (scala-ss-trait-name (current-service) (hash-ref m 'output))
                      (scala-pair-trait-name (current-service) 'client-streaming (hash-ref m 'input) (hash-ref m 'output) "ClientStreamServer")
                      (scala-pair-trait-name (current-service) 'bidi (hash-ref m 'input) (hash-ref m 'output) "BidiServer"))))
(define current-methods (make-parameter '()))

;; Helper stream traits/classes are typed by message type. While a
;; service uses one type for a given role, helpers keep their
;; historical names (<Svc>ServerStreamServer etc.); heterogeneous
;; services get one helper per type (<Svc><Type>ServerStreamServer
;; etc.), so generated code stays correct instead of silently
;; typing every stream with the first method's messages.
(define (kind-outputs kind)
  (remove-duplicates
   (map (lambda (m) (hash-ref m 'output))
        (filter (lambda (m) (eq? (hash-ref m 'kind) kind)) (current-methods)))))

(define (kind-pairs kind)
  (remove-duplicates
   (map (lambda (m) (cons (hash-ref m 'input) (hash-ref m 'output)))
        (filter (lambda (m) (eq? (hash-ref m 'kind) kind)) (current-methods)))))

(define (scala-ss-trait-name svc out)
  (if (<= (length (kind-outputs 'server-streaming)) 1)
      (format "~aServerStreamServer" svc)
      (format "~a~aServerStreamServer" svc out)))

(define (scala-pair-trait-name svc kind in out suffix)
  (if (<= (length (kind-pairs kind)) 1)
      (format "~a~a" svc suffix)
      (format "~a~a~a~a" svc in out suffix)))

(define (scala-client-stream-name svc kind out)
  (define suffix (if (eq? kind 'server-streaming) "ServerStreamStream" "BidiStream"))
  (if (<= (length (kind-outputs kind)) 1)
      (format "~a~a" svc suffix)
      (format "~a~a~a" svc out suffix)))

(define (scala-service svc)
  (run-segments scala-service-program svc (hash-ref svc 'name)))
(define sc-pb-varint-types varint-scalar-types)
;; type -> (size kind) ; kind: double float fixed32 fixed64
(define sc-pb-fixed (map (lambda (e) (list (first e) (second e) (string->symbol (third e)))) (fixed-scalar-table 'scala)))

(define (sc-pb-camel s)
  (define parts (string-split s "_"))
  (if (null? parts)
      s
      (apply string-append (car parts)
             (map (lambda (p) (if (string=? p "") "" (string-append (string (char-upcase (string-ref p 0))) (substring p 1))))
                  (cdr parts)))))

;; Scala hard keywords: a field named e.g. `type` must be
;; backtick-quoted everywhere it is referenced.
(define sc-pb-keywords
  '("abstract" "case" "catch" "class" "def" "do" "else" "extends"
    "false" "final" "finally" "for" "forSome" "if" "implicit"
    "import" "lazy" "match" "new" "null" "object" "override"
    "package" "private" "protected" "return" "sealed" "super"
    "this" "throw" "trait" "try" "true" "type" "val" "var"
    "while" "with" "yield"))

(define (sc-pb-field-name f)
  (define jn (hash-ref f 'json-name ""))
  (define n (if (and jn (not (string=? jn ""))) jn (sc-pb-camel (hash-ref f 'name))))
  (if (member n sc-pb-keywords) (string-append "`" n "`") n))

(define (sc-pb-flat pkg full)
  (define rel (if (and pkg (not (string=? pkg "")) (string-prefix? full (string-append pkg ".")))
                  (substring full (add1 (string-length pkg)))
                  full))
  (string-join (string-split rel ".") "_"))

(define (sc-pb-resolve model type-name)
  (hash-ref (hash-ref model 'types) type-name
            (lambda () (error 'emit-scala-pb-file "unresolved type ~a" type-name))))

(define (sc-pb-entry-ref model entry)
  (define flat
    (sc-pb-flat (hash-ref entry 'pkg)
                (if (eq? (hash-ref entry 'kind) 'enum)
                    (let ([e (hash-ref entry 'enum)])
                      (if (hash-ref entry 'msg)
                          (format "~a.~a" (hash-ref (hash-ref entry 'msg) 'full-name) (hash-ref e 'name))
                          (format "~a.~a" (hash-ref entry 'pkg) (hash-ref e 'name))))
                    (hash-ref (hash-ref entry 'msg) 'full-name))))
  (define simple
    (if (eq? (hash-ref entry 'kind) 'enum)
        (hash-ref (hash-ref entry 'enum) 'name)
        flat))
  (if (or (eq? (hash-ref entry 'kind) 'map)
          (equal? (hash-ref entry 'file) (hash-ref model 'name)))
      (if (eq? (hash-ref entry 'kind) 'enum)
          (sc-pb-flat (hash-ref entry 'pkg)
                      (if (hash-ref entry 'msg)
                          (format "~a.~a" (hash-ref (hash-ref entry 'msg) 'full-name) simple)
                          (format "~a.~a" (hash-ref entry 'pkg) simple)))
          flat)
      (format "~a.~a" (hash-ref entry 'pkg) simple)))

(define (sc-pb-scalar-type f) (scalar-type-entry 'scala (hash-ref f 'type)))

(define (sc-pb-elem-type model f)
  (run-segments sc-pb-elem-type-program f "" model))
(define (sc-pb-type model f)
  (run-segments sc-pb-type-program f "" model))
(define (sc-pb-explicit-literal model f)
  (define lit (run-segments sc-pb-explicit-literal-program f "" model))
  (and (not (string=? lit "")) lit))
(define (sc-pb-default model f)
  (run-segments sc-pb-default-program f "" model))
(define (sc-pb-varint-expr f v)
  (run-segments sc-pb-varint-expr-program f "" #f (list v)))
(define (sc-pb-varint-decode f v)
  (run-segments sc-pb-varint-decode-program f "" #f (list v)))
(define (sc-pb-fixed-encode-expr f v)
  (run-segments sc-pb-fixed-encode-program f "" #f (list (current-pb-obj) v)))
(define (sc-pb-fixed-decode-expr f src)
  (run-segments sc-pb-fixed-decode-program f "" #f (list (current-pb-obj) src)))
(define current-pb-obj (make-parameter "Pb"))

(define (sc-pb-nonzero f v)
  (run-segments sc-pb-nonzero-program f "" #f (list v)))
(define (sc-pb-encode-singular model f v indent)
  (run-segments sc-pb-encode-singular-program f "" model (list (current-pb-obj) v indent)))
(define (sc-pb-encode-field model f)
  (run-segments sc-pb-encode-field-program f "" model (list (current-pb-obj))))
(define (sc-pb-decode-singular model f target src indent)
  (run-segments sc-pb-decode-singular-program f "" model (list (current-pb-obj) target src indent)))
(define (sc-pb-oneof-clearing model f)
  (run-segments sc-pb-oneof-clearing-program f "" model))
(define (sc-pb-decode-case model f)
  (run-segments sc-pb-decode-case-program f "" model (list (current-pb-obj))))
(define (sc-pb-map-helpers model entry)
  (run-segments sc-pb-map-helpers-program entry "" model (list (current-pb-obj))))
(define (sc-pb-support obj)
  (string-append
   (format "object ~a {\n" obj)
   "  class Writer {\n"
   "    private val out = new java.io.ByteArrayOutputStream()\n\n"
   "    def varint(value: Long): Unit = {\n      var v = value\n      while ((v & -0x80L) != 0L) {\n        out.write(((v & 0x7f) | 0x80).toInt)\n        v = v >>> 7\n      }\n      out.write(v.toInt)\n    }\n\n"
   "    def tag(field: Int, wire: Int): Unit = {\n      varint(((field << 3) | wire).toLong)\n    }\n\n"
   "    def bytesField(field: Int, payload: Array[Byte]): Unit = {\n      tag(field, 2)\n      varint(payload.length.toLong)\n      out.write(payload)\n    }\n\n"
   "    def stringField(field: Int, value: String): Unit = {\n      if (value.nonEmpty) {\n        bytesField(field, value.getBytes(java.nio.charset.StandardCharsets.UTF_8))\n      }\n    }\n\n"
   "    def fixed(field: Int, wire: Int, payload: Array[Byte]): Unit = {\n      tag(field, wire)\n      out.write(payload)\n    }\n\n"
   "    def raw(payload: Array[Byte]): Unit = {\n      out.write(payload)\n    }\n\n"
   "    def toBytes: Array[Byte] = out.toByteArray\n  }\n\n"
   "  def varintBytes(value: Long): Array[Byte] = {\n    val w = new Writer()\n    w.varint(value)\n    w.toBytes\n  }\n\n"
   "  def int32BytesLE(value: Int): Array[Byte] = {\n    Array((value & 0xff).toByte, ((value >> 8) & 0xff).toByte, ((value >> 16) & 0xff).toByte, ((value >> 24) & 0xff).toByte)\n  }\n\n"
   "  def int64BytesLE(value: Long): Array[Byte] = {\n    val out = new Array[Byte](8)\n    var i = 0\n    while (i < 8) {\n      out(i) = ((value >> (8 * i)) & 0xffL).toByte\n      i += 1\n    }\n    out\n  }\n\n"
   "  def toInt32LE(bytes: Array[Byte], off: Int): Int = {\n    (bytes(off) & 0xff) | ((bytes(off + 1) & 0xff) << 8) | ((bytes(off + 2) & 0xff) << 16) | ((bytes(off + 3) & 0xff) << 24)\n  }\n\n"
   "  def toInt64LE(bytes: Array[Byte], off: Int): Long = {\n    var result = 0L\n    var i = 0\n    while (i < 8) {\n      result |= (bytes(off + i) & 0xffL) << (8 * i)\n      i += 1\n    }\n    result\n  }\n\n"
   "  class Field(val number: Int, val wire: Int, val varintValue: Long, val bytesValue: Array[Byte], val fixedValue: Array[Byte], val rawValue: Array[Byte])\n\n"
   "  class Reader(private val buf: Array[Byte]) {\n"
   "    private var pos = 0\n\n"
   "    def done: Boolean = pos >= buf.length\n\n"
   "    def varint(): Long = {\n      var result = 0L\n      var shift = 0\n      while (true) {\n        if (pos >= buf.length) {\n          throw new IllegalArgumentException(\"truncated varint\")\n        }\n        val b = buf(pos).toInt & 0xff\n        pos += 1\n        result = result | ((b & 0x7f).toLong << shift)\n        if ((b & 0x80) == 0) {\n          return result\n        }\n        shift += 7\n        if (shift >= 70) {\n          throw new IllegalArgumentException(\"varint too long\")\n        }\n      }\n      0L\n    }\n\n"
   "    def take(n: Int): Array[Byte] = {\n      if (pos + n > buf.length) {\n        throw new IllegalArgumentException(\"truncated field\")\n      }\n      val value = buf.slice(pos, pos + n)\n      pos += n\n      value\n    }\n\n"
   "    def next(): Field = {\n      if (done) {\n        return null\n      }\n      val start = pos\n      val tag = varint()\n      val number = (tag >>> 3).toInt\n      val wire = (tag & 7).toInt\n      wire match {\n        case 0 =>\n          val v = varint()\n          new Field(number, wire, v, Array.empty[Byte], Array.empty[Byte], buf.slice(start, pos))\n        case 2 =>\n          val n = varint().toInt\n          new Field(number, wire, 0L, take(n), Array.empty[Byte], buf.slice(start, pos))\n        case 1 => new Field(number, wire, 0L, Array.empty[Byte], take(8), buf.slice(start, pos))\n        case 5 => new Field(number, wire, 0L, Array.empty[Byte], take(4), buf.slice(start, pos))\n        case _ => throw new IllegalArgumentException(\"bad wire type\")\n      }\n    }\n  }\n"))

(define (sc-pb-message-class model msg)
  (run-segments sc-pb-message-program msg "" model (list (current-pb-obj))))
(define (sc-pb-enum model e)
  (run-segments sc-pb-enum-program e "" model
                (list (if (string=? (hash-ref model 'package) "")
                          (hash-ref e 'name)
                          (format "~a.~a" (hash-ref model 'package) (hash-ref e 'name))))))
(define (emit-scala-pb-file file-model)
  (and (hash-has-key? file-model 'messages)
       (hash-has-key? file-model 'types)
       (emit-scala-pb-file/inner file-model)))

(define (emit-scala-pb-file/inner file-model)
  (define messages (hash-ref file-model 'messages))
  (define enums (hash-ref file-model 'enums))
  (and (or (pair? messages) (pair? enums))
       (let ()
         (define base (path->string (path-replace-extension
                                     (file-name-from-path (hash-ref file-model 'name)) "")))
         (define obj (string-append (pascal (string->symbol base)) "Pb"))
         (define pkg (hash-ref file-model 'package))
         (define seen-maps (mutable-set))
         (define helpers '())
         (define (collect msg)
           (for ([f (in-list (hash-ref msg 'fields))])
             (when (= (hash-ref f 'type) 11)
               (define e (sc-pb-resolve file-model (hash-ref f 'type-name)))
               (when (and (eq? (hash-ref e 'kind) 'map)
                          (not (set-member? seen-maps (hash-ref (hash-ref e 'msg) 'full-name))))
                 (set-add! seen-maps (hash-ref (hash-ref e 'msg) 'full-name))
                 (set! helpers (cons (sc-pb-map-helpers file-model e) helpers)))))
           (for ([n (in-list (hash-ref msg 'nested))]) (collect n)))
         (parameterize ([current-pb-obj obj])
           (for ([m (in-list messages)]) (collect m))
           (define content
             (string-append
              "// @generated by protoc-gen-grpc-dc-scala. DO NOT EDIT.\n"
              (if (string=? pkg "") "" (format "package ~a\n\n" pkg))
              (sc-pb-support obj)
              (apply string-append helpers)
              "}\n\n"
              (apply string-append (map (lambda (e) (sc-pb-enum file-model e)) enums))
              (apply string-append
                     (map (lambda (m) (sc-pb-message-class file-model m))
                          (filter (lambda (m) (not (hash-ref m 'map-entry))) messages)))))
           (cons (string-append (pascal (string->symbol base)) "Messages.scala") content)))))

;; Stub type reference for a method input/output: the simple class
;; name when the message lives in the stub file's own package,
;; fully qualified otherwise (Scala cannot resolve a simple name
;; across packages).
(define (scala-qualify-type pkg simple full)
  (cond [(or (not full) (string=? pkg "")
             (string-prefix? full (string-append pkg ".")))
         simple]
        [else full]))

(define (scala-qualify-services pkg services)
  (for/list ([svc (in-list services)])
    (hash-set svc 'methods
              (for/list ([m (in-list (hash-ref svc 'methods))])
                (hash-set* m
                           'input (scala-qualify-type pkg (hash-ref m 'input)
                                                      (hash-ref m 'input-full #f))
                           'output (scala-qualify-type pkg (hash-ref m 'output)
                                                       (hash-ref m 'output-full #f)))))))

(define (emit-scala-file file-model params)
  (define base (path->string (path-replace-extension
                              (file-name-from-path (hash-ref file-model 'name)) "")))
  (define obj-name (string-append (pascal (string->symbol base)) "GrpcDc"))
  (define pkg (hash-ref file-model 'package))
  (define stub
    (cons (string-append obj-name ".scala")
        (string-append
         "// @generated by protoc-gen-grpc-dc-scala. DO NOT EDIT.\n"
         (format "// source: ~a\n" (hash-ref file-model 'name))
         (format "package ~a\n\n" pkg)
         "/** Generated gRPC-over-DataChannels stubs. */\n"
         (format "object ~a {\n" obj-name)
         ;; trace=hooks: delegate the tracer registrar to grpcdc.Tracing.
         (if (equal? (hash-ref params 'trace #f) "hooks")
             (string-append
              "  // Tracing (trace=hooks@@TRACING_BETA@@): register an observer via setTracer.\n"
              "  def setTracer(t: grpcdc.Tracing.Tracer): Unit = grpcdc.Tracing.setTracer(t)\n"
              "  def setTraceFilter(patterns: String): Unit = grpcdc.Tracing.setTraceFilter(patterns)\n"
              (let ([methods (hash-ref params 'trace_methods #f)])
                (if methods
                    (format "  grpcdc.Tracing.setTraceFilter(~s)\n" methods)
                    ""))
              "\n")
             "")
         (apply string-append
                (map scala-service
                     (scala-qualify-services pkg (hash-ref file-model 'services))))
         "}\n")))
  (define pb-file (parameterize ([seg-struct-codec (equal? (hash-ref params 'struct_codec #f) "true")])
                    (emit-scala-pb-file file-model)))
  (define struct-files (emit-scala-struct-files file-model params pkg))
  (if (null? struct-files)
      (if pb-file (list stub pb-file) stub)
      (append (list stub pb-file) struct-files)))

;; ------------------------------------------------------------------
;; Struct codec (struct_codec=true): <Msg>Struct object per message
;; with the packed layout from SPEC.md (byte-identical to the
;; Go/Rust/Java/Kotlin struct codecs; verified by conformance/struct).
(define (sc-descriptor-hex bstr)
  (apply string-append
         (for/list ([b (in-bytes bstr)])
           (let ([h (format "~x" b)])
             (if (= (string-length h) 1) (string-append "0" h) h)))))

(define (sc-struct-fingerprint s)
  (for/fold ([h 2166136261]) ([c (in-string s)])
    (modulo (* (bitwise-xor h (char->integer c)) 16777619) 4294967296)))

(define (sc-struct-fixed32-type? t) (member t '(2 7 15)))
(define (sc-struct-fixed64-type? t) (member t '(1 6 16)))

(define (sc-struct-slot-size f)
  (if (sc-struct-fixed32-type? (hash-ref f 'type)) 4 8))

(define (sc-struct-sorted-fields msg)
  (sort (hash-ref msg 'fields) < #:key (lambda (f) (hash-ref f 'number))))

(define (sc-struct-map-entry model f)
  (and (= (hash-ref f 'type) 11)
       (let ([e (sc-pb-resolve model (hash-ref f 'type-name))])
         (and (eq? (hash-ref e 'kind) 'map) e))))

(define (sc-struct-map-key-field model f)
  (define em (hash-ref (sc-struct-map-entry model f) 'msg))
  (findf (lambda (x) (= (hash-ref x 'number) 1)) (hash-ref em 'fields)))
(define (sc-struct-map-val-field model f)
  (define em (hash-ref (sc-struct-map-entry model f) 'msg))
  (findf (lambda (x) (= (hash-ref x 'number) 2)) (hash-ref em 'fields)))

(define (sc-struct-type-name model msg)
  (sc-pb-flat (hash-ref model 'package) (hash-ref msg 'full-name)))

(define (sc-struct-companion model f)
  (define e (sc-pb-resolve model (hash-ref f 'type-name)))
  (string-append (sc-pb-flat (hash-ref model 'package)
                             (hash-ref (hash-ref e 'msg) 'full-name)) "Struct"))

(define (sc-struct-zero f)
  (case (hash-ref f 'type)
    [(1) "0.0"] [(2) "0.0f"] [(3 4 6 16 18) "0L"] [else "0"]))

(define (sc-struct-present f sn)
  (define t (hash-ref f 'type))
  (cond [(= (hash-ref f 'label) 3) (format "m.~a.nonEmpty" sn)]
        [(= t 11) (format "m.~a != null" sn)]
        [(= t 9) (format "m.~a.nonEmpty" sn)]
        [(= t 12) (format "m.~a.nonEmpty" sn)]
        [(= t 8) (format "m.~a" sn)]
        [else (format "m.~a != ~a" sn (sc-struct-zero f))]))

(define (sc-struct-scalar-encode f v)
  (define t (hash-ref f 'type))
  (cond [(sc-struct-fixed32-type? t)
         (if (= t 2)
             (format "put32(buf, off, java.lang.Float.floatToIntBits(~a))" v)
             (format "put32(buf, off, ~a)" v))]
        [(sc-struct-fixed64-type? t)
         (if (= t 1)
             (format "put64(buf, off, java.lang.Double.doubleToLongBits(~a))" v)
             (format "put64(buf, off, ~a)" v))]
        [(= t 8) (format "buf(off) = (if (~a) 1 else 0).toByte" v)]
        [(= t 14) (format "put64(buf, off, ~a.toLong)" v)]
        [(member t '(3 4 6 16 18)) (format "put64(buf, off, ~a)" v)]
        [else (format "put64(buf, off, ~a.toLong)" v)]))

(define (sc-struct-scalar-value/off model f offv)
  (define t (hash-ref f 'type))
  (cond [(sc-struct-fixed32-type? t)
         (if (= t 2)
             (format "java.lang.Float.intBitsToFloat(get32(data, ~a))" offv)
             (format "get32(data, ~a)" offv))]
        [(sc-struct-fixed64-type? t)
         (if (= t 1)
             (format "java.lang.Double.longBitsToDouble(get64(data, ~a))" offv)
             (format "get64(data, ~a)" offv))]
        [(= t 8) (format "(data(~a) != 0)" offv)]
        [(= t 14) (format "get64(data, ~a).toInt" offv)]
        [(member t '(3 4 6 16 18)) (format "get64(data, ~a)" offv)]
        [else (format "get64(data, ~a).toInt" offv)]))

(define (sc-struct-value-size model f v)
  (define t (hash-ref f 'type))
  (cond [(= t 9) (format "~a.getBytes(java.nio.charset.StandardCharsets.UTF_8).length" v)]
        [(= t 12) (format "~a.length" v)]
        [(= t 11) (format "(if (~a == null) 0 else ~a.size(~a))" v (sc-struct-companion model f) v)]
        [(sc-struct-fixed32-type? t) "4"]
        [else "8"]))

(define (sc-struct-message model msg)
  (define type-name (sc-struct-type-name model msg))
  (define fp (sc-struct-fingerprint (hash-ref msg 'full-name)))
  (define fp-dec (if (>= fp 2147483648) (- fp 4294967296) fp))
  (define out (open-output-string))
  (fprintf out "object ~aStruct {\n" type-name)
  (fprintf out "  final val FINGERPRINT: Int = ~a\n\n" fp-dec)
  (fprintf out "  private val descriptor: Array[Byte] = java.util.HexFormat.of().parseHex(\"~a\")\n\n"
           (sc-descriptor-hex (hash-ref model 'descriptor-set #"")))
  (fprintf out "  def size(m: ~a): Int = marshal(m).length\n\n" type-name)
  (fprintf out "  def marshal(m: ~a): Array[Byte] = grpcdc.StructDc.encode(descriptor, \"~a\", m.marshalDc())\n\n"
           type-name (hash-ref msg 'full-name))
  (fprintf out "  def unmarshal(data: Array[Byte]): ~a = {\n    val m = new ~a()\n    m.unmarshalDc(grpcdc.StructDc.decode(descriptor, \"~a\", data))\n    m\n  }\n}\n"
           type-name type-name (hash-ref msg 'full-name))
  (get-output-string out))

(define (sc-struct-value-write model f v)
  (define t (hash-ref f 'type))
  (define out (open-output-string))
  (cond [(= t 9)
         (fprintf out "                val sb = ~a.getBytes(java.nio.charset.StandardCharsets.UTF_8); System.arraycopy(sb, 0, buf, vp, sb.length); vp += sb.length\n" v)]
        [(= t 12)
         (fprintf out "                System.arraycopy(~a, 0, buf, vp, ~a.length); vp += ~a.length\n" v v v)]
        [(= t 11)
         (fprintf out "                if (~a != null) { val nb = ~a.marshal(~a); System.arraycopy(nb, 0, buf, vp, nb.length); vp += nb.length }\n" v (sc-struct-companion model f) v)]
        [else
         (fprintf out "                locally { val off = vp; ~a }; vp += ~a\n"
                  (sc-struct-scalar-encode f v) (if (sc-struct-fixed32-type? t) 4 8))])
  (get-output-string out))

(define (sc-struct-marshal-field model f off)
  (define sn (sc-pb-field-name f))
  (define t (hash-ref f 'type))
  (define out (open-output-string))
  (define mv (format "m.~a" sn))
  (cond [(sc-struct-map-entry model f)
         (define kf (sc-struct-map-key-field model f))
         (define vf (sc-struct-map-val-field model f))
         (fprintf out "    if (~a.nonEmpty) {\n      put32(buf, ~a, vp); put32(buf, ~a, ~a.size)\n" mv off (+ off 4) mv)
         (fprintf out "      val keys = ~a.keys.toList.sorted\n" mv)
         (fprintf out "      for (k <- keys) {\n        val v = ~a(k)\n        put32(buf, vp, ~a); put32(buf, vp + 4, ~a); vp += 8\n"
                  mv (sc-struct-value-size model kf "k") (sc-struct-value-size model vf "v"))
         (display (sc-struct-value-write model kf "k") out)
         (display (sc-struct-value-write model vf "v") out)
         (fprintf out "      }\n    }\n")]
        [(= (hash-ref f 'label) 3)
         (cond [(member t '(9 12))
                (fprintf out "    if (~a.nonEmpty) {\n      put32(buf, ~a, vp); put32(buf, ~a, ~a.size)\n      var doff = vp + 8 * ~a.size\n      for (e <- ~a) { put32(buf, vp, doff); put32(buf, vp + 4, ~a); doff += ~a; vp += 8 }\n      for (e <- ~a) { ~a }\n    }\n"
                         mv off (+ off 4) mv mv mv
                         (if (= t 9) "e.getBytes(java.nio.charset.StandardCharsets.UTF_8).length" "e.length")
                         (if (= t 9) "e.getBytes(java.nio.charset.StandardCharsets.UTF_8).length" "e.length")
                         mv
                         (if (= t 9) "val sb = e.getBytes(java.nio.charset.StandardCharsets.UTF_8); System.arraycopy(sb, 0, buf, vp, sb.length); vp += sb.length"
                             "System.arraycopy(e, 0, buf, vp, e.length); vp += e.length"))]
               [(= t 11)
                (fprintf out "    if (~a.nonEmpty) {\n      put32(buf, ~a, vp); put32(buf, ~a, ~a.size)\n      var doff = vp + 8 * ~a.size\n      for (e <- ~a) { val es = ~a.size(e); put32(buf, vp, doff); put32(buf, vp + 4, es); doff += es; vp += 8 }\n      for (e <- ~a) { val nb = ~a.marshal(e); System.arraycopy(nb, 0, buf, vp, nb.length); vp += nb.length }\n    }\n"
                         mv off (+ off 4) mv mv mv (sc-struct-companion model f)
                         mv (sc-struct-companion model f))]
               [else
                (fprintf out "    if (~a.nonEmpty) {\n      put32(buf, ~a, vp); put32(buf, ~a, ~a.size)\n      for (e <- ~a) { val off = vp; ~a; vp += ~a }\n    }\n"
                         mv off (+ off 4) mv
                         mv
                         (sc-struct-scalar-encode f "e")
                         (if (sc-struct-fixed32-type? t) 4 8))])]
        [(= t 11)
         (fprintf out "    if (~a != null) {\n      put32(buf, ~a, vp); put32(buf, ~a, ~a.size(~a))\n      val nb = ~a.marshal(~a); System.arraycopy(nb, 0, buf, vp, nb.length); vp += nb.length\n    }\n"
                  mv off (+ off 4) (sc-struct-companion model f) mv (sc-struct-companion model f) mv)]
        [(member t '(9 12))
         (fprintf out "    if (~a.nonEmpty) {\n      put32(buf, ~a, vp); put32(buf, ~a, ~a)\n      ~a\n    }\n"
                  mv off (+ off 4)
                  (if (= t 9) (format "~a.getBytes(java.nio.charset.StandardCharsets.UTF_8).length" mv) (format "~a.length" mv))
                  (if (= t 9)
                      (format "val sb = ~a.getBytes(java.nio.charset.StandardCharsets.UTF_8); System.arraycopy(sb, 0, buf, vp, sb.length); vp += sb.length" mv)
                      (format "System.arraycopy(~a, 0, buf, vp, ~a.length); vp += ~a.length" mv mv mv)))]
        [else
         (fprintf out "    locally { val off = ~a; ~a }\n" off (sc-struct-scalar-encode f mv))])
  (get-output-string out))

(define (sc-struct-value-expr/off model f lenvar offv)
  (define t (hash-ref f 'type))
  (cond [(= t 9) (format "new String(data, ~a, ~a, java.nio.charset.StandardCharsets.UTF_8)" offv lenvar)]
        [(= t 12) (format "java.util.Arrays.copyOfRange(data, ~a, ~a + ~a)" offv offv lenvar)]
        [(= t 11) (format "if (~a > 0) ~a.unmarshal(java.util.Arrays.copyOfRange(data, ~a, ~a + ~a)) else new ~a()"
                          lenvar (sc-struct-companion model f) offv offv lenvar
                          (sc-pb-flat (hash-ref model 'package)
                                      (hash-ref (hash-ref (sc-pb-resolve model (hash-ref f 'type-name)) 'msg) 'full-name)))]
        [else (sc-struct-scalar-value/off model f offv)]))

(define (sc-struct-decode-field model f foff)
  (define sn (sc-pb-field-name f))
  (define t (hash-ref f 'type))
  (define out (open-output-string))
  (define mv (format "m.~a" sn))
  (cond [(sc-struct-map-entry model f)
         (define kf (sc-struct-map-key-field model f))
         (define vf (sc-struct-map-val-field model f))
         (fprintf out "      val off = get32(data, ~a); val n = get32(data, ~a)\n" foff (+ foff 4))
         (fprintf out "      var p = off\n      for (i <- 0 until n) {\n")
         (fprintf out "        check(data, p, 8)\n        val kl = get32(data, p); val vl = get32(data, p + 4); p += 8\n        check(data, p, kl + vl)\n")
         (fprintf out "        val k = { val io = p; ~a }\n" (sc-struct-value-expr/off model kf "kl" "io"))
         (fprintf out "        val v = { val io = p + kl; ~a }\n" (sc-struct-value-expr/off model vf "vl" "io"))
         (fprintf out "        ~a = ~a + (k -> v)\n        p += kl + vl\n      }\n      if (p > vend) { vend = p }\n" mv mv)]
        [(= (hash-ref f 'label) 3)
         (fprintf out "      val off = get32(data, ~a); val n = get32(data, ~a)\n" foff (+ foff 4))
         (cond [(member t '(9 12))
                (fprintf out "      for (i <- 0 until n) {\n        val eo = get32(data, off + 8 * i); val el = get32(data, off + 8 * i + 4)\n        check(data, eo, el)\n        ~a = ~a :+ ~a\n        if (eo + el > vend) { vend = eo + el }\n      }\n"
                         mv mv (if (= t 9) "new String(data, eo, el, java.nio.charset.StandardCharsets.UTF_8)" "java.util.Arrays.copyOfRange(data, eo, eo + el)"))]
               [(= t 11)
                (fprintf out "      for (i <- 0 until n) {\n        val eo = get32(data, off + 8 * i); val el = get32(data, off + 8 * i + 4)\n        if (el > 0) {\n          check(data, eo, el)\n          ~a = ~a :+ ~a.unmarshal(java.util.Arrays.copyOfRange(data, eo, eo + el))\n          if (eo + el > vend) { vend = eo + el }\n        }\n      }\n"
                         mv mv (sc-struct-companion model f))]
               [else
                (define esz (if (sc-struct-fixed32-type? t) 4 8))
                (fprintf out "      check(data, off, n * ~a)\n      for (i <- 0 until n) {\n        val eo = off + i * ~a\n        ~a = ~a :+ ~a\n      }\n      if (off + n * ~a > vend) { vend = off + n * ~a }\n"
                         esz esz mv mv (sc-struct-scalar-value/off model f "eo") esz esz)])]
        [(= t 11)
         (fprintf out "      val off = get32(data, ~a); val el = get32(data, ~a)\n" foff (+ foff 4))
         (fprintf out "      check(data, off, el)\n      ~a = ~a.unmarshal(java.util.Arrays.copyOfRange(data, off, off + el))\n      if (off + el > vend) { vend = off + el }\n" mv (sc-struct-companion model f))]
        [(member t '(9 12))
         (fprintf out "      val off = get32(data, ~a); val el = get32(data, ~a)\n" foff (+ foff 4))
         (fprintf out "      check(data, off, el)\n")
         (if (= t 9)
             (fprintf out "      ~a = new String(data, off, el, java.nio.charset.StandardCharsets.UTF_8)\n" mv)
             (fprintf out "      ~a = java.util.Arrays.copyOfRange(data, off, off + el)\n" mv))
         (fprintf out "      if (off + el > vend) { vend = off + el }\n")]
        [else
         (fprintf out "      val off = ~a\n      ~a = ~a\n" foff mv
                  (sc-struct-scalar-value/off model f "off"))])
  (get-output-string out))

(define (emit-scala-struct-files file-model params pkg)
  (if (equal? (hash-ref params 'struct_codec #f) "true")
      (let ()
        (define comps '())
        (define (emit-comp msg)
          (unless (hash-ref msg 'map-entry)
            (set! comps
                  (cons (cons (string-append (sc-struct-type-name file-model msg) "Struct.scala")
                              (string-append
                               "// @generated by protoc-gen-grpc-dc-scala. DO NOT EDIT.\n"
                               (format "// source: ~a\n\n" (hash-ref file-model 'name))
                               (format "package ~a\n\n" (if (string=? pkg "") "proto" pkg))
                               (sc-struct-message file-model msg)))
                        comps)))
          (for ([n (in-list (hash-ref msg 'nested))]) (emit-comp n)))
        (for ([m (in-list (hash-ref file-model 'messages))]) (emit-comp m))
        (reverse comps))
      '()))
