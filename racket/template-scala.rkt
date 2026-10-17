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

(define (emit-scala-file file-model params)
  (define base (path->string (path-replace-extension
                              (file-name-from-path (hash-ref file-model 'name)) "")))
  (define obj-name (string-append (pascal (string->symbol base)) "GrpcDc"))
  (define pkg (hash-ref file-model 'package))
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
