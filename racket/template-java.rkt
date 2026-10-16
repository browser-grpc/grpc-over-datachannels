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

(define (emit-java-file file-model params)
  (define base (path->string (path-replace-extension
                              (file-name-from-path (hash-ref file-model 'name)) "")))
  (define class-name (string-append (pascal (string->symbol base)) "GrpcDc"))
  (define pkg (hash-ref file-model 'package))
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
