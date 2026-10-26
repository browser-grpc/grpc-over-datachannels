#lang racket

;;; template-kotlin.rkt — emitter body spliced into
;;; protoc-gen-grpc-dc-kotlin.
;;;
;;; Generated code is one object <Base>GrpcDc in the proto package,
;;; beside hand-written message types implementing Marshaler /
;;; Unmarshaler. Method names keep the proto spelling, mirroring the
;;; other language stubs.

(require "spec.rkt" "desc.rkt")
(provide emit-kotlin-file emit-wasm-kotlin-native-file)

(define kotlin-wasm-mode (make-parameter #f))

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
              "        class ~a~aStream(private val stream: Channel.ClientStream) : AutoCloseable {\n"
              "            fun recv(): ~a {\n"
              "                val resp = ~a()\n"
              "                stream.recv(resp)\n"
              "                return resp\n"
              "            }\n\n"
              "            /** Abort this stream (sends RST, wakes a pending recv). */\n"
              "            fun cancel() = stream.cancel()\n\n"
              "            /** Abandon the call if still live (RST); no-op once terminated. */\n"
              "            override fun close() = stream.close()\n"
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
              "            val stream = ~a(req, metadata, timeout)\n"
              "            return AsyncPump.future(onCancel = { stream.cancel() }) {\n"
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
              "            val stream = ~a(reqs, metadata, timeout)\n"
              "            return AsyncPump.future(onCancel = { stream.cancel() }) {\n"
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
     (if (kotlin-wasm-mode) "" "        // -- async (coroutine / CompletableFuture) surface ---------------\n\n")
     (if (kotlin-wasm-mode) "" (apply string-append (map kotlin-client-async-method (append methods (alias-client-methods svc)))))
     "    }\n\n"
     (apply string-append (map kotlin-server-stream-iface methods))
     (format "    /** Service implementation interface for ~a. */\n" (hash-ref svc 'full-name))
     (format "    interface ~aServer {\n" sname)
     (apply string-append (map kotlin-server-iface-method methods))
     "    }\n\n"
     (if (kotlin-wasm-mode) "" (format "    /** Async service implementation interface for ~a. */\n" (hash-ref svc 'full-name)))
     (if (kotlin-wasm-mode) "" (format "    interface ~aServerAsync {\n" sname))
     (if (kotlin-wasm-mode) "" (apply string-append (map kotlin-server-async-iface-method methods)))
     (if (kotlin-wasm-mode) "" "    }\n\n")
     (apply string-append (map kotlin-stream-impl methods))
     (if (kotlin-wasm-mode) "" (format "    private class ~aServerAsyncAdapter(private val impl: ~aServerAsync) : ~aServer {\n" sname sname sname))
     (if (kotlin-wasm-mode) "" (apply string-append (map kotlin-server-async-adapter-method methods)))
     (if (kotlin-wasm-mode) "" "    }\n\n")
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
     (if (kotlin-wasm-mode) "" (format "    /** Register an async implementation of ~a on a Server. */\n" (hash-ref svc 'full-name)))
     (if (kotlin-wasm-mode) "" (format "    fun register~aServerAsync(server: Server, impl: ~aServerAsync) {\n" sname sname))
     (if (kotlin-wasm-mode) "" "        // Adapters are retained for the process lifetime: registration is\n")
     (if (kotlin-wasm-mode) "" "        // once-per-process and bounded by service count.\n")
     (if (kotlin-wasm-mode) "" (format "        val adapter = ~aServerAsyncAdapter(impl)\n" sname))
     (if (kotlin-wasm-mode) "" "        adapters.add(adapter)\n")
     (if (kotlin-wasm-mode) "" (format "        register~aServer(server, adapter)\n    }\n\n" sname))
     (if (kotlin-wasm-mode) "" (format "    private val adapters = ArrayList<~aServerAsyncAdapter>()\n" sname)))))

;; ---------------------------------------------------------------------------
;; Kotlin message types (<Base>Messages.kt): classes implementing
;; grpcdc.Marshaler/Unmarshaler plus a <Base>Pb wire-support object
;; per proto file. Dependency-free (JDK only). Mirrors the Swift
;; emitter on the shared desc.rkt model.
;; ---------------------------------------------------------------------------

(define kt-pb-varint-types '(5 3 13 4 17 18 8 14))
(define kt-pb-fixed '((2 4 "Float") (1 8 "Double") (7 4 "UInt") (15 4 "Int") (6 8 "ULong") (16 8 "Long")))

(define (kt-pb-camel s)
  (define parts (string-split s "_"))
  (if (null? parts)
      s
      (apply string-append (car parts)
             (map (lambda (p) (if (string=? p "") "" (string-append (string (char-upcase (string-ref p 0))) (substring p 1))))
                  (cdr parts)))))

(define (kt-pb-field-name f)
  (define jn (hash-ref f 'json-name ""))
  (if (and jn (not (string=? jn ""))) jn (kt-pb-camel (hash-ref f 'name))))

(define (kt-pb-resolve model type-name)
  (hash-ref (hash-ref model 'types) type-name
            (lambda () (error 'emit-kotlin-pb-file "unresolved type ~a" type-name))))

(define (kt-pb-rel pkg full)
  (define rel (if (and pkg (not (string=? pkg "")) (string-prefix? full (string-append pkg ".")))
                  (substring full (add1 (string-length pkg)))
                  full))
  (string-join (string-split rel ".") "."))

(define (kt-pb-entry-ref model entry)
  (define rel
    (kt-pb-rel (hash-ref entry 'pkg)
               (if (eq? (hash-ref entry 'kind) 'enum)
                   (let ([e (hash-ref entry 'enum)])
                     (if (hash-ref entry 'msg)
                         (format "~a.~a" (hash-ref (hash-ref entry 'msg) 'full-name) (hash-ref e 'name))
                         (format "~a.~a" (hash-ref entry 'pkg) (hash-ref e 'name))))
                   (hash-ref (hash-ref entry 'msg) 'full-name))))
  (if (equal? (hash-ref entry 'file) (hash-ref model 'name))
      rel
      (if (string=? (hash-ref entry 'pkg) "") rel (string-append (hash-ref entry 'pkg) "." rel))))

(define (kt-pb-scalar f)
  (case (hash-ref f 'type)
    [(1) '("Double" "0.0")] [(2) '("Float" "0f")] [(3) '("Long" "0L")] [(4) '("ULong" "0uL")]
    [(5) '("Int" "0")] [(6) '("ULong" "0uL")] [(7) '("UInt" "0u")] [(8) '("Boolean" "false")]
    [(9) '("String" "\"\"")] [(12) '("ByteArray" "ByteArray(0)")] [(13) '("UInt" "0u")]
    [(15) '("Int" "0")] [(16) '("Long" "0L")] [(17) '("Int" "0")] [(18) '("Long" "0L")]
    [else #f]))

(define (kt-pb-type model f)
  (define type (hash-ref f 'type))
  (define singular
    (cond [(= type 11)
           (define entry (kt-pb-resolve model (hash-ref f 'type-name)))
           (if (eq? (hash-ref entry 'kind) 'map)
               (let* ([em (hash-ref entry 'msg)]
                      [kf (findf (lambda (x) (= (hash-ref x 'number) 1)) (hash-ref em 'fields))]
                      [vf (findf (lambda (x) (= (hash-ref x 'number) 2)) (hash-ref em 'fields))])
                 (format "MutableMap<~a, ~a>" (kt-pb-type model (hash-set kf 'label 1))
                         (if (= (hash-ref vf 'type) 11)
                             (kt-pb-entry-ref model (kt-pb-resolve model (hash-ref vf 'type-name)))
                             (kt-pb-type model (hash-set vf 'label 1)))))
               (format "~a?" (kt-pb-entry-ref model entry)))]
          [(= type 14) (kt-pb-entry-ref model (kt-pb-resolve model (hash-ref f 'type-name)))]
          [else (first (kt-pb-scalar f))]))
  (cond [(and (= type 11)
              (eq? (hash-ref (kt-pb-resolve model (hash-ref f 'type-name)) 'kind) 'map))
         singular]
        [(= (hash-ref f 'label) 3)
         (format "MutableList<~a>" (if (= type 11)
                                       (kt-pb-entry-ref model (kt-pb-resolve model (hash-ref f 'type-name)))
                                       (kt-pb-type model (hash-set f 'label 1))))]
        [else singular]))

(define (kt-pb-explicit-literal model f)
  (define d (field-explicit-default f))
  (and d
       (case (hash-ref f 'type)
         [(9) (format "~s" d)]
         [(8) d]
         [(14) (format "~a.~a" (kt-pb-entry-ref model (kt-pb-resolve model (hash-ref f 'type-name))) d)]
         [(2) (format "~af" d)]
         [else d])))

(define (kt-pb-default model f)
  (cond [(kt-pb-explicit-literal model f) => (lambda (lit) lit)]
        [(and (= (hash-ref f 'type) 11)
              (eq? (hash-ref (kt-pb-resolve model (hash-ref f 'type-name)) 'kind) 'map))
         "mutableMapOf()"]
        [(= (hash-ref f 'label) 3) "mutableListOf()"]
        [(= (hash-ref f 'type) 11) "null"]
        [(= (hash-ref f 'type) 14)
         (define entry (kt-pb-resolve model (hash-ref f 'type-name)))
         (format "~a.~a" (kt-pb-entry-ref model entry) (hash-ref (car (hash-ref (hash-ref entry 'enum) 'values)) 'name))]
        [else (second (kt-pb-scalar f))]))

(define (kt-pb-varint-expr f v)
  (case (hash-ref f 'type)
    [(8) (format "if (~a) 1L else 0L" v)]
    [(17) (format "(((~a shl 1) xor (~a shr 31)).toLong() and 0xffffffffL)" v v)]
    [(18) (format "((~a shl 1) xor (~a shr 63))" v v)]
    [(14) (format "~a.number.toLong()" v)]
    [(5) (format "~a.toLong()" v)]
    [(13 7) (format "~a.toLong()" v)]
    [(3) v]
    [else (format "~a.toLong()" v)]))

(define (kt-pb-varint-decode f v)
  (case (hash-ref f 'type)
    [(5) (format "~a.toInt()" v)]
    [(13 7) (format "~a.toUInt()" v)]
    [(3) v] [(4 6) (format "~a.toULong()" v)]
    [(8) (format "~a != 0L" v)]
    [(17) (format "(((~a shr 1) xor -(~a and 1L)).toInt())" v v)]
    [(18) (format "((~a shr 1) xor -(~a and 1L))" v v)]))

(define (kt-pb-nonzero f v)
  (case (hash-ref f 'type)
    [(8) v]
    [(14) (format "~a.number != 0" v)]
    [else (format "~a != ~a" v (second (kt-pb-scalar f)))]))

(define (kt-pb-encode-singular model f v indent)
  (define n (hash-ref f 'number))
  (define type (hash-ref f 'type))
  ;; Proto2 optional/required fields have explicit presence.
  (define proto2? (equal? (hash-ref model 'syntax "") "proto2"))
  (cond [(memv type kt-pb-varint-types)
         (if proto2?
             (format "~a{ w.tag(~a, 0); w.varint(~a) }\n" indent n (kt-pb-varint-expr f v))
             (format "~aif (~a) { w.tag(~a, 0); w.varint(~a) }\n" indent (kt-pb-nonzero f v) n (kt-pb-varint-expr f v)))]
        [(assv type kt-pb-fixed)
         => (lambda (info)
              (if proto2?
                  (format "~a{ w.tag(~a, ~a); w.fixed~a(~a) }\n" indent n
                          (if (= (second info) 8) 1 5) (third info) v)
                  (format "~aif (~a) { w.tag(~a, ~a); w.fixed~a(~a) }\n" indent (kt-pb-nonzero f v) n
                          (if (= (second info) 8) 1 5) (third info) v)))]
        [(= type 9)
         (if proto2?
             (format "~aw.bytesField(~a, ~a.toByteArray(Charsets.UTF_8))\n" indent n v)
             (format "~aw.stringField(~a, ~a)\n" indent n v))]
        [(= type 12)
         (if proto2?
             (format "~aw.bytesField(~a, ~a)\n" indent n v)
             (format "~aif (~a.isNotEmpty()) w.bytesField(~a, ~a)\n" indent v n v))]
        [(= type 11) (format "~a~a?.let { w.bytesField(~a, it.marshalDc()) }\n" indent v n)]
        [else (error 'emit-kotlin-pb-file "unsupported field type ~a (groups)" type)]))

(define (kt-pb-set-expr sib)
  (define v (kt-pb-field-name sib))
  (case (hash-ref sib 'type)
    [(11 10) (format "~a != null" v)]
    [(9 12) (format "~a.isNotEmpty()" v)]
    [else (kt-pb-nonzero sib v)]))

;; Encode-side oneof clearing: suppress f when a later sibling is
;; set, so only the winning member is written.
(define (kt-pb-encode-guard model f code)
  (define later (oneof-later-siblings model f))
  (if (null? later)
      code
      (format "        if (!(~a)) {\n~a        }\n"
              (string-join (map kt-pb-set-expr later) " || ")
              (if (string-suffix? code "\n") code (string-append code "\n")))))

(define (kt-pb-encode-field model f support)
  (define v (kt-pb-field-name f))
  (define n (hash-ref f 'number))
  (define type (hash-ref f 'type))
  (cond [(and (= type 11)
              (eq? (hash-ref (kt-pb-resolve model (hash-ref f 'type-name)) 'kind) 'map))
         (define entry (kt-pb-resolve model (hash-ref f 'type-name)))
         (define helper (format "~a.~aEncode" support (kt-pb-map-helper-name model entry)))
         (format "        for (e in ~a) w.bytesField(~a, ~a(e.key, e.value))\n" v n helper)]
        [(not (= (hash-ref f 'label) 3)) (kt-pb-encode-singular model f v "        ")]
        [(memv type kt-pb-varint-types)
         (string-append
          (format "        if (~a.isNotEmpty()) {\n" v)
          (format "            val payload = ~a.Writer()\n" support)
          (format "            for (x in ~a) payload.varint(~a)\n" v (kt-pb-varint-expr f "x"))
          (format "            w.bytesField(~a, payload.toBytes())\n        }\n" n))]
        [(assv type kt-pb-fixed)
         => (lambda (info)
              (string-append
               (format "        if (~a.isNotEmpty()) {\n" v)
               (format "            val payload = ~a.Writer()\n" support)
               (format "            for (x in ~a) payload.fixed~a(x)\n" v (third info))
               (format "            w.bytesField(~a, payload.toBytes())\n        }\n" n)))]
        [(= type 9) (format "        for (x in ~a) w.bytesField(~a, x.toByteArray(Charsets.UTF_8))\n" v n)]
        [(= type 12) (format "        for (x in ~a) w.bytesField(~a, x)\n" v n)]
        [(= type 11) (format "        for (x in ~a) w.bytesField(~a, x.marshalDc())\n" v n)]
        [else (error 'emit-kotlin-pb-file "unsupported repeated field type ~a" type)]))

(define (kt-pb-decode-singular model f target src indent support)
  (define type (hash-ref f 'type))
  (cond [(memv type kt-pb-varint-types)
         (format "~a~a = ~a\n" indent target
                 (if (= type 14)
                     (format "~a.fromNumber(~a)" (kt-pb-entry-ref model (kt-pb-resolve model (hash-ref f 'type-name))) (kt-pb-varint-decode (hash-set f 'type 5) src))
                     (kt-pb-varint-decode f src)))]
        [(assv type kt-pb-fixed)
         => (lambda (info)
              (format "~a~a = ~a\n" indent target
                      (case (hash-ref f 'type)
                        [(2) (format "~a.bitsToFloat(~a.toUInt())" support src)]
                        [(1) (format "~a.bitsToDouble(~a.toULong())" support src)]
                        [(7) (format "~a.toUInt()" src)]
                        [(15) (format "~a.toInt()" src)]
                        [(6) (format "~a.toULong()" src)]
                        [(16) src]
                        [else src])))]
        [(= type 9) (format "~a~a = String(~a, Charsets.UTF_8)\n" indent target src)]
        [(= type 12) (format "~a~a = ~a\n" indent target src)]
        [(= type 11)
         (define ref (kt-pb-entry-ref model (kt-pb-resolve model (hash-ref f 'type-name))))
         (string-append
          (format "~a~a = ~a()\n" indent target ref)
          (format "~a~a!!.unmarshalDc(~a)\n" indent target src))]
        [else (error 'emit-kotlin-pb-file "unsupported field type ~a" type)]))

(define (kt-pb-oneof-clearing model f)
  (apply string-append
         (map (lambda (sib)
                (format "                    ~a = ~a\n" (kt-pb-field-name sib) (kt-pb-default model sib)))
              (oneof-siblings model f))))

(define (kt-pb-decode-case model f support)
  (define v (kt-pb-field-name f))
  (define type (hash-ref f 'type))
  (define head (format "                ~a -> {\n" (hash-ref f 'number)))
  (define clearing (kt-pb-oneof-clearing model f))
  (define tail "                }\n")
  (cond [(and (= type 11)
              (eq? (hash-ref (kt-pb-resolve model (hash-ref f 'type-name)) 'kind) 'map))
         (define entry (kt-pb-resolve model (hash-ref f 'type-name)))
         (define helper (format "~a.~aDecode" support (kt-pb-map-helper-name model entry)))
         (string-append head
                        (format "                    val kv = ~a(field.bytesValue)\n" helper)
                        (format "                    ~a[kv.first] = kv.second\n" v)
                        tail)]
        [(not (= (hash-ref f 'label) 3))
         (string-append head
                        clearing
                        (kt-pb-decode-singular model f v
                                               (cond [(memv type kt-pb-varint-types) "field.varintValue"]
                                                     [(assv type kt-pb-fixed) "field.fixedValue"]
                                                     [else "field.bytesValue"])
                                               "                    " support)
                        tail)]
        [(memv type kt-pb-varint-types)
         (string-append head
                        "                    if (field.wire == 2) {\n"
                        (format "                        val sub = ~a.Reader(field.bytesValue)\n" support)
                        "                        while (!sub.done()) {\n"
                        (format "                            ~a.add(~a)\n" v
                                (let ([conv (kt-pb-varint-decode f "sub.varint()")])
                                  (if (= type 14)
                                      (format "~a.fromNumber(~a)" (kt-pb-entry-ref model (kt-pb-resolve model (hash-ref f 'type-name))) (kt-pb-varint-decode (hash-set f 'type 5) "sub.varint()"))
                                      conv)))
                        "                        }\n                    } else {\n"
                        (format "                        ~a.add(~a)\n" v
                                (let ([conv (kt-pb-varint-decode f "field.varintValue")])
                                  (if (= type 14)
                                      (format "~a.fromNumber(~a)" (kt-pb-entry-ref model (kt-pb-resolve model (hash-ref f 'type-name))) (kt-pb-varint-decode (hash-set f 'type 5) "field.varintValue"))
                                      conv)))
                        "                    }\n" tail)]
        [(assv type kt-pb-fixed)
         => (lambda (info)
              (string-append head
                             "                    if (field.wire == 2) {\n"
                             (format "                        val sub = ~a.Reader(field.bytesValue)\n" support)
                             (format "                        while (!sub.done()) ~a.add(~a)\n" v
                                     (case (hash-ref f 'type)
                                       [(2) (format "~a.bitsToFloat(sub.fixed32())" support)]
                                       [(1) (format "~a.bitsToDouble(sub.fixed64())" support)]
                                       [(7) "sub.fixed32()"]
                                       [(15) "sub.fixed32().toInt()"]
                                       [else "sub.fixed64()"]))
                             "                    } else {\n"
                             (format "                        ~a.add(~a)\n" v
                                     (case (hash-ref f 'type)
                                       [(2) (format "~a.bitsToFloat(field.fixedValue.toUInt())" support)]
                                       [(1) (format "~a.bitsToDouble(field.fixedValue.toULong())" support)]
                                       [(7) "field.fixedValue.toUInt()"]
                                       [(15) "field.fixedValue.toInt()"]
                                       [(6) "field.fixedValue.toULong()"]
                                       [else "field.fixedValue"]))
                             "                    }\n" tail))]
        [(= type 9) (string-append head (format "                    ~a.add(String(field.bytesValue, Charsets.UTF_8))\n" v) tail)]
        [(= type 12) (string-append head (format "                    ~a.add(field.bytesValue)\n" v) tail)]
        [(= type 11)
         (string-append head
                        (format "                    val item = ~a()\n" (kt-pb-entry-ref model (kt-pb-resolve model (hash-ref f 'type-name))))
                        "                    item.unmarshalDc(field.bytesValue)\n"
                        (format "                    ~a.add(item)\n" v) tail)]
        [else (error 'emit-kotlin-pb-file "unsupported repeated field type ~a" type)]))

(define (kt-pb-map-helper-name model entry)
  (define rel (kt-pb-rel (hash-ref entry 'pkg) (hash-ref (hash-ref entry 'msg) 'full-name)))
  (string-join (string-split rel ".") ""))

(define (kt-pb-map-helpers model entry support)
  (define msg (hash-ref entry 'msg))
  (define base (kt-pb-map-helper-name model entry))
  (define key-f (findf (lambda (x) (= (hash-ref x 'number) 1)) (hash-ref msg 'fields)))
  (define val-f (findf (lambda (x) (= (hash-ref x 'number) 2)) (hash-ref msg 'fields)))
  (unless (and key-f val-f) (error 'emit-kotlin-pb-file "map entry ~a lacks key/value" (hash-ref msg 'full-name)))
  (define kt (kt-pb-type model (hash-set key-f 'label 1)))
  (define vt (kt-pb-type model (hash-set val-f 'label 1)))
  (define vt-plain (if (and (= (hash-ref val-f 'type) 11)
                            (not (eq? (hash-ref (kt-pb-resolve model (hash-ref val-f 'type-name)) 'kind) 'map)))
                       (kt-pb-entry-ref model (kt-pb-resolve model (hash-ref val-f 'type-name)))
                       vt))
  (string-append
   (format "    fun ~aEncode(key: ~a, value: ~a): ByteArray {\n" base kt vt-plain)
   "        val w = Writer()\n"
   (kt-pb-encode-singular model (hash-set key-f 'label 1) "key" "        ")
   (if (= (hash-ref val-f 'type) 11)
       (format "        w.bytesField(~a, value.marshalDc())\n" (hash-ref val-f 'number))
       (kt-pb-encode-singular model (hash-set val-f 'label 1) "value" "        "))
   "        return w.toBytes()\n    }\n\n"
   (format "    fun ~aDecode(bytes: ByteArray): Pair<~a, ~a> {\n" base kt vt-plain)
   (format "        var key: ~a = ~a\n" kt (kt-pb-default model (hash-set key-f 'label 1)))
   (format "        var value: ~a = ~a\n" vt-plain (if (= (hash-ref val-f 'type) 11) (format "~a()" vt-plain) (kt-pb-default model (hash-set val-f 'label 1))))
   "        val r = Reader(bytes)\n        while (true) {\n            val field = r.next() ?: break\n            when (field.number) {\n"
   (format "                ~a -> ~a\n" (hash-ref key-f 'number)
           (string-trim (kt-pb-decode-singular model (hash-set key-f 'label 1) "key"
                                               (cond [(memv (hash-ref key-f 'type) kt-pb-varint-types) "field.varintValue"]
                                                     [(assv (hash-ref key-f 'type) kt-pb-fixed) "field.fixedValue"]
                                                     [else "field.bytesValue"]) "" support) "\n" #:left? #f #:repeat? #t))
   (format "                ~a -> ~a\n" (hash-ref val-f 'number)
           (if (= (hash-ref val-f 'type) 11)
               "value.unmarshalDc(field.bytesValue)"
               (string-trim (kt-pb-decode-singular model (hash-set val-f 'label 1) "value"
                                                   (cond [(memv (hash-ref val-f 'type) kt-pb-varint-types) "field.varintValue"]
                                                         [(assv (hash-ref val-f 'type) kt-pb-fixed) "field.fixedValue"]
                                                         [else "field.bytesValue"]) "" support) "\n" #:left? #f #:repeat? #t)))
   "                else -> {}\n            }\n        }\n        return Pair(key, value)\n    }\n\n"))

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
  (define name (hash-ref msg 'name))
  (define fields (hash-ref msg 'fields))
  (string-append
   (format "~a~a class ~a(\n" indent decl name)
   (string-join (map (lambda (f)
                       (format "~a    var ~a: ~a = ~a" indent (kt-pb-field-name f) (kt-pb-type model f) (kt-pb-default model f)))
                     fields) ",\n")
   (if (null? fields) "" ",")
   (format "\n~a) : Marshaler, Unmarshaler {\n" indent)
   (format "~a    var unknownFields: ByteArray = ByteArray(0)\n" indent)
   (format "~a    override fun marshalDc(): ByteArray {\n" indent)
   (format "~a        val w = ~a.Writer()\n" indent support)
   (apply string-append (map (lambda (f) (kt-pb-encode-guard model f (kt-pb-encode-field model f support))) fields))
   (format "~a        w.raw(unknownFields)\n" indent)
   (format "~a        return w.toBytes()\n~a    }\n" indent indent)
   (format "~a    override fun unmarshalDc(data: ByteArray) {\n" indent)
   (format "~a        unknownFields = ByteArray(0)\n" indent)
   (apply string-append
          (map (lambda (f) (format "~a        ~a = ~a\n" indent (kt-pb-field-name f) (kt-pb-default model f))) fields))
   (format "~a        val r = ~a.Reader(data)\n" indent support)
   (format "~a        while (true) {\n" indent)
   (format "~a            val field = r.next() ?: break\n" indent)
   (format "~a            when (field.number) {\n" indent)
   (apply string-append (map (lambda (f) (kt-pb-decode-case model f support)) fields))
   (format "~a                else -> { unknownFields = unknownFields + field.rawValue }\n~a            }\n~a        }\n~a    }\n" indent indent indent indent)
   (apply string-append (map (lambda (n) (kt-pb-message-class model n support (string-append indent "    ") "")) (hash-ref msg 'nested)))
   (apply string-append (map (lambda (e) (kt-pb-nested-enum e (string-append indent "    "))) (hash-ref msg 'enums)))
   (format "~a}\n" indent)))

(define (kt-pb-nested-enum e indent)
  (string-append
   (format "~aenum class ~a(val number: Int) {\n" indent (hash-ref e 'name))
   (string-join (map (lambda (v) (format "~a    ~a(~a)" indent (hash-ref v 'name) (hash-ref v 'number)))
                     (hash-ref e 'values)) ",\n")
   (format ";\n~a    companion object {\n" indent)
   (format "~a        fun fromNumber(number: Int): ~a =\n" indent (hash-ref e 'name))
   (format "~a            when (number) {\n" indent)
   (apply string-append
          (map (lambda (v) (format "~a                ~a -> ~a\n" indent (hash-ref v 'number) (hash-ref v 'name)))
               (hash-ref e 'values)))
   (format "~a                else -> ~a\n~a            }\n~a    }\n~a}\n" indent (hash-ref (car (hash-ref e 'values)) 'name) indent indent indent)))

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
                (map kotlin-service (hash-ref file-model 'services)))
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
