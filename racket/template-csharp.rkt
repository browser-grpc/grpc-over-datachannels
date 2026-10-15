#lang racket

;;; template-csharp.rkt — emitter body spliced into
;;; protoc-gen-grpc-dc-csharp.
;;;
;;; Generated code is one static class <Base>GrpcDc in the proto
;;; package's PascalCase namespace, beside hand-written message types
;;; implementing Grpcdc.IMarshaler / Grpcdc.IUnmarshaler. Method names
;;; keep the proto spelling, mirroring the Go/Java stubs.

(require "spec.rkt" "desc.rkt")
(provide emit-csharp-file)

(define current-service (make-parameter ""))

(define (pascal sym) ; echo_service -> EchoService ; echo -> Echo
  (apply string-append
         (for/list ([part (in-list (string-split (symbol->string sym) "[_.-]"))])
           (if (string=? part "")
               ""
               (string-append (string (char-upcase (string-ref part 0)))
                              (substring part 1))))))

(define (csharp-deprecated m indent)
  (if (hash-ref m 'deprecated #f)
      (format "~a[Obsolete(\"deprecated in the proto schema\")]\n" indent)
      ""))

(define (csharp-client-method/raw m)
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define path (hash-ref m 'path))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(unary)
     (format (string-append
              "        public ~a ~a(~a req, IDictionary<string, string> metadata = null)\n"
              "        {\n"
              "            var resp = new ~a();\n"
              "            _channel.Unary(~s, req, resp, metadata);\n"
              "            return resp;\n"
              "        }\n\n")
             resp name req resp path)]
    [(server-streaming)
     (format (string-append
              "        public ~a~aStream ~a(~a req, IDictionary<string, string> metadata = null)\n"
              "        {\n"
              "            return new ~a~aStream(_channel.ServerStream(~s, req, metadata));\n"
              "        }\n\n")
             svc name name req svc name path)]
    [(client-streaming)
     (format (string-append
              "        public ~a ~a(IEnumerable<~a> reqs, IDictionary<string, string> metadata = null)\n"
              "        {\n"
              "            var resp = new ~a();\n"
              "            _channel.ClientStreamCall(~s, reqs, resp, metadata);\n"
              "            return resp;\n"
              "        }\n\n")
             resp name req resp path)]
    [(bidi)
     (format (string-append
              "        public ~a~aStream ~a(IEnumerable<~a> reqs, IDictionary<string, string> metadata = null)\n"
              "        {\n"
              "            return new ~a~aStream(_channel.Bidi(~s, reqs, metadata));\n"
              "        }\n\n")
             svc name name req svc name path)]))

(define (csharp-client-method m)
  (string-append (csharp-deprecated m "        ") (csharp-client-method/raw m)))

(define (csharp-client-stream-class m)
  (define name (hash-ref m 'name))
  (define resp (hash-ref m 'output))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(server-streaming bidi)
     (format (string-append
              "    /// <summary>Receiving stream for ~a.~a: Recv() throws EndOfStreamException at end.</summary>\n"
              "    public sealed class ~a~aStream\n"
              "    {\n"
              "        private readonly Channel.ClientStream _stream;\n\n"
              "        internal ~a~aStream(Channel.ClientStream stream)\n"
              "        {\n"
              "            _stream = stream;\n"
              "        }\n\n"
              "        public ~a Recv()\n"
              "        {\n"
              "            var resp = new ~a();\n"
              "            _stream.Recv(resp);\n"
              "            return resp;\n"
              "        }\n"
              "    }\n\n")
             svc name svc name svc name resp resp)]
    [else ""]))

(define (csharp-server-iface-method/raw m)
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(unary)
     (format "        ~a ~a(Endpoint.CallContext ctx, ~a req);\n" resp name req)]
    [(server-streaming)
     (format "        void ~a(~a req, ~a~aServer stream);\n" name req svc name)]
    [(client-streaming)
     (format "        void ~a(~a~aServer stream);\n" name svc name)]
    [(bidi)
     (format "        void ~a(~a~aServer stream);\n" name svc name)]))

(define (csharp-server-iface-method m)
  (string-append (csharp-deprecated m "        ") (csharp-server-iface-method/raw m)))

(define (csharp-server-stream-ifaces m)
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(unary) ""]
    [(server-streaming)
     (format (string-append
              "    /// <summary>Server-streaming sink passed to service implementations.</summary>\n"
              "    public interface ~a~aServer\n"
              "    {\n"
              "        void Send(~a resp);\n"
              "        Endpoint.CallContext Context { get; }\n"
              "    }\n\n")
             svc name resp)]
    [(client-streaming)
     (format (string-append
              "    /// <summary>Client-streaming stream passed to service implementations.</summary>\n"
              "    public interface ~a~aServer\n"
              "    {\n"
              "        ~a Recv();\n"
              "        void SendAndClose(~a resp);\n"
              "        Endpoint.CallContext Context { get; }\n"
              "    }\n\n")
             svc name req resp)]
    [(bidi)
     (format (string-append
              "    /// <summary>Bidi stream passed to service implementations.</summary>\n"
              "    public interface ~a~aServer\n"
              "    {\n"
              "        void Send(~a resp);\n"
              "        ~a Recv();\n"
              "        Endpoint.CallContext Context { get; }\n"
              "    }\n\n")
             svc name resp req)]))

(define (csharp-register-method m)
  (define name (hash-ref m 'name))
  (define impl-name (method-impl-name m))
  (define req (hash-ref m 'input))
  (define svc (current-service))
  (define kind-const
    (case (hash-ref m 'kind)
      [(unary) "KindUnary"]
      [(server-streaming) "KindServerStreaming"]
      [(client-streaming) "KindClientStreaming"]
      [(bidi) "KindBidi"]))
  (case (hash-ref m 'kind)
    [(unary)
     (format (string-append
              "                new Server.Method(~s, ~s, Server.~a, (ctx, reqs, sink) =>\n"
              "                {\n"
              "                    var req = new ~a();\n"
              "                    reqs.RecvInto(req);\n"
              "                    sink(impl.~a(ctx, req).MarshalDc());\n"
              "                }),\n")
             name (hash-ref m 'path) kind-const req impl-name)]
    [(server-streaming)
     (format (string-append
              "                new Server.Method(~s, ~s, Server.~a, (ctx, reqs, sink) =>\n"
              "                {\n"
              "                    var req = new ~a();\n"
              "                    reqs.RecvInto(req);\n"
              "                    impl.~a(req, new ~a~aServerImpl(ctx, sink));\n"
              "                }),\n")
             name (hash-ref m 'path) kind-const req impl-name svc impl-name)]
    [(client-streaming)
     (format (string-append
              "                new Server.Method(~s, ~s, Server.~a, (ctx, reqs, sink) =>\n"
              "                {\n"
              "                    var stream = new ~a~aServerImpl(ctx, reqs);\n"
              "                    impl.~a(stream);\n"
              "                    if (stream.Resp == null)\n"
              "                    {\n"
              "                        throw new StatusException(Wire.CodeInternal,\n"
              "                            \"client-streaming handler never called SendAndClose\");\n"
              "                    }\n"
              "                    sink(stream.Resp.MarshalDc());\n"
              "                }),\n")
             name (hash-ref m 'path) kind-const svc impl-name impl-name)]
    [(bidi)
     (format (string-append
              "                new Server.Method(~s, ~s, Server.~a, (ctx, reqs, sink) =>\n"
              "                {\n"
              "                    impl.~a(new ~a~aServerImpl(ctx, reqs, sink));\n"
              "                }),\n")
             name (hash-ref m 'path) kind-const impl-name svc impl-name)]))

(define (csharp-stream-impls m)
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(unary) ""]
    [(server-streaming)
     (format (string-append
              "    private sealed class ~a~aServerImpl : ~a~aServer\n"
              "    {\n"
              "        private readonly Server.ServerSink _sink;\n\n"
              "        internal ~a~aServerImpl(Endpoint.CallContext ctx, Server.ServerSink sink)\n"
              "        {\n"
              "            Context = ctx;\n"
              "            _sink = sink;\n"
              "        }\n\n"
              "        public Endpoint.CallContext Context { get; }\n\n"
              "        public void Send(~a resp) => _sink(resp.MarshalDc());\n"
              "    }\n\n")
             svc name svc name svc name resp)]
    [(client-streaming)
     (format (string-append
              "    private sealed class ~a~aServerImpl : ~a~aServer\n"
              "    {\n"
              "        private readonly Server.RequestStream _reqs;\n\n"
              "        internal ~a~aServerImpl(Endpoint.CallContext ctx, Server.RequestStream reqs)\n"
              "        {\n"
              "            Context = ctx;\n"
              "            _reqs = reqs;\n"
              "        }\n\n"
              "        public Endpoint.CallContext Context { get; }\n"
              "        public ~a Resp { get; private set; }\n\n"
              "        public ~a Recv()\n"
              "        {\n"
              "            var req = new ~a();\n"
              "            _reqs.RecvInto(req);\n"
              "            return req;\n"
              "        }\n\n"
              "        public void SendAndClose(~a resp) => Resp = resp;\n"
              "    }\n\n")
             svc name svc name svc name resp req req resp)]
    [(bidi)
     (format (string-append
              "    private sealed class ~a~aServerImpl : ~a~aServer\n"
              "    {\n"
              "        private readonly Server.RequestStream _reqs;\n"
              "        private readonly Server.ServerSink _sink;\n\n"
              "        internal ~a~aServerImpl(Endpoint.CallContext ctx, Server.RequestStream reqs, Server.ServerSink sink)\n"
              "        {\n"
              "            Context = ctx;\n"
              "            _reqs = reqs;\n"
              "            _sink = sink;\n"
              "        }\n\n"
              "        public Endpoint.CallContext Context { get; }\n\n"
              "        public void Send(~a resp) => _sink(resp.MarshalDc());\n\n"
              "        public ~a Recv()\n"
              "        {\n"
              "            var req = new ~a();\n"
              "            _reqs.RecvInto(req);\n"
              "            return req;\n"
              "        }\n"
              "    }\n\n")
             svc name svc name svc name resp req req)]))


(define (csharp-client-async-method m)
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(unary)
     (format (string-append
              "        public Task<~a> ~aAsync(~a req, IDictionary<string, string> metadata = null,\n"
              "            CancellationToken cancellationToken = default)\n"
              "        {\n"
              "            return AsyncPump.Run(() => Unary(req, metadata), cancellationToken);\n"
              "        }\n\n")
             resp name req)]
    [(server-streaming)
     (format (string-append
              "        public async IAsyncEnumerable<~a> ~aAsync(~a req, IDictionary<string, string> metadata = null,\n"
              "            [EnumeratorCancellation] CancellationToken cancellationToken = default)\n"
              "        {\n"
              "            var stream = ~a(req, metadata);\n"
              "            await foreach (var item in AsyncPump.Stream(stream.Recv, cancellationToken))\n"
              "            {\n"
              "                yield return item;\n"
              "            }\n"
              "        }\n\n")
             resp name req name)]
    [(client-streaming)
     (format (string-append
              "        public Task<~a> ~aAsync(IEnumerable<~a> reqs, IDictionary<string, string> metadata = null,\n"
              "            CancellationToken cancellationToken = default)\n"
              "        {\n"
              "            return AsyncPump.Run(() => ClientStream(reqs, metadata), cancellationToken);\n"
              "        }\n\n")
             resp name req)]
    [(bidi)
     (format (string-append
              "        public async IAsyncEnumerable<~a> ~aAsync(IEnumerable<~a> reqs, IDictionary<string, string> metadata = null,\n"
              "            [EnumeratorCancellation] CancellationToken cancellationToken = default)\n"
              "        {\n"
              "            var stream = ~a(reqs, metadata);\n"
              "            await foreach (var item in AsyncPump.Stream(stream.Recv, cancellationToken))\n"
              "            {\n"
              "                yield return item;\n"
              "            }\n"
              "        }\n\n")
             resp name req name)]))

(define (csharp-server-async-iface-method m)
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(unary)
     (format "        Task<~a> ~aAsync(Endpoint.CallContext ctx, ~a req);\n" resp name req)]
    [(server-streaming)
     (format "        Task ~aAsync(~a req, ~a~aServer stream);\n" name req svc name)]
    [(client-streaming)
     (format "        Task ~aAsync(~a~aServer stream);\n" name svc name)]
    [(bidi)
     (format "        Task ~aAsync(~a~aServer stream);\n" name svc name)]))

(define (csharp-server-async-adapter-method m)
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(unary)
     (format (string-append
              "        public ~a ~a(Endpoint.CallContext ctx, ~a req)\n"
              "        {\n"
              "            return _impl.~aAsync(ctx, req).GetAwaiter().GetResult();\n"
              "        }\n\n")
             resp name req name)]
    [(server-streaming)
     (format (string-append
              "        public void ~a(~a req, ~a~aServer stream)\n"
              "        {\n"
              "            _impl.~aAsync(req, stream).GetAwaiter().GetResult();\n"
              "        }\n\n")
             name req svc name name)]
    [(client-streaming)
     (format (string-append
              "        public void ~a(~a~aServer stream)\n"
              "        {\n"
              "            _impl.~aAsync(stream).GetAwaiter().GetResult();\n"
              "        }\n\n")
             name svc name name)]
    [(bidi)
     (format (string-append
              "        public void ~a(~a~aServer stream)\n"
              "        {\n"
              "            _impl.~aAsync(stream).GetAwaiter().GetResult();\n"
              "        }\n\n")
             name svc name name)]))

(define (csharp-service svc)
  (define sname (hash-ref svc 'name))
  (define methods (hash-ref svc 'methods))
  (parameterize ([current-service sname])
    (string-append
     (format "    /// <summary>Client for ~a.</summary>\n" (hash-ref svc 'full-name))
     (format "    public sealed class ~aClient\n    {\n" sname)
     "        private readonly Channel _channel;\n\n"
     (format "        public ~aClient(Channel channel)\n        {\n            _channel = channel;\n        }\n\n" sname)
     (apply string-append (map csharp-client-method (append methods (alias-client-methods svc))))
     (apply string-append (map csharp-client-async-method (append methods (alias-client-methods svc))))
     "    }\n\n"
     (apply string-append (map csharp-client-stream-class methods))
     (format "    /// <summary>Service implementation interface for ~a.</summary>\n" (hash-ref svc 'full-name))
     (format "    public interface ~aServer\n    {\n" sname)
     (apply string-append (map csharp-server-iface-method methods))
     "    }\n\n"
     (apply string-append (map csharp-server-stream-ifaces methods))
     (apply string-append (map csharp-stream-impls methods))
     (format "    /// <summary>Async service implementation interface for ~a.</summary>\n" (hash-ref svc 'full-name))
     (format "    public interface ~aServerAsync\n    {\n" sname)
     (apply string-append (map csharp-server-async-iface-method methods))
     "    }\n\n"
     (format "    private sealed class ~aServerAsyncAdapter : ~aServer\n    {\n" sname sname)
     (format "        private readonly ~aServerAsync _impl;\n\n" sname)
     (format "        internal ~aServerAsyncAdapter(~aServerAsync impl)\n        {\n            _impl = impl;\n        }\n\n" sname sname)
     (apply string-append (map csharp-server-async-adapter-method methods))
     "    }\n\n"
     (format "    /// <summary>Register an implementation of ~a on a Server.</summary>\n" (hash-ref svc 'full-name))
     (format "    public static void Register~aServer(Server server, ~aServer impl)\n    {\n" sname sname)
     (format "        server.RegisterService(new Server.ServiceDesc(\n            ~s,\n            new List<Server.Method>\n            {\n"
             (hash-ref svc 'full-name))
     (apply string-append (map csharp-register-method (append methods (alias-server-methods svc))))
     "            }));\n    }\n"
     (format "    /// <summary>Register an async implementation of ~a on a Server.</summary>\n" (hash-ref svc 'full-name))
     (format "    public static void Register~aServerAsync(Server server, ~aServerAsync impl)\n    {\n" sname sname)
     (format "        Register~aServer(server, new ~aServerAsyncAdapter(impl));\n    }\n" sname sname))))

(define (emit-csharp-file file-model params)
  (define base (path->string (path-replace-extension
                              (file-name-from-path (hash-ref file-model 'name)) "")))
  (define class-name (string-append (pascal (string->symbol base)) "GrpcDc"))
  (define pkg (hash-ref file-model 'package))
  (define ns (if (string=? pkg "") "Proto" (pascal (string->symbol pkg))))
  (cons (string-append class-name ".cs")
        (string-append
         "// @generated by protoc-gen-grpc-dc-csharp (Racket metaprogram). DO NOT EDIT.\n"
         (format "// source: ~a\n\n" (hash-ref file-model 'name))
         "using System.Collections.Generic;\n"
         "using System.Runtime.CompilerServices;\n"
         "using System.Threading;\n"
         "using System.Threading.Tasks;\n"
         "using Grpcdc;\n\n"
         (format "namespace ~a;\n\n" ns)
         (format "/// <summary>Generated gRPC-over-DataChannels stubs for ~a.</summary>\n" (hash-ref file-model 'name))
         (format "public static class ~a\n{\n" class-name)
         (apply string-append
                (map csharp-service (hash-ref file-model 'services)))
         "}\n")))
