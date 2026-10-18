#lang racket

;;; template-scala.rkt — emitter body spliced into
;;; protoc-gen-grpc-dc-scala.
;;;
;;; Generated stubs live in the proto package beside hand-written
;;; message types (marshalDc/unmarshalDc), mirroring the Kotlin
;;; stub: a sync client plus a scala.concurrent.Future surface
;;; (grpcdc.Futures), and a service trait + register function.
;;; Method names keep the proto spelling (Unary, ServerStream...).

(require "spec.rkt" "desc.rkt")
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
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define path (hash-ref m 'path))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(unary)
     (format (string-append
              "        def ~a(req: ~a, metadata: Map[String, String] = null, timeout: java.time.Duration = null): ~a = {\n"
              "            val resp = new ~a()\n"
              "            channel.unary(~s, req, resp, metadata, timeout)\n"
              "            resp\n"
              "        }\n\n")
             name req resp resp path)]
    [(server-streaming)
     (format (string-append
              "        def ~a(req: ~a, metadata: Map[String, String] = null, timeout: java.time.Duration = null): ~a = {\n"
              "            new ~a(channel.serverStream(~s, req, metadata, timeout))\n"
              "        }\n\n")
             name req (scala-client-stream-name svc 'server-streaming resp)
             (scala-client-stream-name svc 'server-streaming resp) path)]
    [(client-streaming)
     (format (string-append
              "        def ~a(reqs: List[~a], metadata: Map[String, String] = null, timeout: java.time.Duration = null): ~a = {\n"
              "            val resp = new ~a()\n"
              "            channel.clientStreamCall(~s, reqs, resp, metadata, timeout)\n"
              "            resp\n"
              "        }\n\n")
             name req resp resp path)]
    [(bidi)
     (format (string-append
              "        def ~a(reqs: List[~a], metadata: Map[String, String] = null, timeout: java.time.Duration = null): ~a = {\n"
              "            new ~a(channel.bidi(~s, reqs, metadata, timeout))\n"
              "        }\n\n")
             name req (scala-client-stream-name svc 'bidi resp)
             (scala-client-stream-name svc 'bidi resp) path)]))

(define (scala-future-method m)
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (case (hash-ref m 'kind)
    [(unary client-streaming)
     (format (string-append
              "        def ~aFuture(req~a, metadata: Map[String, String] = null, timeout: java.time.Duration = null): scala.concurrent.Future[~a] = {\n"
              "            grpcdc.Futures { ~a(req~a, metadata, timeout) }\n"
              "        }\n\n")
             name (if (eq? (hash-ref m 'kind) 'unary) (format ": ~a" req) (format "s: List[~a]" req))
             resp name (if (eq? (hash-ref m 'kind) 'unary) "" "s"))]
    [(server-streaming bidi)
     (format (string-append
              "        def ~aFuture(req~a, metadata: Map[String, String] = null, timeout: java.time.Duration = null): scala.concurrent.Future[List[~a]] = {\n"
              "            grpcdc.Futures {\n"
              "                val stream = ~a(req~a, metadata, timeout)\n"
              "                val out = scala.collection.mutable.ListBuffer[~a]()\n"
              "                var done = false\n"
              "                while (!done) {\n"
              "                    try {\n"
              "                        out += stream.recv()\n"
              "                    } catch {\n"
              "                        case e: java.io.EOFException => done = true\n"
              "                    }\n"
              "                }\n"
              "                out.toList\n"
              "            }\n"
              "        }\n\n")
             name (if (eq? (hash-ref m 'kind) 'server-streaming) (format ": ~a" req) (format "s: List[~a]" req))
             resp name (if (eq? (hash-ref m 'kind) 'server-streaming) "" "s") resp)]))

(define (scala-server-iface-method m)
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(unary)
     (format "        def ~a(ctx: grpcdc.Endpoint#CallContext, req: ~a): ~a\n" name req resp)]
    [(server-streaming)
     (format "        def ~a(req: ~a, stream: ~a): Unit\n" name req (scala-ss-trait-name svc resp))]
    [(client-streaming)
     (format "        def ~a(stream: ~a): Unit\n" name (scala-pair-trait-name svc 'client-streaming req resp "ClientStreamServer"))]
    [(bidi)
     (format "        def ~a(stream: ~a): Unit\n" name (scala-pair-trait-name svc 'bidi req resp "BidiServer"))]))

(define (scala-register-method m)
  (define name (hash-ref m 'name))
  (define impl-name (method-impl-name m))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define path (hash-ref m 'path))
  (define kind-const
    (case (hash-ref m 'kind)
      [(unary) "KIND_UNARY"]
      [(server-streaming) "KIND_SERVER_STREAMING"]
      [(client-streaming) "KIND_CLIENT_STREAMING"]
      [(bidi) "KIND_BIDI"]))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(unary)
     (format (string-append
              "            grpcdc.Server.Method(~s, ~s, grpcdc.Server.~a, (ctx, reqs, sink) => {\n"
              "                val req = new ~a()\n"
              "                reqs.recvInto(req)\n"
              "                val resp = impl.~a(ctx, req)\n"
              "                sink.send(resp.marshalDc())\n"
              "            }),\n")
             name path kind-const req impl-name)]
    [(server-streaming)
     (format (string-append
              "            grpcdc.Server.Method(~s, ~s, grpcdc.Server.~a, (ctx, reqs, sink) => {\n"
              "                val req = new ~a()\n"
              "                reqs.recvInto(req)\n"
              "                impl.~a(req, new ~a {\n"
              "                    def send(resp: ~a): Unit = sink.send(resp.marshalDc())\n"
              "                    val context: grpcdc.Endpoint#CallContext = ctx\n"
              "                })\n"
              "            }),\n")
             name path kind-const req impl-name (scala-ss-trait-name svc resp) resp)]
    [(client-streaming)
     (format (string-append
              "            grpcdc.Server.Method(~s, ~s, grpcdc.Server.~a, (ctx, reqs, sink) => {\n"
              "                var response: ~a = null\n"
              "                impl.~a(new ~a {\n"
              "                    def recv(): ~a = {\n"
              "                        val req = new ~a()\n"
              "                        reqs.recvInto(req)\n"
              "                        req\n"
              "                    }\n"
              "                    def sendAndClose(resp: ~a): Unit = { response = resp }\n"
              "                    val context: grpcdc.Endpoint#CallContext = ctx\n"
              "                })\n"
              "                if (response == null) {\n"
              "                    throw grpcdc.StatusException(grpcdc.Wire.CODE_INTERNAL, \"client-streaming handler never called sendAndClose\")\n"
              "                }\n"
              "                sink.send(response.marshalDc())\n"
              "            }),\n")
             name path kind-const resp impl-name (scala-pair-trait-name svc 'client-streaming req resp "ClientStreamServer") req req resp)]
    [(bidi)
     (format (string-append
              "            grpcdc.Server.Method(~s, ~s, grpcdc.Server.~a, (ctx, reqs, sink) => {\n"
              "                impl.~a(new ~a {\n"
              "                    def send(resp: ~a): Unit = sink.send(resp.marshalDc())\n"
              "                    def recv(): ~a = {\n"
              "                        val req = new ~a()\n"
              "                        reqs.recvInto(req)\n"
              "                        req\n"
              "                    }\n"
              "                    val context: grpcdc.Endpoint#CallContext = ctx\n"
              "                })\n"
              "            }),\n")
             name path kind-const impl-name (scala-pair-trait-name svc 'bidi req resp "BidiServer") resp req req)]))


(define (scala-server-async-iface-method m)
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(unary)
     (format "        def ~aAsync(ctx: grpcdc.Endpoint#CallContext, req: ~a): scala.concurrent.Future[~a]\n" name req resp)]
    [(server-streaming)
     (format "        def ~aAsync(req: ~a, stream: ~a): scala.concurrent.Future[Unit]\n" name req (scala-ss-trait-name svc resp))]
    [(client-streaming)
     (format "        def ~aAsync(stream: ~a): scala.concurrent.Future[Unit]\n" name (scala-pair-trait-name svc 'client-streaming req resp "ClientStreamServer"))]
    [(bidi)
     (format "        def ~aAsync(stream: ~a): scala.concurrent.Future[Unit]\n" name (scala-pair-trait-name svc 'bidi req resp "BidiServer"))]))

(define (scala-server-async-adapter-method m)
  (define name (hash-ref m 'name))
  (define impl-name (method-impl-name m))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(unary)
     (format (string-append
              "            def ~a(ctx: grpcdc.Endpoint#CallContext, req: ~a): ~a = {\n"
              "                scala.concurrent.Await.result(impl.~aAsync(ctx, req), scala.concurrent.duration.Duration.Inf)\n"
              "            }\n")
             name req resp impl-name)]
    [(server-streaming)
     (format (string-append
              "            def ~a(req: ~a, stream: ~a): Unit = {\n"
              "                scala.concurrent.Await.result(impl.~aAsync(req, stream), scala.concurrent.duration.Duration.Inf)\n"
              "            }\n")
             name req (scala-ss-trait-name svc resp) impl-name)]
    [(client-streaming)
     (format (string-append
              "            def ~a(stream: ~a): Unit = {\n"
              "                scala.concurrent.Await.result(impl.~aAsync(stream), scala.concurrent.duration.Duration.Inf)\n"
              "            }\n")
             name (scala-pair-trait-name svc 'client-streaming req resp "ClientStreamServer") impl-name)]
    [(bidi)
     (format (string-append
              "            def ~a(stream: ~a): Unit = {\n"
              "                scala.concurrent.Await.result(impl.~aAsync(stream), scala.concurrent.duration.Duration.Inf)\n"
              "            }\n")
             name (scala-pair-trait-name svc 'bidi req resp "BidiServer") impl-name)]))

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
  (define sname (hash-ref svc 'name))
  (define methods (hash-ref svc 'methods))
  (define req (hash-ref (car methods) 'input))
  (define resp (hash-ref (car methods) 'output))
  (define (class-outputs kind)
    (define os (kind-outputs kind))
    (if (null? os) (list resp) os))
  (define (pair-list kind)
    (define ps (kind-pairs kind))
    (if (null? ps) (list (cons req resp)) ps))
  (parameterize ([current-service sname] [current-methods methods])
    (string-append
     (format "    /** Client for ~a. */\n" (hash-ref svc 'full-name))
     (format "    class ~aClient(private val channel: grpcdc.Channel) {\n" sname)
     (apply string-append
            (for/list ([out (in-list (class-outputs 'server-streaming))])
              (string-append
               (format "        class ~a(private val stream: grpcdc.Channel#ClientStream) {\n" (scala-client-stream-name sname 'server-streaming out))
               (format "            def recv(): ~a = {\n" out)
               (format "                val resp = new ~a()\n" out)
               "                stream.recv(resp)\n"
               "                resp\n"
               "            }\n"
               "        }\n\n")))
     (apply string-append
            (for/list ([out (in-list (class-outputs 'bidi))])
              (string-append
               (format "        class ~a(private val stream: grpcdc.Channel#ClientStream) {\n" (scala-client-stream-name sname 'bidi out))
               (format "            def recv(): ~a = {\n" out)
               (format "                val resp = new ~a()\n" out)
               "                stream.recv(resp)\n"
               "                resp\n"
               "            }\n"
               "        }\n\n")))
     (apply string-append (map scala-client-method (append methods (alias-client-methods svc))))
     "        // -- async (scala.concurrent.Future) surface ---------------\n\n"
     (apply string-append (map scala-future-method (append methods (alias-client-methods svc))))
     "    }\n\n"
     (apply string-append
            (for/list ([out (in-list (class-outputs 'server-streaming))])
              (string-append
               (format "    /** Server-streaming sink passed to service implementations. */\n")
               (format "    trait ~a {\n" (scala-ss-trait-name sname out))
               (format "        def send(resp: ~a): Unit\n" out)
               "        val context: grpcdc.Endpoint#CallContext\n"
               "    }\n\n")))
     (apply string-append
            (for/list ([pr (in-list (pair-list 'client-streaming))])
              (string-append
               (format "    /** Client-streaming stream passed to service implementations. */\n")
               (format "    trait ~a {\n" (scala-pair-trait-name sname 'client-streaming (car pr) (cdr pr) "ClientStreamServer"))
               (format "        def recv(): ~a\n" (car pr))
               (format "        def sendAndClose(resp: ~a): Unit\n" (cdr pr))
               "        val context: grpcdc.Endpoint#CallContext\n"
               "    }\n\n")))
     (apply string-append
            (for/list ([pr (in-list (pair-list 'bidi))])
              (string-append
               (format "    /** Bidi stream passed to service implementations. */\n")
               (format "    trait ~a {\n" (scala-pair-trait-name sname 'bidi (car pr) (cdr pr) "BidiServer"))
               (format "        def send(resp: ~a): Unit\n" (cdr pr))
               (format "        def recv(): ~a\n" (car pr))
               "        val context: grpcdc.Endpoint#CallContext\n"
               "    }\n\n")))
     (format "    /** Service implementation interface for ~a. */\n" (hash-ref svc 'full-name))
     (format "    trait ~aServer {\n" sname)
     (apply string-append (map scala-server-iface-method methods))
     "    }\n\n"
     (format "    /** Register an implementation of ~a on a Server. */\n" (hash-ref svc 'full-name))
     (format "    def register~aServer(server: grpcdc.Server, impl: ~aServer): Unit = {\n" sname sname)
     (format "        server.registerService(grpcdc.Server.ServiceDesc(~s, List(\n" (hash-ref svc 'full-name))
     (apply string-append (map scala-register-method (append methods (alias-server-methods svc))))
     "        )))\n"
     "    }\n\n"
     (format "    /** Async service implementation for ~a (scala.concurrent.Future). */\n" (hash-ref svc 'full-name))
     (format "    trait ~aServerAsync {\n" sname)
     (apply string-append (map scala-server-async-iface-method methods))
     "    }\n\n"
     (format "    /** Register a Future-based implementation (adapts to the sync trait). */\n")
     (format "    def register~aServerAsync(server: grpcdc.Server, impl: ~aServerAsync): Unit = {\n" sname sname)
     (format "        register~aServer(server, new ~aServer {\n" sname sname)
     (apply string-append (map scala-server-async-adapter-method methods))
     "        })\n"
     "    }\n")))

;; ---------------------------------------------------------------------------
;; Generated message types (<Base>Messages.scala, in the proto
;; package): the stdlib-only protobuf wire codec beside the stubs,
;; emitted from the shared desc.rkt model. Mirrors the PHP emitter.
;; ---------------------------------------------------------------------------

(define sc-pb-varint-types '(5 3 13 4 17 18 8 14))
;; type -> (size kind) ; kind: double float fixed32 fixed64
(define sc-pb-fixed '((1 8 double) (2 4 float) (6 8 fixed64) (7 4 fixed32) (15 4 fixed32) (16 8 fixed64)))

(define (sc-pb-camel s)
  (define parts (string-split s "_"))
  (if (null? parts)
      s
      (apply string-append (car parts)
             (map (lambda (p) (if (string=? p "") "" (string-append (string (char-upcase (string-ref p 0))) (substring p 1))))
                  (cdr parts)))))

(define (sc-pb-field-name f)
  (define jn (hash-ref f 'json-name ""))
  (if (and jn (not (string=? jn ""))) jn (sc-pb-camel (hash-ref f 'name))))

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

(define (sc-pb-scalar-type f)
  (case (hash-ref f 'type)
    [(1) "Double"]
    [(2) "Float"]
    [(3 4 6 16 18) "Long"]
    [(8) "Boolean"]
    [(9) "String"]
    [(12) "Array[Byte]"]
    [else "Int"]))

(define (sc-pb-elem-type model f)
  (if (= (hash-ref f 'type) 11)
      (sc-pb-entry-ref model (sc-pb-resolve model (hash-ref f 'type-name)))
      (sc-pb-scalar-type f)))

(define (sc-pb-type model f)
  (cond [(and (= (hash-ref f 'type) 11)
              (eq? (hash-ref (sc-pb-resolve model (hash-ref f 'type-name)) 'kind) 'map))
         (define entry (sc-pb-resolve model (hash-ref f 'type-name)))
         (define msg (hash-ref entry 'msg))
         (define kf (findf (lambda (x) (= (hash-ref x 'number) 1)) (hash-ref msg 'fields)))
         (define vf (findf (lambda (x) (= (hash-ref x 'number) 2)) (hash-ref msg 'fields)))
         (format "Map[~a, ~a]" (sc-pb-elem-type model kf) (sc-pb-elem-type model vf))]
        [(= (hash-ref f 'label) 3)
         (format "List[~a]" (sc-pb-elem-type model f))]
        [else (sc-pb-elem-type model f)]))

(define (sc-pb-default model f)
  (cond [(and (= (hash-ref f 'type) 11)
              (eq? (hash-ref (sc-pb-resolve model (hash-ref f 'type-name)) 'kind) 'map)) "Map.empty"]
        [(= (hash-ref f 'label) 3) "List.empty"]
        [(= (hash-ref f 'type) 11) "null"]
        [(= (hash-ref f 'type) 9) "\"\""]
        [(= (hash-ref f 'type) 12) "Array.empty[Byte]"]
        [(= (hash-ref f 'type) 8) "false"]
        [(= (hash-ref f 'type) 1) "0.0"]
        [(= (hash-ref f 'type) 2) "0.0f"]
        [(memv (hash-ref f 'type) '(3 4 6 16 18)) "0L"]
        [(= (hash-ref f 'type) 14)
         (define entry (sc-pb-resolve model (hash-ref f 'type-name)))
         (format "~a" (hash-ref (car (hash-ref (hash-ref entry 'enum) 'values)) 'number))]
        [else "0"]))

(define (sc-pb-varint-expr f v)
  (case (hash-ref f 'type)
    [(8) (format "(if (~a) 1L else 0L)" v)]
    [(17) (format "(((~a << 1) ^ (~a >> 31)) & 0xffffffffL)" v v)]
    [(18) (format "((~a << 1) ^ (~a >> 63))" v v)]
    [(5 13 7 14) (format "(~a & 0xffffffffL)" v)]
    [else (format "~a.toLong" v)]))

(define (sc-pb-varint-decode f v)
  (case (hash-ref f 'type)
    [(5 14 13 7) (format "~a.toInt" v)]
    [(8) (format "(~a != 0L)" v)]
    [(17) (format "(((~a.toInt) >>> 1) ^ -((~a.toInt) & 1))" v v)]
    [(18) (format "((~a >>> 1) ^ -(~a & 1L))" v v)]
    [else v]))

(define (sc-pb-fixed-info f) (assv (hash-ref f 'type) sc-pb-fixed))
(define (sc-pb-wire f) (if (= (second (sc-pb-fixed-info f)) 8) 1 5))

(define (sc-pb-fixed-encode-expr f v)
  (case (third (sc-pb-fixed-info f))
    [(double) (format "~a.int64BytesLE(java.lang.Double.doubleToRawLongBits(~a))" (current-pb-obj) v)]
    [(float) (format "~a.int32BytesLE(java.lang.Float.floatToRawIntBits(~a))" (current-pb-obj) v)]
    [(fixed64) (format "~a.int64BytesLE(~a)" (current-pb-obj) v)]
    [(fixed32) (format "~a.int32BytesLE(~a)" (current-pb-obj) v)]))

(define (sc-pb-fixed-decode-expr f src)
  (case (third (sc-pb-fixed-info f))
    [(double) (format "java.lang.Double.longBitsToDouble(~a.toInt64LE(~a, 0))" (current-pb-obj) src)]
    [(float) (format "java.lang.Float.intBitsToFloat(~a.toInt32LE(~a, 0))" (current-pb-obj) src)]
    [(fixed64) (format "~a.toInt64LE(~a, 0)" (current-pb-obj) src)]
    [(fixed32) (format "~a.toInt32LE(~a, 0)" (current-pb-obj) src)]))

(define current-pb-obj (make-parameter "Pb"))

(define (sc-pb-nonzero f v)
  (case (hash-ref f 'type)
    [(8) v]
    [else (format "~a != 0" v)]))

(define (sc-pb-encode-singular model f v indent)
  (define n (hash-ref f 'number))
  (define type (hash-ref f 'type))
  (define obj (current-pb-obj))
  (cond [(memv type sc-pb-varint-types)
         (format "~aif (~a) {\n~a  w.tag(~a, 0)\n~a  w.varint(~a)\n~a}\n" indent (sc-pb-nonzero f v) indent n indent (sc-pb-varint-expr f v) indent)]
        [(assv type sc-pb-fixed)
         (format "~aif (~a != 0) {\n~a  w.fixed(~a, ~a, ~a)\n~a}\n" indent v indent n (sc-pb-wire f) (sc-pb-fixed-encode-expr f v) indent)]
        [(= type 9) (format "~aw.stringField(~a, ~a)\n" indent n v)]
        [(= type 12) (format "~aif (~a.nonEmpty) {\n~a  w.bytesField(~a, ~a)\n~a}\n" indent v indent n v indent)]
        [(= type 11) (format "~aif (~a != null) {\n~a  w.bytesField(~a, ~a.marshalDc())\n~a}\n" indent v indent n v indent)]
        [else (error 'emit-scala-pb-file "unsupported field type ~a (groups)" type)]))

(define (sc-pb-encode-field model f)
  (define v (sc-pb-field-name f))
  (define n (hash-ref f 'number))
  (define type (hash-ref f 'type))
  (define obj (current-pb-obj))
  (cond [(and (= type 11)
              (eq? (hash-ref (sc-pb-resolve model (hash-ref f 'type-name)) 'kind) 'map))
         (define entry (sc-pb-resolve model (hash-ref f 'type-name)))
         (define helper (format "~a.encode~a" obj (sc-pb-entry-ref model entry)))
         (format "    for ((k, v) <- ~a) {\n      w.bytesField(~a, ~a(k, v))\n    }\n" v n helper)]
        [(not (= (hash-ref f 'label) 3)) (sc-pb-encode-singular model f v "    ")]
        [(memv type sc-pb-varint-types)
         (string-append
          (format "    if (~a.nonEmpty) {\n      val payload = new java.io.ByteArrayOutputStream()\n" v)
          (format "      for (x <- ~a) {\n        payload.write(~a.varintBytes(~a))\n      }\n" v obj (sc-pb-varint-expr f "x"))
          (format "      w.bytesField(~a, payload.toByteArray)\n    }\n" n))]
        [(assv type sc-pb-fixed)
         (string-append
          (format "    if (~a.nonEmpty) {\n      val payload = new java.io.ByteArrayOutputStream()\n" v)
          (format "      for (x <- ~a) {\n        payload.write(~a)\n      }\n" v (sc-pb-fixed-encode-expr f "x"))
          (format "      w.bytesField(~a, payload.toByteArray)\n    }\n" n))]
        [(= type 9) (format "    for (x <- ~a) {\n      w.bytesField(~a, x.getBytes(java.nio.charset.StandardCharsets.UTF_8))\n    }\n" v n)]
        [(= type 12) (format "    for (x <- ~a) {\n      w.bytesField(~a, x)\n    }\n" v n)]
        [(= type 11) (format "    for (x <- ~a) {\n      w.bytesField(~a, x.marshalDc())\n    }\n" v n)]
        [else (error 'emit-scala-pb-file "unsupported repeated field type ~a" type)]))

(define (sc-pb-decode-singular model f target src indent)
  (define type (hash-ref f 'type))
  (cond [(memv type sc-pb-varint-types)
         (format "~a~a = ~a\n" indent target (sc-pb-varint-decode f src))]
        [(assv type sc-pb-fixed)
         (format "~a~a = ~a\n" indent target (sc-pb-fixed-decode-expr f src))]
        [(= type 9) (format "~a~a = new String(~a, java.nio.charset.StandardCharsets.UTF_8)\n" indent target src)]
        [(= type 12) (format "~a~a = ~a\n" indent target src)]
        [(= type 11)
         (define ref (sc-pb-entry-ref model (sc-pb-resolve model (hash-ref f 'type-name))))
         (string-append
          (format "~a~a = new ~a()\n" indent target ref)
          (format "~a~a.unmarshalDc(~a)\n" indent target src))]
        [else (error 'emit-scala-pb-file "unsupported field type ~a" type)]))

(define (sc-pb-decode-case model f)
  (define v (sc-pb-field-name f))
  (define type (hash-ref f 'type))
  (define obj (current-pb-obj))
  (define head (format "        case ~a =>\n" (hash-ref f 'number)))
  (cond [(and (= type 11)
              (eq? (hash-ref (sc-pb-resolve model (hash-ref f 'type-name)) 'kind) 'map))
         (define entry (sc-pb-resolve model (hash-ref f 'type-name)))
         (define helper (format "~a.decode~a" obj (sc-pb-entry-ref model entry)))
         (string-append head
                        (format "          val (kk, vv) = ~a(field.bytesValue)\n" helper)
                        (format "          ~a = ~a + (kk -> vv)\n" v v))]
        [(not (= (hash-ref f 'label) 3))
         (string-append head
                        (sc-pb-decode-singular model f v
                                               (cond [(memv type sc-pb-varint-types) "field.varintValue"]
                                                     [(assv type sc-pb-fixed) "field.fixedValue"]
                                                     [else "field.bytesValue"])
                                               "          "))]
        [(memv type sc-pb-varint-types)
         (string-append head
                        "          if (field.wire == 2) {\n"
                        (format "            val sub = new ~a.Reader(field.bytesValue)\n" obj)
                        "            while (!sub.done) {\n"
                        "              val raw = sub.varint()\n"
                        (format "              ~a = ~a :+ ~a\n" v v (sc-pb-varint-decode f "raw"))
                        "            }\n          } else {\n"
                        (format "            ~a = ~a :+ ~a\n" v v (sc-pb-varint-decode f "field.varintValue"))
                        "          }\n")]
        [(assv type sc-pb-fixed)
         (string-append head
                        "          if (field.wire == 2) {\n"
                        (format "            var i = 0\n            while (i < field.bytesValue.length) {\n")
                        (format "              ~a = ~a :+ ~a\n" v v
                                (sc-pb-fixed-decode-expr f (format "java.util.Arrays.copyOfRange(field.bytesValue, i, i + ~a)" (second (sc-pb-fixed-info f)))))
                        (format "              i += ~a\n            }\n          } else {\n" (second (sc-pb-fixed-info f)))
                        (format "            ~a = ~a :+ ~a\n" v v (sc-pb-fixed-decode-expr f "field.fixedValue"))
                        "          }\n")]
        [(= type 9) (string-append head (format "          ~a = ~a :+ new String(field.bytesValue, java.nio.charset.StandardCharsets.UTF_8)\n" v v))]
        [(= type 12) (string-append head (format "          ~a = ~a :+ field.bytesValue\n" v v))]
        [(= type 11)
         (string-append head
                        (format "          val item = new ~a()\n" (sc-pb-entry-ref model (sc-pb-resolve model (hash-ref f 'type-name))))
                        "          item.unmarshalDc(field.bytesValue)\n"
                        (format "          ~a = ~a :+ item\n" v v))]
        [else (error 'emit-scala-pb-file "unsupported repeated field type ~a" type)]))

(define (sc-pb-map-helpers model entry)
  (define msg (hash-ref entry 'msg))
  (define base (sc-pb-entry-ref model entry))
  (define obj (current-pb-obj))
  (define key-f (findf (lambda (x) (= (hash-ref x 'number) 1)) (hash-ref msg 'fields)))
  (define val-f (findf (lambda (x) (= (hash-ref x 'number) 2)) (hash-ref msg 'fields)))
  (unless (and key-f val-f) (error 'emit-scala-pb-file "map entry ~a lacks key/value" (hash-ref msg 'full-name)))
  (string-append
   (format "  def encode~a(key: ~a, value: ~a): Array[Byte] = {\n    val w = new Writer()\n" base (sc-pb-elem-type model key-f) (sc-pb-elem-type model val-f))
   (sc-pb-encode-singular model (hash-set key-f 'label 1) "key" "    ")
   (sc-pb-encode-singular model (hash-set val-f 'label 1) "value" "    ")
   "    w.toBytes\n  }\n\n"
   (format "  def decode~a(data: Array[Byte]): (~a, ~a) = {\n" base (sc-pb-elem-type model key-f) (sc-pb-elem-type model val-f))
   (format "    var key: ~a = ~a\n    var value: ~a = ~a\n" (sc-pb-elem-type model key-f) (sc-pb-default model (hash-set key-f 'label 1)) (sc-pb-elem-type model val-f) (sc-pb-default model (hash-set val-f 'label 1)))
   "    val r = new Reader(data)\n    var field = r.next()\n    while (field != null) {\n      field.number match {\n"
   (format "        case ~a =>\n~a" (hash-ref key-f 'number)
           (sc-pb-decode-singular model (hash-set key-f 'label 1) "key"
                                  (cond [(memv (hash-ref key-f 'type) sc-pb-varint-types) "field.varintValue"]
                                        [(assv (hash-ref key-f 'type) sc-pb-fixed) "field.fixedValue"]
                                        [else "field.bytesValue"]) "          "))
   (format "        case ~a =>\n~a" (hash-ref val-f 'number)
           (if (= (hash-ref val-f 'type) 11)
               (format "          value = new ~a()\n          value.unmarshalDc(field.bytesValue)\n"
                       (sc-pb-entry-ref model (sc-pb-resolve model (hash-ref val-f 'type-name))))
               (sc-pb-decode-singular model (hash-set val-f 'label 1) "value"
                                      (cond [(memv (hash-ref val-f 'type) sc-pb-varint-types) "field.varintValue"]
                                            [(assv (hash-ref val-f 'type) sc-pb-fixed) "field.fixedValue"]
                                            [else "field.bytesValue"]) "          ")))
   "        case _ => ()\n      }\n      field = r.next()\n    }\n    (key, value)\n  }\n\n"))

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
   "    def toBytes: Array[Byte] = out.toByteArray\n  }\n\n"
   "  def varintBytes(value: Long): Array[Byte] = {\n    val w = new Writer()\n    w.varint(value)\n    w.toBytes\n  }\n\n"
   "  def int32BytesLE(value: Int): Array[Byte] = {\n    Array((value & 0xff).toByte, ((value >> 8) & 0xff).toByte, ((value >> 16) & 0xff).toByte, ((value >> 24) & 0xff).toByte)\n  }\n\n"
   "  def int64BytesLE(value: Long): Array[Byte] = {\n    val out = new Array[Byte](8)\n    var i = 0\n    while (i < 8) {\n      out(i) = ((value >> (8 * i)) & 0xffL).toByte\n      i += 1\n    }\n    out\n  }\n\n"
   "  def toInt32LE(bytes: Array[Byte], off: Int): Int = {\n    (bytes(off) & 0xff) | ((bytes(off + 1) & 0xff) << 8) | ((bytes(off + 2) & 0xff) << 16) | ((bytes(off + 3) & 0xff) << 24)\n  }\n\n"
   "  def toInt64LE(bytes: Array[Byte], off: Int): Long = {\n    var result = 0L\n    var i = 0\n    while (i < 8) {\n      result |= (bytes(off + i) & 0xffL) << (8 * i)\n      i += 1\n    }\n    result\n  }\n\n"
   "  class Field(val number: Int, val wire: Int, val varintValue: Long, val bytesValue: Array[Byte], val fixedValue: Array[Byte])\n\n"
   "  class Reader(private val buf: Array[Byte]) {\n"
   "    private var pos = 0\n\n"
   "    def done: Boolean = pos >= buf.length\n\n"
   "    def varint(): Long = {\n      var result = 0L\n      var shift = 0\n      while (true) {\n        if (pos >= buf.length) {\n          throw new IllegalArgumentException(\"truncated varint\")\n        }\n        val b = buf(pos).toInt & 0xff\n        pos += 1\n        result = result | ((b & 0x7f).toLong << shift)\n        if ((b & 0x80) == 0) {\n          return result\n        }\n        shift += 7\n        if (shift >= 70) {\n          throw new IllegalArgumentException(\"varint too long\")\n        }\n      }\n      0L\n    }\n\n"
   "    def take(n: Int): Array[Byte] = {\n      if (pos + n > buf.length) {\n        throw new IllegalArgumentException(\"truncated field\")\n      }\n      val value = buf.slice(pos, pos + n)\n      pos += n\n      value\n    }\n\n"
   "    def next(): Field = {\n      if (done) {\n        return null\n      }\n      val tag = varint()\n      val number = (tag >>> 3).toInt\n      val wire = (tag & 7).toInt\n      wire match {\n        case 0 => new Field(number, wire, varint(), Array.empty[Byte], Array.empty[Byte])\n        case 2 =>\n          val n = varint().toInt\n          new Field(number, wire, 0L, take(n), Array.empty[Byte])\n        case 1 => new Field(number, wire, 0L, Array.empty[Byte], take(8))\n        case 5 => new Field(number, wire, 0L, Array.empty[Byte], take(4))\n        case _ => throw new IllegalArgumentException(\"bad wire type\")\n      }\n    }\n  }\n"))

(define (sc-pb-message-class model msg)
  (define name (sc-pb-flat (hash-ref model 'package) (hash-ref msg 'full-name)))
  (define fields (hash-ref msg 'fields))
  (define obj (current-pb-obj))
  (string-append
   (format "class ~a(\n" name)
   (string-join (map (lambda (f) (format "    var ~a: ~a = ~a" (sc-pb-field-name f) (sc-pb-type model f) (sc-pb-default model f))) fields) ",\n")
   (if (null? fields) "" "\n")
   ") extends grpcdc.Marshaler with grpcdc.Unmarshaler {\n"
   "  def marshalDc(): Array[Byte] = {\n"
   (format "    val w = new ~a.Writer()\n" obj)
   (apply string-append (map (lambda (f) (sc-pb-encode-field model f)) fields))
   "    w.toBytes\n  }\n\n"
   "  def unmarshalDc(data: Array[Byte]): Unit = {\n"
   (apply string-append (map (lambda (f) (format "    ~a = ~a\n" (sc-pb-field-name f) (sc-pb-default model f))) fields))
   (format "    val r = new ~a.Reader(data)\n" obj)
   "    var field = r.next()\n    while (field != null) {\n      field.number match {\n"
   (apply string-append (map (lambda (f) (sc-pb-decode-case model f)) fields))
   "        case _ => ()\n      }\n      field = r.next()\n    }\n  }\n"
   "}\n\n"
   (apply string-append (map (lambda (n) (sc-pb-message-class model n)) (hash-ref msg 'nested)))))

(define (sc-pb-enum model e)
  (define name (sc-pb-flat (hash-ref model 'package)
                           (if (string=? (hash-ref model 'package) "")
                               (hash-ref e 'name)
                               (format "~a.~a" (hash-ref model 'package) (hash-ref e 'name)))))
  (string-append
   (format "object ~a {\n" name)
   (apply string-append
          (map (lambda (v) (format "  final val ~a: Int = ~a\n" (hash-ref v 'name) (hash-ref v 'number)))
               (hash-ref e 'values)))
   "}\n\n"))

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
                          (equal? (hash-ref e 'file) (hash-ref file-model 'name))
                          (not (set-member? seen-maps (hash-ref (hash-ref e 'msg) 'full-name))))
                 (set-add! seen-maps (hash-ref (hash-ref e 'msg) 'full-name))
                 (set! helpers (cons (sc-pb-map-helpers file-model e) helpers)))))
           (for ([n (in-list (hash-ref msg 'nested))]) (collect n)))
         (parameterize ([current-pb-obj obj])
           (for ([m (in-list messages)]) (collect m))
           (define content
             (string-append
              "// @generated by protoc-gen-grpc-dc-scala (Racket metaprogram). DO NOT EDIT.\n"
              (if (string=? pkg "") "" (format "package ~a\n\n" pkg))
              (sc-pb-support obj)
              (apply string-append helpers)
              "}\n\n"
              (apply string-append (map (lambda (e) (sc-pb-enum file-model e)) enums))
              (apply string-append
                     (map (lambda (m) (sc-pb-message-class file-model m))
                          (filter (lambda (m) (not (hash-ref m 'map-entry))) messages)))))
           (cons (string-append (pascal (string->symbol base)) "Messages.scala") content)))))

(define (emit-scala-file file-model params)
  (define base (path->string (path-replace-extension
                              (file-name-from-path (hash-ref file-model 'name)) "")))
  (define obj-name (string-append (pascal (string->symbol base)) "GrpcDc"))
  (define pkg (hash-ref file-model 'package))
  (define stub
    (cons (string-append obj-name ".scala")
        (string-append
         "// @generated by protoc-gen-grpc-dc-scala (Racket metaprogram). DO NOT EDIT.\n"
         (format "// source: ~a\n" (hash-ref file-model 'name))
         (format "package ~a\n\n" pkg)
         "/** Generated gRPC-over-DataChannels stubs. */\n"
         (format "object ~a {\n" obj-name)
         (apply string-append
                (map scala-service (hash-ref file-model 'services)))
         "}\n")))
  (define pb-file (emit-scala-pb-file file-model))
  (if pb-file (list stub pb-file) stub))
