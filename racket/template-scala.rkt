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
  (define pb-file (emit-scala-pb-file file-model))
  (if pb-file (list stub pb-file) stub))
