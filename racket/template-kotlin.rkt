#lang racket

;;; template-kotlin.rkt — emitter body spliced into
;;; protoc-gen-grpc-dc-kotlin.
;;;
;;; Generated code is one object <Base>GrpcDc in the proto package,
;;; beside hand-written message types implementing Marshaler /
;;; Unmarshaler. Method names keep the proto spelling, mirroring the
;;; other language stubs.

(require "spec.rkt" "desc.rkt")
(provide emit-kotlin-file)

(define current-service (make-parameter ""))

(define (pascal sym) ; echo_service -> EchoService ; echo -> Echo
  (apply string-append
         (for/list ([part (in-list (string-split (symbol->string sym) "[_.-]"))])
           (if (string=? part "")
               ""
               (string-append (string (char-upcase (string-ref part 0)))
                              (substring part 1))))))

(define (kotlin-deprecated m indent)
  (if (hash-ref m 'deprecated #f)
      (format "~a@Deprecated(\"deprecated in the proto schema\")\n" indent)
      ""))

(define (kotlin-client-method/raw m)
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define path (hash-ref m 'path))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(unary)
     (format (string-append
              "        fun ~a(req: ~a, metadata: Map<String, String>? = null, timeout: java.time.Duration? = null): ~a {\n"
              "            val resp = ~a()\n"
              "            channel.unary(~s, req, resp, metadata, timeout)\n"
              "            return resp\n"
              "        }\n\n")
             name req resp resp path)]
    [(server-streaming)
     (format (string-append
              "        fun ~a(req: ~a, metadata: Map<String, String>? = null, timeout: java.time.Duration? = null): ~a~aStream {\n"
              "            return ~a~aStream(channel.serverStream(~s, req, metadata, timeout))\n"
              "        }\n\n")
             name req svc name svc name path)]
    [(client-streaming)
     (format (string-append
              "        fun ~a(reqs: List<~a>, metadata: Map<String, String>? = null, timeout: java.time.Duration? = null): ~a {\n"
              "            val resp = ~a()\n"
              "            channel.clientStreamCall(~s, reqs, resp, metadata, timeout)\n"
              "            return resp\n"
              "        }\n\n")
             name req resp resp path)]
    [(bidi)
     (format (string-append
              "        fun ~a(reqs: List<~a>, metadata: Map<String, String>? = null, timeout: java.time.Duration? = null): ~a~aStream {\n"
              "            return ~a~aStream(channel.bidi(~s, reqs, metadata, timeout))\n"
              "        }\n\n")
             name req svc name svc name path)]))

(define (kotlin-client-method m)
  (string-append (kotlin-deprecated m "        ") (kotlin-client-method/raw m)))

(define (kotlin-client-stream-class m)
  (define name (hash-ref m 'name))
  (define resp (hash-ref m 'output))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(server-streaming bidi)
     (format (string-append
              "        class ~a~aStream(private val stream: Channel.ClientStream) {\n"
              "            fun recv(): ~a {\n"
              "                val resp = ~a()\n"
              "                stream.recv(resp)\n"
              "                return resp\n"
              "            }\n"
              "        }\n\n")
             svc name resp resp)]
    [else ""]))

(define (kotlin-client-async-method m)
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (case (hash-ref m 'kind)
    [(unary)
     (format (string-append
              "        suspend fun ~aAsync(req: ~a, metadata: Map<String, String>? = null, timeout: java.time.Duration? = null): ~a {\n"
              "            return AsyncPump.await(~aFuture(req, metadata, timeout))\n"
              "        }\n\n"
              "        fun ~aFuture(req: ~a, metadata: Map<String, String>? = null, timeout: java.time.Duration? = null): CompletableFuture<~a> {\n"
              "            return AsyncPump.future { ~a(req, metadata, timeout) }\n"
              "        }\n\n")
             name req resp name name req resp name)]
    [(server-streaming)
     (format (string-append
              "        suspend fun ~aAsync(req: ~a, metadata: Map<String, String>? = null, timeout: java.time.Duration? = null): List<~a> {\n"
              "            return AsyncPump.await(~aFuture(req, metadata, timeout))\n"
              "        }\n\n"
              "        fun ~aFuture(req: ~a, metadata: Map<String, String>? = null, timeout: java.time.Duration? = null): CompletableFuture<List<~a>> {\n"
              "            return AsyncPump.future {\n"
              "                val stream = ~a(req, metadata, timeout)\n"
              "                val out = ArrayList<~a>()\n"
              "                while (true) {\n"
              "                    try {\n"
              "                        out.add(stream.recv())\n"
              "                    } catch (e: EOFException) {\n"
              "                        break\n"
              "                    }\n"
              "                }\n"
              "                out\n"
              "            }\n"
              "        }\n\n")
             name req resp name name req resp name resp)]
    [(client-streaming)
     (format (string-append
              "        suspend fun ~aAsync(reqs: List<~a>, metadata: Map<String, String>? = null, timeout: java.time.Duration? = null): ~a {\n"
              "            return AsyncPump.await(~aFuture(reqs, metadata, timeout))\n"
              "        }\n\n"
              "        fun ~aFuture(reqs: List<~a>, metadata: Map<String, String>? = null, timeout: java.time.Duration? = null): CompletableFuture<~a> {\n"
              "            return AsyncPump.future { ~a(reqs, metadata, timeout) }\n"
              "        }\n\n")
             name req resp name name req resp name)]
    [(bidi)
     (format (string-append
              "        suspend fun ~aAsync(reqs: List<~a>, metadata: Map<String, String>? = null, timeout: java.time.Duration? = null): List<~a> {\n"
              "            return AsyncPump.await(~aFuture(reqs, metadata, timeout))\n"
              "        }\n\n"
              "        fun ~aFuture(reqs: List<~a>, metadata: Map<String, String>? = null, timeout: java.time.Duration? = null): CompletableFuture<List<~a>> {\n"
              "            return AsyncPump.future {\n"
              "                val stream = ~a(reqs, metadata, timeout)\n"
              "                val out = ArrayList<~a>()\n"
              "                while (true) {\n"
              "                    try {\n"
              "                        out.add(stream.recv())\n"
              "                    } catch (e: EOFException) {\n"
              "                        break\n"
              "                    }\n"
              "                }\n"
              "                out\n"
              "            }\n"
              "        }\n\n")
             name req resp name name req resp name resp)]))

(define (kotlin-server-stream-iface m)
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(unary) ""]
    [(server-streaming)
     (format (string-append
              "    /** Server-streaming sink passed to service implementations. */\n"
              "    interface ~a~aServer {\n"
              "        fun send(resp: ~a)\n"
              "        val context: Endpoint.CallContext\n"
              "    }\n\n")
             svc name resp)]
    [(client-streaming)
     (format (string-append
              "    /** Client-streaming stream passed to service implementations. */\n"
              "    interface ~a~aServer {\n"
              "        fun recv(): ~a\n"
              "        fun sendAndClose(resp: ~a)\n"
              "        val context: Endpoint.CallContext\n"
              "    }\n\n")
             svc name req resp)]
    [(bidi)
     (format (string-append
              "    /** Bidi stream passed to service implementations. */\n"
              "    interface ~a~aServer {\n"
              "        fun send(resp: ~a)\n"
              "        fun recv(): ~a\n"
              "        val context: Endpoint.CallContext\n"
              "    }\n\n")
             svc name resp req)]))

(define (kotlin-server-iface-method/raw m)
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(unary)
     (format "        fun ~a(ctx: Endpoint.CallContext, req: ~a): ~a\n" name req resp)]
    [(server-streaming)
     (format "        fun ~a(req: ~a, stream: ~a~aServer)\n" name req svc name)]
    [(client-streaming)
     (format "        fun ~a(stream: ~a~aServer)\n" name svc name)]
    [(bidi)
     (format "        fun ~a(stream: ~a~aServer)\n" name svc name)]))

(define (kotlin-server-iface-method m)
  (string-append (kotlin-deprecated m "        ") (kotlin-server-iface-method/raw m)))

(define (kotlin-server-async-iface-method m)
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(unary)
     (format "        suspend fun ~aAsync(ctx: Endpoint.CallContext, req: ~a): ~a\n" name req resp)]
    [(server-streaming)
     (format "        suspend fun ~aAsync(req: ~a, stream: ~a~aServer)\n" name req svc name)]
    [(client-streaming)
     (format "        suspend fun ~aAsync(stream: ~a~aServer)\n" name svc name)]
    [(bidi)
     (format "        suspend fun ~aAsync(stream: ~a~aServer)\n" name svc name)]))

(define (kotlin-server-async-adapter-method m)
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(unary)
     (format (string-append
              "        override fun ~a(ctx: Endpoint.CallContext, req: ~a): ~a {\n"
              "            return AsyncPump.runSuspend { impl.~aAsync(ctx, req) }\n"
              "        }\n\n")
             name req resp name)]
    [(server-streaming)
     (format (string-append
              "        override fun ~a(req: ~a, stream: ~a~aServer) {\n"
              "            AsyncPump.runSuspend { impl.~aAsync(req, stream) }\n"
              "        }\n\n")
             name req svc name name)]
    [(client-streaming)
     (format (string-append
              "        override fun ~a(stream: ~a~aServer) {\n"
              "            AsyncPump.runSuspend { impl.~aAsync(stream) }\n"
              "        }\n\n")
             name svc name name)]
    [(bidi)
     (format (string-append
              "        override fun ~a(stream: ~a~aServer) {\n"
              "            AsyncPump.runSuspend { impl.~aAsync(stream) }\n"
              "        }\n\n")
             name svc name name)]))

(define (kotlin-stream-impl m)
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(unary) ""]
    [(server-streaming)
     (format (string-append
              "    private class ~a~aServerImpl(\n"
              "        override val context: Endpoint.CallContext,\n"
              "        private val sink: Server.ServerSink\n"
              "    ) : ~a~aServer {\n"
              "        override fun send(resp: ~a) {\n"
              "            sink.send(resp.marshalDc())\n"
              "        }\n"
              "    }\n\n")
             svc name svc name resp)]
    [(client-streaming)
     (format (string-append
              "    private class ~a~aServerImpl(\n"
              "        override val context: Endpoint.CallContext,\n"
              "        private val reqs: Server.RequestStream\n"
              "    ) : ~a~aServer {\n"
              "        var resp: ~a? = null\n"
              "            private set\n\n"
              "        override fun recv(): ~a {\n"
              "            val req = ~a()\n"
              "            reqs.recvInto(req)\n"
              "            return req\n"
              "        }\n\n"
              "        override fun sendAndClose(resp: ~a) {\n"
              "            this.resp = resp\n"
              "        }\n"
              "    }\n\n")
             svc name svc name resp req req resp)]
    [(bidi)
     (format (string-append
              "    private class ~a~aServerImpl(\n"
              "        override val context: Endpoint.CallContext,\n"
              "        private val reqs: Server.RequestStream,\n"
              "        private val sink: Server.ServerSink\n"
              "    ) : ~a~aServer {\n"
              "        override fun send(resp: ~a) {\n"
              "            sink.send(resp.marshalDc())\n"
              "        }\n\n"
              "        override fun recv(): ~a {\n"
              "            val req = ~a()\n"
              "            reqs.recvInto(req)\n"
              "            return req\n"
              "        }\n"
              "    }\n\n")
             svc name svc name resp req req)]))

(define (kotlin-register-method m)
  (define name (hash-ref m 'name))
  (define impl-name (method-impl-name m))
  (define req (hash-ref m 'input))
  (define svc (current-service))
  (define kind-const
    (case (hash-ref m 'kind)
      [(unary) "KIND_UNARY"]
      [(server-streaming) "KIND_SERVER_STREAMING"]
      [(client-streaming) "KIND_CLIENT_STREAMING"]
      [(bidi) "KIND_BIDI"]))
  (case (hash-ref m 'kind)
    [(unary)
     (format (string-append
              "                    Server.Method(~s, ~s, Server.~a) { ctx, reqs, sink ->\n"
              "                        val req = ~a()\n"
              "                        reqs.recvInto(req)\n"
              "                        sink.send(impl.~a(ctx, req).marshalDc())\n"
              "                    },\n")
             name (hash-ref m 'path) kind-const req impl-name)]
    [(server-streaming)
     (format (string-append
              "                    Server.Method(~s, ~s, Server.~a) { ctx, reqs, sink ->\n"
              "                        val req = ~a()\n"
              "                        reqs.recvInto(req)\n"
              "                        impl.~a(req, ~a~aServerImpl(ctx, sink))\n"
              "                    },\n")
             name (hash-ref m 'path) kind-const req impl-name svc name)]
    [(client-streaming)
     (format (string-append
              "                    Server.Method(~s, ~s, Server.~a) { ctx, reqs, sink ->\n"
              "                        val stream = ~a~aServerImpl(ctx, reqs)\n"
              "                        impl.~a(stream)\n"
              "                        val resp = stream.resp\n"
              "                            ?: throw StatusException(\n"
              "                                Wire.CODE_INTERNAL,\n"
              "                                \"client-streaming handler never called sendAndClose\"\n"
              "                            )\n"
              "                        sink.send(resp.marshalDc())\n"
              "                    },\n")
             name (hash-ref m 'path) kind-const svc name impl-name)]
    [(bidi)
     (format (string-append
              "                    Server.Method(~s, ~s, Server.~a) { ctx, reqs, sink ->\n"
              "                        impl.~a(~a~aServerImpl(ctx, reqs, sink))\n"
              "                    },\n")
             name (hash-ref m 'path) kind-const impl-name svc name)]))

(define (kotlin-service svc)
  (define sname (hash-ref svc 'name))
  (define methods (hash-ref svc 'methods))
  (parameterize ([current-service sname])
    (string-append
     (format "    /** Client for ~a. */\n" (hash-ref svc 'full-name))
     (format "    class ~aClient(private val channel: Channel) {\n" sname)
     (apply string-append (map kotlin-client-stream-class methods))
     (apply string-append (map kotlin-client-method (append methods (alias-client-methods svc))))
     "        // -- async (coroutine / CompletableFuture) surface ---------------\n\n"
     (apply string-append (map kotlin-client-async-method (append methods (alias-client-methods svc))))
     "    }\n\n"
     (apply string-append (map kotlin-server-stream-iface methods))
     (format "    /** Service implementation interface for ~a. */\n" (hash-ref svc 'full-name))
     (format "    interface ~aServer {\n" sname)
     (apply string-append (map kotlin-server-iface-method methods))
     "    }\n\n"
     (format "    /** Async service implementation interface for ~a. */\n" (hash-ref svc 'full-name))
     (format "    interface ~aServerAsync {\n" sname)
     (apply string-append (map kotlin-server-async-iface-method methods))
     "    }\n\n"
     (apply string-append (map kotlin-stream-impl methods))
     (format "    private class ~aServerAsyncAdapter(private val impl: ~aServerAsync) : ~aServer {\n" sname sname sname)
     (apply string-append (map kotlin-server-async-adapter-method methods))
     "    }\n\n"
     (format "    /** Register an implementation of ~a on a Server. */\n" (hash-ref svc 'full-name))
     (format "    fun register~aServer(server: Server, impl: ~aServer) {\n" sname sname)
     "        server.registerService(\n"
     "            Server.ServiceDesc(\n"
     (format "                ~s,\n" (hash-ref svc 'full-name))
     "                listOf(\n"
     (let ([regs (apply string-append (map kotlin-register-method (append methods (alias-server-methods svc))))])
       (if (string-suffix? regs ",\n")
           (string-append (substring regs 0 (- (string-length regs) 2)) "\n")
           regs))
     "                )\n"
     "            )\n"
     "        )\n"
     "    }\n\n"
     (format "    /** Register an async implementation of ~a on a Server. */\n" (hash-ref svc 'full-name))
     (format "    fun register~aServerAsync(server: Server, impl: ~aServerAsync) {\n" sname sname)
     "        // Adapters are retained for the process lifetime: registration is\n"
     "        // once-per-process and bounded by service count.\n"
     (format "        val adapter = ~aServerAsyncAdapter(impl)\n" sname)
     "        adapters.add(adapter)\n"
     (format "        register~aServer(server, adapter)\n    }\n\n" sname)
     (format "    private val adapters = ArrayList<~aServerAsyncAdapter>()\n" sname))))

(define (emit-kotlin-file file-model params)
  (define base (path->string (path-replace-extension
                              (file-name-from-path (hash-ref file-model 'name)) "")))
  (define object-name (string-append (pascal (string->symbol base)) "GrpcDc"))
  (define pkg (hash-ref file-model 'package))
  (cons (string-append object-name ".kt")
        (string-append
         "// @generated by protoc-gen-grpc-dc-kotlin (Racket metaprogram). DO NOT EDIT.\n"
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
         (format "/** Generated gRPC-over-DataChannels stubs for ~a. */\n" (hash-ref file-model 'name))
         (format "object ~a {\n" object-name)
         (apply string-append
                (map kotlin-service (hash-ref file-model 'services)))
         "}\n")))
