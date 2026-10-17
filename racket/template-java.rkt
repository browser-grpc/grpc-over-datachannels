#lang racket

;;; template-java.rkt — emitter body spliced into
;;; protoc-gen-grpc-dc-java.
;;;
;;; Generated code is one final class <Base>GrpcDc in the proto's
;;; package, beside hand-written message types implementing
;;; grpcdc.Marshaler / grpcdc.Unmarshaler, importing the runtime as
;;; grpcdc.*. Method names keep the proto spelling, mirroring Go.

(require "spec.rkt" "desc.rkt")
(provide emit-java-file)

(define current-service (make-parameter ""))

(define (pascal sym) ; echo_service -> EchoService
  (apply string-append
         (for/list ([part (in-list (string-split (symbol->string sym) "[_-]"))])
           (if (string=? part "")
               ""
               (string-append (string (char-upcase (string-ref part 0)))
                              (substring part 1))))))

(define (lower-first s)
  (string-append (string (char-downcase (string-ref s 0))) (substring s 1)))

(define (java-deprecated m indent)
  (if (hash-ref m 'deprecated #f)
      (format "~a@Deprecated\n" indent)
      ""))

(define (java-client-method/raw m)
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define path (hash-ref m 'path))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(unary)
     (format (string-append
              "        public ~a ~a(~a req, Map<String, String> metadata) throws Exception {\n"
              "            ~a resp = new ~a();\n"
              "            channel.unary(~s, req, resp, metadata);\n"
              "            return resp;\n"
              "        }\n\n"
              "        public ~a ~a(~a req) throws Exception {\n"
              "            return ~a(req, null);\n"
              "        }\n")
             resp name req resp resp path resp name req name)]
    [(server-streaming)
     (format (string-append
              "        public ~a~aStream ~a(~a req, Map<String, String> metadata) throws Exception {\n"
              "            return new ~a~aStream(channel.serverStream(~s, req, metadata));\n"
              "        }\n\n"
              "        public ~a~aStream ~a(~a req) throws Exception {\n"
              "            return ~a(req, null);\n"
              "        }\n")
             svc name name req svc name path svc name name req name)]
    [(client-streaming)
     (format (string-append
              "        public ~a ~a(List<~a> reqs, Map<String, String> metadata) throws Exception {\n"
              "            ~a resp = new ~a();\n"
              "            channel.clientStream(~s, reqs, resp, metadata);\n"
              "            return resp;\n"
              "        }\n\n"
              "        public ~a ~a(List<~a> reqs) throws Exception {\n"
              "            return ~a(reqs, null);\n"
              "        }\n")
             resp name req resp resp path resp name req name)]
    [(bidi)
     (format (string-append
              "        public ~a~aStream ~a(List<~a> reqs, Map<String, String> metadata) throws Exception {\n"
              "            return new ~a~aStream(channel.bidi(~s, reqs, metadata));\n"
              "        }\n\n"
              "        public ~a~aStream ~a(List<~a> reqs) throws Exception {\n"
              "            return ~a(reqs, null);\n"
              "        }\n")
             svc name name req svc name path svc name name req name)]))

(define (java-client-method m)
  (string-append (java-deprecated m "        ") (java-client-method/raw m)))

(define (java-client-timeout-method m)
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define path (hash-ref m 'path))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(unary)
     (format (string-append
              "\n        /** Deadline variant: timeout propagates as grpc-timeout; expiry raises DEADLINE_EXCEEDED. */\n"
              "        public ~a ~a(~a req, Map<String, String> metadata, java.time.Duration timeout) throws Exception {\n"
              "            ~a resp = new ~a();\n"
              "            channel.unary(~s, req, resp, metadata, timeout);\n"
              "            return resp;\n"
              "        }\n")
             resp name req resp resp path)]
    [(server-streaming)
     (format (string-append
              "\n        /** Deadline variant of ~a. */\n"
              "        public ~a~aStream ~a(~a req, Map<String, String> metadata, java.time.Duration timeout) throws Exception {\n"
              "            return new ~a~aStream(channel.serverStream(~s, req, metadata, timeout));\n"
              "        }\n")
             name svc name name req svc name path)]
    [(client-streaming)
     (format (string-append
              "\n        /** Deadline variant of ~a. */\n"
              "        public ~a ~a(List<~a> reqs, Map<String, String> metadata, java.time.Duration timeout) throws Exception {\n"
              "            ~a resp = new ~a();\n"
              "            channel.clientStream(~s, reqs, resp, metadata, timeout);\n"
              "            return resp;\n"
              "        }\n")
             name resp name req resp resp path)]
    [(bidi)
     (format (string-append
              "\n        /** Deadline variant of ~a. */\n"
              "        public ~a~aStream ~a(List<~a> reqs, Map<String, String> metadata, java.time.Duration timeout) throws Exception {\n"
              "            return new ~a~aStream(channel.bidi(~s, reqs, metadata, timeout));\n"
              "        }\n")
             name svc name name req svc name path)]))

(define (java-client-stream-class m)
  (define name (hash-ref m 'name))
  (define resp (hash-ref m 'output))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(server-streaming bidi)
     (format (string-append
              "    /** Receiving stream for ~a.~a: recv() throws EOFException at end. */\n"
              "    public static final class ~a~aStream {\n"
              "        private final Channel.ClientStream stream;\n\n"
              "        ~a~aStream(Channel.ClientStream stream) {\n"
              "            this.stream = stream;\n"
              "        }\n\n"
              "        public ~a recv() throws Exception {\n"
              "            ~a resp = new ~a();\n"
              "            stream.recv(resp);\n"
              "            return resp;\n"
              "        }\n"
              "    }\n\n")
             svc name svc name svc name resp resp resp)]
    [else ""]))

(define (java-server-iface-method/raw m)
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(unary)
     (format "        ~a ~a(Endpoint.CallContext ctx, ~a req) throws Exception;\n" resp name req)]
    [(server-streaming)
     (format "        void ~a(~a req, ~a~aServer stream) throws Exception;\n" name req svc name)]
    [(client-streaming)
     (format "        void ~a(~a~aServer stream) throws Exception;\n" name svc name)]
    [(bidi)
     (format "        void ~a(~a~aServer stream) throws Exception;\n" name svc name)]))

(define (java-server-iface-method m)
  (string-append (java-deprecated m "        ") (java-server-iface-method/raw m)))

(define (java-server-stream-ifaces m)
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(unary) ""]
    [(server-streaming)
     (format (string-append
              "    /** Server-streaming sink passed to service implementations. */\n"
              "    public interface ~a~aServer {\n"
              "        void send(~a resp) throws Exception;\n"
              "        Endpoint.CallContext context();\n"
              "    }\n\n")
             svc name resp)]
    [(client-streaming)
     (format (string-append
              "    /** Client-streaming stream passed to service implementations. */\n"
              "    public interface ~a~aServer {\n"
              "        ~a recv() throws Exception;\n"
              "        void sendAndClose(~a resp) throws Exception;\n"
              "        Endpoint.CallContext context();\n"
              "    }\n\n")
             svc name req resp)]
    [(bidi)
     (format (string-append
              "    /** Bidi stream passed to service implementations. */\n"
              "    public interface ~a~aServer {\n"
              "        void send(~a resp) throws Exception;\n"
              "        ~a recv() throws Exception;\n"
              "        Endpoint.CallContext context();\n"
              "    }\n\n")
             svc name resp req)]))

(define (java-register-method m)
  (define name (hash-ref m 'name))
  (define impl-name (method-impl-name m))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
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
              "                    new Server.Method(~s, ~s, Server.~a, (ctx, reqs, sink) -> {\n"
              "                        ~a req = new ~a();\n"
              "                        reqs.recvInto(req);\n"
              "                        sink.send(impl.~a(ctx, req).marshalDc());\n"
              "                    }),\n")
             name (hash-ref m 'path) kind-const req req impl-name)]
    [(server-streaming)
     (format (string-append
              "                    new Server.Method(~s, ~s, Server.~a, (ctx, reqs, sink) -> {\n"
              "                        ~a req = new ~a();\n"
              "                        reqs.recvInto(req);\n"
              "                        impl.~a(req, new ~a~aServerImpl(ctx, sink));\n"
              "                    }),\n")
             name (hash-ref m 'path) kind-const req req impl-name svc impl-name)]
    [(client-streaming)
     (format (string-append
              "                    new Server.Method(~s, ~s, Server.~a, (ctx, reqs, sink) -> {\n"
              "                        ~a~aServerImpl stream = new ~a~aServerImpl(ctx, reqs);\n"
              "                        impl.~a(stream);\n"              "                        if (stream.resp == null) {\n"
              "                            throw new StatusException(Wire.CODE_INTERNAL,\n"
              "                                    \"client-streaming handler never called SendAndClose\");\n"
              "                        }\n"
              "                        sink.send(stream.resp.marshalDc());\n"
              "                    }),\n")
             name (hash-ref m 'path) kind-const svc impl-name svc impl-name impl-name)]
    [(bidi)
     (format (string-append
              "                    new Server.Method(~s, ~s, Server.~a, (ctx, reqs, sink) -> {\n"
              "                        impl.~a(new ~a~aServerImpl(ctx, reqs, sink));\n"
              "                    }),\n")
             name (hash-ref m 'path) kind-const impl-name svc impl-name)]))

(define (java-stream-impls m)
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(unary) ""]
    [(server-streaming)
     (format (string-append
              "    private static final class ~a~aServerImpl implements ~a~aServer {\n"
              "        private final Endpoint.CallContext ctx;\n"
              "        private final Server.ServerSink sink;\n\n"
              "        ~a~aServerImpl(Endpoint.CallContext ctx, Server.ServerSink sink) {\n"
              "            this.ctx = ctx;\n"
              "            this.sink = sink;\n"
              "        }\n\n"
              "        public void send(~a resp) throws Exception {\n"
              "            sink.send(resp.marshalDc());\n"
              "        }\n\n"
              "        public Endpoint.CallContext context() {\n"
              "            return ctx;\n"
              "        }\n"
              "    }\n\n")
             svc name svc name svc name resp)]
    [(client-streaming)
     (format (string-append
              "    private static final class ~a~aServerImpl implements ~a~aServer {\n"
              "        private final Endpoint.CallContext ctx;\n"
              "        private final Server.RequestStream reqs;\n"
              "        ~a resp;\n\n"
              "        ~a~aServerImpl(Endpoint.CallContext ctx, Server.RequestStream reqs) {\n"
              "            this.ctx = ctx;\n"
              "            this.reqs = reqs;\n"
              "        }\n\n"
              "        public ~a recv() throws Exception {\n"
              "            ~a req = new ~a();\n"
              "            reqs.recvInto(req);\n"
              "            return req;\n"
              "        }\n\n"
              "        public void sendAndClose(~a resp) {\n"
              "            this.resp = resp;\n"
              "        }\n\n"
              "        public Endpoint.CallContext context() {\n"
              "            return ctx;\n"
              "        }\n"
              "    }\n\n")
             svc name svc name resp svc name req req req resp)]
    [(bidi)
     (format (string-append
              "    private static final class ~a~aServerImpl implements ~a~aServer {\n"
              "        private final Endpoint.CallContext ctx;\n"
              "        private final Server.RequestStream reqs;\n"
              "        private final Server.ServerSink sink;\n\n"
              "        ~a~aServerImpl(Endpoint.CallContext ctx, Server.RequestStream reqs, Server.ServerSink sink) {\n"
              "            this.ctx = ctx;\n"
              "            this.reqs = reqs;\n"
              "            this.sink = sink;\n"
              "        }\n\n"
              "        public void send(~a resp) throws Exception {\n"
              "            sink.send(resp.marshalDc());\n"
              "        }\n\n"
              "        public ~a recv() throws Exception {\n"
              "            ~a req = new ~a();\n"
              "            reqs.recvInto(req);\n"
              "            return req;\n"
              "        }\n\n"
              "        public Endpoint.CallContext context() {\n"
              "            return ctx;\n"
              "        }\n"
              "    }\n\n")
             svc name svc name svc name resp req req req)]))


(define (java-client-async-method m)
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(unary)
     (format (string-append
              "        public CompletableFuture<~a> ~aAsync(~a req, Map<String, String> metadata) {\n"
              "            return CompletableFuture.supplyAsync(() -> {\n"
              "                try {\n"
              "                    return ~a(req, metadata);\n"
              "                } catch (Exception e) {\n"
              "                    throw new CompletionException(e);\n"
              "                }\n"
              "            });\n"
              "        }\n\n"
              "        public CompletableFuture<~a> ~aAsync(~a req) {\n"
              "            return ~aAsync(req, null);\n"
              "        }\n")
             resp name req name resp name req name)]
    [(server-streaming)
     (format (string-append
              "        /** Collect-all async convenience over the blocking stream. */\n"
              "        public CompletableFuture<List<~a>> ~aAllAsync(~a req, Map<String, String> metadata) {\n"
              "            return CompletableFuture.supplyAsync(() -> {\n"
              "                try {\n"
              "                    List<~a> out = new ArrayList<>();\n"
              "                    ~a~aStream stream = ~a(req, metadata);\n"
              "                    while (true) {\n"
              "                        try {\n"
              "                            out.add(stream.recv());\n"
              "                        } catch (java.io.EOFException eof) {\n"
              "                            return out;\n"
              "                        }\n"
              "                    }\n"
              "                } catch (Exception e) {\n"
              "                    throw new CompletionException(e);\n"
              "                }\n"
              "            });\n"
              "        }\n\n"
              "        public CompletableFuture<List<~a>> ~aAllAsync(~a req) {\n"
              "            return ~aAllAsync(req, null);\n"
              "        }\n")
             resp name req resp svc name name resp name req name)]
    [(client-streaming)
     (format (string-append
              "        public CompletableFuture<~a> ~aAsync(List<~a> reqs, Map<String, String> metadata) {\n"
              "            return CompletableFuture.supplyAsync(() -> {\n"
              "                try {\n"
              "                    return ~a(reqs, metadata);\n"
              "                } catch (Exception e) {\n"
              "                    throw new CompletionException(e);\n"
              "                }\n"
              "            });\n"
              "        }\n\n"
              "        public CompletableFuture<~a> ~aAsync(List<~a> reqs) {\n"
              "            return ~aAsync(reqs, null);\n"
              "        }\n")
             resp name req name resp name req name)]
    [(bidi)
     (format (string-append
              "        /** Collect-all async convenience over the blocking stream. */\n"
              "        public CompletableFuture<List<~a>> ~aAllAsync(List<~a> reqs, Map<String, String> metadata) {\n"
              "            return CompletableFuture.supplyAsync(() -> {\n"
              "                try {\n"
              "                    List<~a> out = new ArrayList<>();\n"
              "                    ~a~aStream stream = ~a(reqs, metadata);\n"
              "                    while (true) {\n"
              "                        try {\n"
              "                            out.add(stream.recv());\n"
              "                        } catch (java.io.EOFException eof) {\n"
              "                            return out;\n"
              "                        }\n"
              "                    }\n"
              "                } catch (Exception e) {\n"
              "                    throw new CompletionException(e);\n"
              "                }\n"
              "            });\n"
              "        }\n\n"
              "        public CompletableFuture<List<~a>> ~aAllAsync(List<~a> reqs) {\n"
              "            return ~aAllAsync(reqs, null);\n"
              "        }\n")
             resp name req resp svc name name resp name req name)]))

(define (java-server-async-iface-method m)
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(unary)
     (format "        CompletableFuture<~a> ~aAsync(Endpoint.CallContext ctx, ~a req);\n" resp name req)]
    [(server-streaming)
     (format "        CompletableFuture<Void> ~aAsync(~a req, ~a~aServer stream);\n" name req svc name)]
    [(client-streaming)
     (format "        CompletableFuture<Void> ~aAsync(~a~aServer stream);\n" name svc name)]
    [(bidi)
     (format "        CompletableFuture<Void> ~aAsync(~a~aServer stream);\n" name svc name)]))

(define (java-server-async-adapter-method m)
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(unary)
     (format (string-append
              "        public ~a ~a(Endpoint.CallContext ctx, ~a req) throws Exception {\n"
              "            try {\n"
              "                return impl.~aAsync(ctx, req).join();\n"
              "            } catch (CompletionException e) {\n"
              "                Throwable cause = e.getCause();\n"
              "                if (cause instanceof Exception ex) throw ex;\n"
              "                throw e;\n"
              "            }\n"
              "        }\n\n")
             resp name req name)]
    [(server-streaming)
     (format (string-append
              "        public void ~a(~a req, ~a~aServer stream) throws Exception {\n"
              "            try {\n"
              "                impl.~aAsync(req, stream).join();\n"
              "            } catch (CompletionException e) {\n"
              "                Throwable cause = e.getCause();\n"
              "                if (cause instanceof Exception ex) throw ex;\n"
              "                throw e;\n"
              "            }\n"
              "        }\n\n")
             name req svc name name)]
    [(client-streaming)
     (format (string-append
              "        public void ~a(~a~aServer stream) throws Exception {\n"
              "            try {\n"
              "                impl.~aAsync(stream).join();\n"
              "            } catch (CompletionException e) {\n"
              "                Throwable cause = e.getCause();\n"
              "                if (cause instanceof Exception ex) throw ex;\n"
              "                throw e;\n"
              "            }\n"
              "        }\n\n")
             name svc name name)]
    [(bidi)
     (format (string-append
              "        public void ~a(~a~aServer stream) throws Exception {\n"
              "            try {\n"
              "                impl.~aAsync(stream).join();\n"
              "            } catch (CompletionException e) {\n"
              "                Throwable cause = e.getCause();\n"
              "                if (cause instanceof Exception ex) throw ex;\n"
              "                throw e;\n"
              "            }\n"
              "        }\n\n")
             name svc name name)]))

(define (java-service svc)
  (define sname (hash-ref svc 'name))
  (define methods (hash-ref svc 'methods))
  (parameterize ([current-service sname])
    (string-append
     (format "    /** Client for ~a. */\n" (hash-ref svc 'full-name))
     (format "    public static final class ~aClient {\n" sname)
     "        private final Channel channel;\n\n"
     (format "        public ~aClient(Channel channel) {\n            this.channel = channel;\n        }\n\n" sname)
     (apply string-append (map (lambda (m) (string-append (java-client-method m) (java-client-timeout-method m))) (append methods (alias-client-methods svc))))
     (apply string-append (map java-client-async-method (append methods (alias-client-methods svc))))
     "    }\n\n"
     (apply string-append (map java-client-stream-class methods))
     (format "    /** Service implementation interface for ~a. */\n" (hash-ref svc 'full-name))
     (format "    public interface ~aServer {\n" sname)
     (apply string-append (map java-server-iface-method methods))
     "    }\n\n"
     (apply string-append (map java-server-stream-ifaces methods))
     (apply string-append (map java-stream-impls methods))
     (format "    /** Async service implementation interface for ~a. */\n" (hash-ref svc 'full-name))
     (format "    public interface ~aServerAsync {\n" sname)
     (apply string-append (map java-server-async-iface-method methods))
     "    }\n\n"
     (format "    private static final class ~aServerAsyncAdapter implements ~aServer {\n" sname sname)
     (format "        private final ~aServerAsync impl;\n\n" sname)
     (format "        ~aServerAsyncAdapter(~aServerAsync impl) {\n            this.impl = impl;\n        }\n\n" sname sname)
     (apply string-append (map java-server-async-adapter-method methods))
     "    }\n\n"
     (format "    /** Register an implementation of ~a on a Server. */\n" (hash-ref svc 'full-name))
     (format "    public static void register~aServer(Server server, ~aServer impl) {\n" sname sname)
     (format "        server.registerService(new Server.ServiceDesc(\n                ~s,\n                List.of(\n"
             (hash-ref svc 'full-name))
     (string-join
      (map (lambda (m)
             (regexp-replace #rx"\\}\\),[ \t\r\n]*$" (java-register-method m) "})"))
           (append methods (alias-server-methods svc)))
      ",\n")
     "\n                )));\n    }\n"
     (format "    /** Register an async implementation of ~a on a Server. */\n" (hash-ref svc 'full-name))
     (format "    public static void register~aServerAsync(Server server, ~aServerAsync impl) {\n" sname sname)
     (format "        register~aServer(server, new ~aServerAsyncAdapter(impl));\n    }\n" sname sname))))

;; ---------------------------------------------------------------------------
;; Java message types: one public class per top-level message and
;; one enum per top-level enum, plus a package-private <Base>Pb
;; wire-support class per proto file. Dependency-free (JDK only),
;; implementing grpcdc.Marshaler/Unmarshaler. Mirrors the Python
;; emitter on the shared desc.rkt model.
;; ---------------------------------------------------------------------------

(define java-pb-varint-types '(5 3 13 4 17 18 8 14))
(define java-pb-fixed '((2 4 "Float") (1 8 "Double") (7 4 "Int") (15 4 "Int") (6 8 "Long") (16 8 "Long")))

(define (java-pb-camel s)
  (define parts (string-split s "_"))
  (if (null? parts)
      s
      (apply string-append (car parts)
             (map (lambda (p) (if (string=? p "") "" (string-append (string (char-upcase (string-ref p 0))) (substring p 1))))
                  (cdr parts)))))

(define (java-pb-field-name f)
  (define jn (hash-ref f 'json-name ""))
  (if (and jn (not (string=? jn ""))) jn (java-pb-camel (hash-ref f 'name))))

(define (java-pb-resolve model type-name)
  (hash-ref (hash-ref model 'types) type-name
            (lambda () (error 'emit-java-pb-file "unresolved type ~a" type-name))))

;; Java type reference for a registry entry, from file-model's
;; package: same package -> Outer.Inner; other package -> fully
;; qualified.
(define (java-pb-entry-ref model entry)
  (define rel
    (if (eq? (hash-ref entry 'kind) 'enum)
        (let ([e (hash-ref entry 'enum)])
          (if (hash-ref entry 'msg)
              (string-append (java-pb-rel (hash-ref entry 'pkg) (hash-ref (hash-ref entry 'msg) 'full-name)) "." (hash-ref e 'name))
              (java-pb-rel (hash-ref entry 'pkg) (format "~a.~a" (hash-ref entry 'pkg) (hash-ref e 'name)))))
        (java-pb-rel (hash-ref entry 'pkg) (hash-ref (hash-ref entry 'msg) 'full-name))))
  (if (equal? (hash-ref entry 'file) (hash-ref model 'name))
      rel
      (if (string=? (hash-ref entry 'pkg) "") rel (string-append (hash-ref entry 'pkg) "." rel))))

(define (java-pb-rel pkg full)
  (define rel (if (and pkg (not (string=? pkg "")) (string-prefix? full (string-append pkg ".")))
                  (substring full (add1 (string-length pkg)))
                  full))
  (string-join (string-split rel ".") "."))

(define (java-pb-scalar f)
  (case (hash-ref f 'type)
    [(1) '("double" "Double" "0")] [(2) '("float" "Float" "0")]
    [(3) '("long" "Long" "0L")] [(4) '("long" "Long" "0L")] [(5) '("int" "Integer" "0")]
    [(6) '("long" "Long" "0L")] [(7) '("int" "Integer" "0")] [(8) '("boolean" "Boolean" "false")]
    [(9) '("String" "String" "\"\"")] [(12) '("byte[]" "byte[]" "new byte[0]")]
    [(13) '("int" "Integer" "0")] [(15) '("int" "Integer" "0")] [(16) '("long" "Long" "0L")]
    [(17) '("int" "Integer" "0")] [(18) '("long" "Long" "0L")]
    [else #f]))

(define (java-pb-type model f boxed?)
  (define type (hash-ref f 'type))
  (define singular
    (cond [(= type 11)
           (define entry (java-pb-resolve model (hash-ref f 'type-name)))
           (if (eq? (hash-ref entry 'kind) 'map)
               (let* ([em (hash-ref entry 'msg)]
                      [kf (findf (lambda (x) (= (hash-ref x 'number) 1)) (hash-ref em 'fields))]
                      [vf (findf (lambda (x) (= (hash-ref x 'number) 2)) (hash-ref em 'fields))])
                 (format "java.util.Map<~a, ~a>" (java-pb-type model (hash-set kf 'label 1) #t)
                         (java-pb-type model (hash-set vf 'label 1) #t)))
               (java-pb-entry-ref model entry))]
          [(= type 14) (java-pb-entry-ref model (java-pb-resolve model (hash-ref f 'type-name)))]
          [else (let ([s (java-pb-scalar f)]) (if boxed? (second s) (first s)))]))
  (cond [(and (= type 11)
              (eq? (hash-ref (java-pb-resolve model (hash-ref f 'type-name)) 'kind) 'map))
         singular]
        [(= (hash-ref f 'label) 3) (format "java.util.List<~a>" (java-pb-type model (hash-set f 'label 1) #t))]
        [else singular]))

(define (java-pb-default model f)
  (cond [(and (= (hash-ref f 'type) 11)
              (eq? (hash-ref (java-pb-resolve model (hash-ref f 'type-name)) 'kind) 'map))
         "new java.util.LinkedHashMap<>()"]
        [(= (hash-ref f 'label) 3) "new java.util.ArrayList<>()"]
        [(= (hash-ref f 'type) 11) "null"]
        [(= (hash-ref f 'type) 14)
         (define entry (java-pb-resolve model (hash-ref f 'type-name)))
         (define vals (hash-ref (hash-ref entry 'enum) 'values))
         (format "~a.~a" (java-pb-entry-ref model entry) (hash-ref (car vals) 'name))]
        [else (third (java-pb-scalar f))]))

(define (java-pb-varint-expr f v)
  (case (hash-ref f 'type)
    [(8) (format "(~a ? 1 : 0)" v)]
    [(17) (format "((~a << 1) ^ (~a >> 31))" v v)]
    [(18) (format "((~a << 1) ^ (~a >> 63))" v v)]
    [else v]))

(define (java-pb-varint-decode f v)
  (case (hash-ref f 'type)
    [(5) (format "(int) ~a" v)]
    [(14) (format "(int) ~a" v)]
    [(13) (format "(int) ~a" v)]
    [(3) v] [(4) v]
    [(8) (format "~a != 0" v)]
    [(17) (format "(int) ((~a >>> 1) ^ -(~a & 1))" v v)]
    [(18) (format "((~a >>> 1) ^ -(~a & 1))" v v)]))

(define (java-pb-encode-singular model f v indent support)
  (define n (hash-ref f 'number))
  (define type (hash-ref f 'type))
  (cond [(memv type java-pb-varint-types)
         (format "~aif (~a) { w.tag(~a, 0); w.varint(~a); }\n" indent
                 (java-pb-nonzero f v) n
                 (if (= type 14) (format "~a.number" v) (java-pb-varint-expr f v)))]
        [(assv type java-pb-fixed)
         => (lambda (info)
              (format "~aif (~a) { w.tag(~a, ~a); w.fixed~a(~a); }\n" indent (java-pb-nonzero f v) n
                      (if (= (second info) 8) 1 5) (third info)
                      (java-pb-fixed-bits info f v)))]
        [(= type 9) (format "~aw.stringField(~a, ~a);\n" indent n v)]
        [(= type 12) (format "~aif (~a != null && ~a.length > 0) w.bytesField(~a, ~a);\n" indent v v n v)]
        [(= type 11) (format "~aif (~a != null) w.bytesField(~a, ~a.marshalDc());\n" indent v n v)]
        [else (error 'emit-java-pb-file "unsupported field type ~a (groups)" type)]))

(define (java-pb-nonzero f v)
  (case (hash-ref f 'type)
    [(8) v]
    [(14) (format "~a != null && ~a.number != 0" v v)]
    [else (format "~a != 0" v)]))

(define (java-pb-fixed-bits info f v)
  ;; The support Writer's fixed* methods take the value itself.
  v)

(define (java-pb-encode-field model f support)
  (define v (java-pb-field-name f))
  (define n (hash-ref f 'number))
  (define type (hash-ref f 'type))
  (cond [(and (= type 11)
              (eq? (hash-ref (java-pb-resolve model (hash-ref f 'type-name)) 'kind) 'map))
         (define entry (java-pb-resolve model (hash-ref f 'type-name)))
         (define helper (format "~a.~aEncode" support (java-pb-map-helper-name model entry)))
         (format "        if (~a != null) for (java.util.Map.Entry<~a, ~a> e : ~a.entrySet()) w.bytesField(~a, ~a(e.getKey(), e.getValue()));\n"
                 v (java-pb-type model (hash-set (findf (lambda (x) (= (hash-ref x 'number) 1)) (hash-ref (hash-ref entry 'msg) 'fields)) 'label 1) #t)
                 (java-pb-type model (hash-set (findf (lambda (x) (= (hash-ref x 'number) 2)) (hash-ref (hash-ref entry 'msg) 'fields)) 'label 1) #t)
                 v n helper)]
        [(not (= (hash-ref f 'label) 3)) (java-pb-encode-singular model f v "        " support)]
        [(memv type java-pb-varint-types)
         (string-append
          (format "        if (~a != null && !~a.isEmpty()) {\n" v v)
          (format "            ~a.Writer payload = new ~a.Writer();\n" support support)
          (format "            for (~a x : ~a) payload.varint(~a);\n" (java-pb-type model (hash-set f 'label 1) #t) v
                  (if (= type 14) "x.number" (java-pb-varint-expr f "x")))
          (format "            w.bytesField(~a, payload.toBytes());\n        }\n" n))]
        [(assv type java-pb-fixed)
         => (lambda (info)
              (string-append
               (format "        if (~a != null && !~a.isEmpty()) {\n" v v)
               (format "            ~a.Writer payload = new ~a.Writer();\n" support support)
               (format "            for (~a x : ~a) payload.fixed~a(~a);\n" (java-pb-type model (hash-set f 'label 1) #t) v (third info) (java-pb-fixed-bits info f "x"))
               (format "            w.bytesField(~a, payload.toBytes());\n        }\n" n)))]
        [(= type 9) (format "        if (~a != null) for (String x : ~a) w.bytesField(~a, x.getBytes(java.nio.charset.StandardCharsets.UTF_8));\n" v v n)]
        [(= type 12) (format "        if (~a != null) for (byte[] x : ~a) w.bytesField(~a, x);\n" v v n)]
        [(= type 11) (format "        if (~a != null) for (~a x : ~a) w.bytesField(~a, x.marshalDc());\n" v (java-pb-type model (hash-set f 'label 1) #t) v n)]
        [else (error 'emit-java-pb-file "unsupported repeated field type ~a" type)]))

(define (java-pb-decode-singular model f target src indent)
  (define type (hash-ref f 'type))
  (cond [(memv type java-pb-varint-types)
         (format "~a~a = ~a;\n" indent target
                 (if (= type 14)
                     (format "~a.fromNumber(~a)" (java-pb-entry-ref model (java-pb-resolve model (hash-ref f 'type-name))) (java-pb-varint-decode (hash-set f 'type 5) src))
                     (java-pb-varint-decode f src)))]
        [(assv type java-pb-fixed)
         => (lambda (info)
              (format "~a~a = ~a;\n" indent target
                      (case (hash-ref f 'type)
                        [(2) (format "Float.intBitsToFloat((int) ~a)" src)]
                        [(1) (format "Double.longBitsToDouble(~a)" src)]
                        [(7 15) (format "(int) ~a" src)]
                        [else src])))]
        [(= type 9) (format "~a~a = new String(~a, java.nio.charset.StandardCharsets.UTF_8);\n" indent target src)]
        [(= type 12) (format "~a~a = ~a;\n" indent target src)]
        [(= type 11)
         (define ref (java-pb-entry-ref model (java-pb-resolve model (hash-ref f 'type-name))))
         (string-append
          (format "~a~a = new ~a();\n" indent target ref)
          (format "~a~a.unmarshalDc(~a);\n" indent target src))]
        [else (error 'emit-java-pb-file "unsupported field type ~a" type)]))

(define (java-pb-decode-case model f support)
  (define v (java-pb-field-name f))
  (define type (hash-ref f 'type))
  (define head (format "                case ~a -> {\n" (hash-ref f 'number)))
  (define tail "                }\n")
  (cond [(and (= type 11)
              (eq? (hash-ref (java-pb-resolve model (hash-ref f 'type-name)) 'kind) 'map))
         (define entry (java-pb-resolve model (hash-ref f 'type-name)))
         (define helper (format "~a.~aDecode" support (java-pb-map-helper-name model entry)))
         (string-append head
                        (format "                    Object[] kv = ~a(field.bytesValue);\n" helper)
                        (format "                    ~a.put((~a) kv[0], (~a) kv[1]);\n" v
                                (java-pb-type model (hash-set (findf (lambda (x) (= (hash-ref x 'number) 1)) (hash-ref (hash-ref entry 'msg) 'fields)) 'label 1) #t)
                                (java-pb-type model (hash-set (findf (lambda (x) (= (hash-ref x 'number) 2)) (hash-ref (hash-ref entry 'msg) 'fields)) 'label 1) #t))
                        tail)]
        [(not (= (hash-ref f 'label) 3))
         (string-append head
                        (java-pb-decode-singular model f v
                                                 (cond [(memv type java-pb-varint-types) "field.varintValue"]
                                                       [(assv type java-pb-fixed) "field.fixedValue"]
                                                       [else "field.bytesValue"])
                                                 "                    ")
                        tail)]
        [(memv type java-pb-varint-types)
         (string-append head
                        "                    if (field.wire == 2) {\n"
                        (format "                        ~a.Reader sub = new ~a.Reader(field.bytesValue);\n" support support)
                        "                        while (!sub.done()) {\n"
                        (format "                            ~a.add(~a);\n" v
                                (let ([conv (java-pb-varint-decode f "sub.varint()")])
                                  (if (= type 14)
                                      (format "~a.fromNumber(~a)" (java-pb-entry-ref model (java-pb-resolve model (hash-ref f 'type-name))) (java-pb-varint-decode (hash-set f 'type 5) "sub.varint()"))
                                      conv)))
                        "                        }\n                    } else {\n"
                        (format "                        ~a.add(~a);\n" v
                                (let ([conv (java-pb-varint-decode f "field.varintValue")])
                                  (if (= type 14)
                                      (format "~a.fromNumber(~a)" (java-pb-entry-ref model (java-pb-resolve model (hash-ref f 'type-name))) (java-pb-varint-decode (hash-set f 'type 5) "field.varintValue"))
                                      conv)))
                        "                    }\n" tail)]
        [(assv type java-pb-fixed)
         => (lambda (info)
              (define size (second info))
              (string-append head
                             "                    if (field.wire == 2) {\n"
                             (format "                        ~a.Reader sub = new ~a.Reader(field.bytesValue);\n" support support)
                             (format "                        while (!sub.done()) ~a.add(~a);\n" v
                                     (case (hash-ref f 'type)
                                       [(2) "Float.intBitsToFloat(sub.fixed32())"]
                                       [(1) "Double.longBitsToDouble(sub.fixed64())"]
                                       [(15) "sub.fixed32()"]
                                       [else "sub.fixed64()"]))
                             "                    } else {\n"
                             (format "                        ~a.add(~a);\n" v
                                     (case (hash-ref f 'type)
                                       [(2) "Float.intBitsToFloat((int) field.fixedValue)"]
                                       [(1) "Double.longBitsToDouble(field.fixedValue)"]
                                       [(15) "(int) field.fixedValue"]
                                       [else "field.fixedValue"]))
                             "                    }\n" tail))]
        [(= type 9) (string-append head (format "                    ~a.add(new String(field.bytesValue, java.nio.charset.StandardCharsets.UTF_8));\n" v) tail)]
        [(= type 12) (string-append head (format "                    ~a.add(field.bytesValue);\n" v) tail)]
        [(= type 11)
         (string-append head
                        (format "                    ~a item = new ~a();\n" (java-pb-type model (hash-set f 'label 1) #t) (java-pb-type model (hash-set f 'label 1) #t))
                        "                    item.unmarshalDc(field.bytesValue);\n"
                        (format "                    ~a.add(item);\n" v) tail)]
        [else (error 'emit-java-pb-file "unsupported repeated field type ~a" type)]))

(define (java-pb-map-helper-name model entry)
  (define rel (java-pb-rel (hash-ref entry 'pkg) (hash-ref (hash-ref entry 'msg) 'full-name)))
  (string-join (string-split rel ".") ""))

(define (java-pb-map-helpers model entry support)
  (define msg (hash-ref entry 'msg))
  (define base (java-pb-map-helper-name model entry))
  (define key-f (findf (lambda (x) (= (hash-ref x 'number) 1)) (hash-ref msg 'fields)))
  (define val-f (findf (lambda (x) (= (hash-ref x 'number) 2)) (hash-ref msg 'fields)))
  (unless (and key-f val-f) (error 'emit-java-pb-file "map entry ~a lacks key/value" (hash-ref msg 'full-name)))
  (define kt (java-pb-type model (hash-set key-f 'label 1) #t))
  (define vt (java-pb-type model (hash-set val-f 'label 1) #t))
  (string-append
   (format "    static byte[] ~aEncode(~a key, ~a value) {\n" base kt vt)
   "        Writer w = new Writer();\n"
   (java-pb-encode-singular model (hash-set key-f 'label 1) "key" "        " support)
   (java-pb-encode-singular model (hash-set val-f 'label 1) "value" "        " support)
   "        return w.toBytes();\n    }\n\n"
   (format "    static Object[] ~aDecode(byte[] bytes) {\n" base)
   (format "        ~a key = ~a;\n" kt (java-pb-default model (hash-set key-f 'label 1)))
   (format "        ~a value = ~a;\n" vt (java-pb-default model (hash-set val-f 'label 1)))
   "        Reader r = new Reader(bytes);\n        Field field;\n        while ((field = r.next()) != null) {\n            switch (field.number) {\n"
   (format "                case ~a: ~a break;\n" (hash-ref key-f 'number)
           (java-pb-decode-singular-stmt model (hash-set key-f 'label 1) "key"))
   (format "                case ~a: ~a break;\n" (hash-ref val-f 'number)
           (java-pb-decode-singular-stmt model (hash-set val-f 'label 1) "value"))
   "                default: break;\n            }\n        }\n        return new Object[] { key, value };\n    }\n\n"))

;; One-line decode statement (no trailing newline handling needed
;; by switch cases in map helpers).
(define (java-pb-decode-singular-stmt model f target)
  (define type (hash-ref f 'type))
  (define src (cond [(memv type java-pb-varint-types) "field.varintValue"]
                    [(assv type java-pb-fixed) "field.fixedValue"]
                    [else "field.bytesValue"]))
  (string-trim (java-pb-decode-singular model f target src "") "\n" #:left? #f #:repeat? #t))

(define (java-pb-message-class model msg support nested?)
  (define name (hash-ref msg 'name))
  (define fields (hash-ref msg 'fields))
  (string-append
   (format "    public static final class ~a implements grpcdc.Marshaler, grpcdc.Unmarshaler {\n" name)
   (apply string-append
          (map (lambda (f)
                 (format "        public ~a ~a = ~a;\n"
                         (java-pb-type model f #f) (java-pb-field-name f) (java-pb-default model f)))
               fields))
   (format "        public ~a() {}\n" name)
   (if (null? fields)
       ""
       (string-append
        (format "        public ~a(~a) {\n" name
                (string-join (map (lambda (f) (format "~a ~a" (java-pb-type model f #f) (java-pb-field-name f))) fields) ", "))
        (apply string-append
               (map (lambda (f) (format "            this.~a = ~a;\n" (java-pb-field-name f) (java-pb-field-name f))) fields))
        "        }\n"))
   "\n        @Override\n        public byte[] marshalDc() {\n"
   (format "            ~a.Writer w = new ~a.Writer();\n" support support)
   (apply string-append (map (lambda (f) (java-pb-encode-field model f support)) fields))
   "            return w.toBytes();\n        }\n\n"
   "        @Override\n        public void unmarshalDc(byte[] data) {\n"
   (apply string-append
          (map (lambda (f) (format "            ~a = ~a;\n" (java-pb-field-name f) (java-pb-default model f))) fields))
   (format "            ~a.Reader r = new ~a.Reader(data);\n" support support)
   (format "            ~a.Field field;\n" support)
   "            while ((field = r.next()) != null) {\n                switch (field.number) {\n"
   (apply string-append (map (lambda (f) (java-pb-decode-case model f support)) fields))
   "                    default -> {}\n                }\n            }\n        }\n"
   (apply string-append (map (lambda (n) (java-pb-message-class model n support #t)) (hash-ref msg 'nested)))
   (apply string-append (map (lambda (e) (java-pb-nested-enum model msg e)) (hash-ref msg 'enums)))
   "    }\n"))

(define (java-pb-enum-values e)
  (string-append
   (string-join (map (lambda (v) (format "        ~a(~a)" (hash-ref v 'name) (hash-ref v 'number)))
                     (hash-ref e 'values)) ",\n")
   ";\n"))

(define (java-pb-enum-body e indent)
  (string-append
   (format "~apublic final int number;\n" indent)
   (format "~a~a(int number) { this.number = number; }\n" indent (hash-ref e 'name))
   (format "~apublic static ~a fromNumber(int number) {\n" indent (hash-ref e 'name))
   (format "~a    switch (number) {\n" indent)
   (apply string-append
          (map (lambda (v) (format "~a        case ~a: return ~a;\n" indent (hash-ref v 'number) (hash-ref v 'name)))
               (hash-ref e 'values)))
   (format "~a        default: return ~a;\n    }\n}\n" indent (hash-ref (car (hash-ref e 'values)) 'name))))

(define (java-pb-nested-enum model msg e)
  (string-append
   (format "        public enum ~a {\n" (hash-ref e 'name))
   (java-pb-enum-values e)
   (java-pb-enum-body e "            ")
   "        }\n"))

(define (java-pb-top-enum model e pkg)
  (string-append
   "// @generated by protoc-gen-grpc-dc-java (Racket metaprogram). DO NOT EDIT.\n"
   (if (string=? pkg "") "" (format "package ~a;\n\n" pkg))
   (format "public enum ~a {\n" (hash-ref e 'name))
   (java-pb-enum-values e)
   (java-pb-enum-body e "    ")
   "}\n"))

(define (java-pb-top-message model msg pkg support)
  (define name (hash-ref msg 'name))
  (define fields (hash-ref msg 'fields))
  (string-append
   "// @generated by protoc-gen-grpc-dc-java (Racket metaprogram). DO NOT EDIT.\n"
   (if (string=? pkg "") "" (format "package ~a;\n\n" pkg))
   (format "public final class ~a implements grpcdc.Marshaler, grpcdc.Unmarshaler {\n" name)
   (apply string-append
          (map (lambda (f)
                 (format "    public ~a ~a = ~a;\n"
                         (java-pb-type model f #f) (java-pb-field-name f) (java-pb-default model f)))
               fields))
   (format "    public ~a() {}\n" name)
   (if (null? fields)
       ""
       (string-append
        (format "    public ~a(~a) {\n" name
                (string-join (map (lambda (f) (format "~a ~a" (java-pb-type model f #f) (java-pb-field-name f))) fields) ", "))
        (apply string-append
               (map (lambda (f) (format "        this.~a = ~a;\n" (java-pb-field-name f) (java-pb-field-name f))) fields))
        "    }\n"))
   "\n    @Override\n    public byte[] marshalDc() {\n"
   (format "        ~a.Writer w = new ~a.Writer();\n" support support)
   (apply string-append (map (lambda (f) (java-pb-encode-field model f support)) fields))
   "        return w.toBytes();\n    }\n\n"
   "    @Override\n    public void unmarshalDc(byte[] data) {\n"
   (apply string-append
          (map (lambda (f) (format "        ~a = ~a;\n" (java-pb-field-name f) (java-pb-default model f))) fields))
   (format "        ~a.Reader r = new ~a.Reader(data);\n" support support)
   (format "        ~a.Field field;\n" support)
   "        while ((field = r.next()) != null) {\n            switch (field.number) {\n"
   (apply string-append (map (lambda (f) (java-pb-decode-case model f support)) fields))
   "                default -> {}\n            }\n        }\n    }\n"
   (apply string-append (map (lambda (n) (java-pb-message-class model n support #t)) (hash-ref msg 'nested)))
   (apply string-append (map (lambda (e) (java-pb-nested-enum model msg e)) (hash-ref msg 'enums)))
   "}\n"))

(define (emit-java-pb-files file-model)
  (and (hash-has-key? file-model 'messages)
       (hash-has-key? file-model 'types)
       (emit-java-pb-files/inner file-model)))

(define (emit-java-pb-files/inner file-model)
  (define messages (hash-ref file-model 'messages))
  (define enums (hash-ref file-model 'enums))
  (and (or (pair? messages) (pair? enums))
       (let ()
         (define base (path->string (path-replace-extension
                                     (file-name-from-path (hash-ref file-model 'name)) "")))
         (define pkg (hash-ref file-model 'package))
         (define support (format "~aPb" (pascal (string->symbol base))))
         ;; Collect this file's map helpers into the support class.
         (define seen-maps (mutable-set))
         (define helpers '())
         (define (collect msg)
           (for ([f (in-list (hash-ref msg 'fields))])
             (when (= (hash-ref f 'type) 11)
               (define e (java-pb-resolve file-model (hash-ref f 'type-name)))
               (when (and (eq? (hash-ref e 'kind) 'map)
                          (equal? (hash-ref e 'file) (hash-ref file-model 'name))
                          (not (set-member? seen-maps (hash-ref (hash-ref e 'msg) 'full-name))))
                 (set-add! seen-maps (hash-ref (hash-ref e 'msg) 'full-name))
                 (set! helpers (cons (java-pb-map-helpers file-model e support) helpers)))))
           (for ([n (in-list (hash-ref msg 'nested))]) (collect n)))
         (for ([m (in-list messages)]) (collect m))
         (define support-content
           (if (null? helpers)
               (java-pb-support-class base pkg)
               (string-replace (java-pb-support-class base pkg)
                               "    static final class Writer {"
                               (string-append (apply string-append (reverse helpers))
                                              "    static final class Writer {"))))
         (append
          (list (cons (string-append support ".java") support-content))
          (map (lambda (m) (cons (string-append (hash-ref m 'name) ".java")
                                 (java-pb-top-message file-model m pkg support)))
               (filter (lambda (m) (not (hash-ref m 'map-entry))) messages))
          (map (lambda (e) (cons (string-append (hash-ref e 'name) ".java")
                                 (java-pb-top-enum file-model e pkg)))
               enums)))))

(define (java-pb-support-class base pkg)
  (string-append
   "// @generated by protoc-gen-grpc-dc-java (Racket metaprogram). DO NOT EDIT.\n"
   (if (string=? pkg "") "" (format "package ~a;\n\n" pkg))
   (format "final class ~aPb {\n" (pascal (string->symbol base)))
   "    private " (format "~aPb" (pascal (string->symbol base))) "() {}\n\n"
   "    static final class Writer {\n"
   "        private final java.io.ByteArrayOutputStream out = new java.io.ByteArrayOutputStream();\n"
   "        void varint(long value) { long v = value; while ((v & ~0x7fL) != 0) { out.write(((int) (v & 0x7f)) | 0x80); v >>>= 7; } out.write((int) v); }\n"
   "        void tag(int field, int wire) { varint((field << 3) | wire); }\n"
   "        void bytesField(int field, byte[] payload) { tag(field, 2); varint(payload.length); out.write(payload, 0, payload.length); }\n"
   "        void stringField(int field, String value) { if (value == null || value.isEmpty()) return; bytesField(field, value.getBytes(java.nio.charset.StandardCharsets.UTF_8)); }\n"
   "        void fixed32(int value) { out.write(value & 0xff); out.write((value >>> 8) & 0xff); out.write((value >>> 16) & 0xff); out.write((value >>> 24) & 0xff); }\n"
   "        void fixed64(long value) { for (int i = 0; i < 8; i++) out.write((int) ((value >>> (8 * i)) & 0xff)); }\n"
   "        void fixedInt(int value) { fixed32(value); }\n"
   "        void fixedLong(long value) { fixed64(value); }\n"
   "        void fixedFloat(float value) { fixed32(Float.floatToIntBits(value)); }\n"
   "        void fixedDouble(double value) { fixed64(Double.doubleToLongBits(value)); }\n"
   "        byte[] toBytes() { return out.toByteArray(); }\n"
   "    }\n\n"
   "    static final class Field {\n"
   "        final int number; final int wire; final long varintValue; final byte[] bytesValue; final long fixedValue;\n"
   "        Field(int number, int wire, long varintValue, byte[] bytesValue, long fixedValue) { this.number = number; this.wire = wire; this.varintValue = varintValue; this.bytesValue = bytesValue; this.fixedValue = fixedValue; }\n"
   "    }\n\n"
   "    static final class Reader {\n"
   "        private final byte[] buf; private int pos;\n"
   "        Reader(byte[] buf) { this.buf = buf; }\n"
   "        boolean done() { return pos >= buf.length; }\n"
   "        long varint() { long result = 0; int shift = 0; while (true) { if (pos >= buf.length) throw new IllegalArgumentException(\"truncated varint\"); int b = buf[pos++] & 0xff; result |= (long) (b & 0x7f) << shift; if ((b & 0x80) == 0) return result; shift += 7; if (shift >= 64) throw new IllegalArgumentException(\"varint too long\"); } }\n"
   "        byte[] take(int n) { if (pos + n > buf.length) throw new IllegalArgumentException(\"truncated field\"); byte[] v = new byte[n]; System.arraycopy(buf, pos, v, 0, n); pos += n; return v; }\n"
   "        int fixed32() { byte[] b = take(4); return (b[0] & 0xff) | ((b[1] & 0xff) << 8) | ((b[2] & 0xff) << 16) | ((b[3] & 0xff) << 24); }\n"
   "        long fixed64() { byte[] b = take(8); long v = 0; for (int i = 0; i < 8; i++) v |= (long) (b[i] & 0xff) << (8 * i); return v; }\n"
   "        Field next() {\n"
   "            if (pos >= buf.length) return null;\n"
   "            long tag = varint(); int number = (int) (tag >> 3); int wire = (int) (tag & 7);\n"
   "            switch (wire) {\n"
   "                case 0: return new Field(number, wire, varint(), null, 0);\n"
   "                case 2: { int n = (int) varint(); return new Field(number, wire, 0, take(n), 0); }\n"
   "                case 1: { byte[] b = take(8); long v = 0; for (int i = 0; i < 8; i++) v |= (long) (b[i] & 0xff) << (8 * i); return new Field(number, wire, 0, b, v); }\n"
   "                case 5: { byte[] b = take(4); int v = (b[0] & 0xff) | ((b[1] & 0xff) << 8) | ((b[2] & 0xff) << 16) | ((b[3] & 0xff) << 24); return new Field(number, wire, 0, b, v); }\n"
   "                default: throw new IllegalArgumentException(\"bad wire type \" + wire);\n"
   "            }\n"
   "        }\n"
   "    }\n"
   "}\n"))

(define (emit-java-file file-model params)
  (define base (path->string (path-replace-extension
                              (file-name-from-path (hash-ref file-model 'name)) "")))
  (define class-name (string-append (pascal (string->symbol base)) "GrpcDc"))
  (define pkg (hash-ref file-model 'package))
  (define stub
    (cons (string-append class-name ".java")
          (string-append
           "// @generated by protoc-gen-grpc-dc-java (Racket metaprogram). DO NOT EDIT.\n"
         (format "// source: ~a\n\n" (hash-ref file-model 'name))
         (if (string=? pkg "") "" (format "package ~a;\n\n" pkg))
         "import grpcdc.Channel;\n"
         "import grpcdc.Endpoint;\n"
         "import grpcdc.Server;\n"
         "import grpcdc.StatusException;\n"
         "import grpcdc.Wire;\n"
         "import java.util.ArrayList;\n"
         "import java.util.List;\n"
         "import java.util.Map;\n"
         "import java.util.concurrent.CompletableFuture;\n"
         "import java.util.concurrent.CompletionException;\n\n"
         (format "/** Generated gRPC-over-DataChannels stubs for ~a. */\n" (hash-ref file-model 'name))
         (format "public final class ~a {\n    private ~a() {}\n\n" class-name class-name)
         (apply string-append
                (map java-service (hash-ref file-model 'services)))
         "}\n")))
  (define pb-files (emit-java-pb-files file-model))
  (if pb-files (cons stub pb-files) stub))
