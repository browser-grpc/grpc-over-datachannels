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
              "        public ~a ~a(~a req, IDictionary<string, string> metadata = null, TimeSpan? timeout = null)\n"
              "        {\n"
              "            var resp = new ~a();\n"
              "            _channel.Unary(~s, req, resp, metadata, timeout);\n"
              "            return resp;\n"
              "        }\n\n")
             resp name req resp path)]
    [(server-streaming)
     (format (string-append
              "        public ~a~aStream ~a(~a req, IDictionary<string, string> metadata = null, TimeSpan? timeout = null)\n"
              "        {\n"
              "            return new ~a~aStream(_channel.ServerStream(~s, req, metadata, timeout));\n"
              "        }\n\n")
             svc name name req svc name path)]
    [(client-streaming)
     (format (string-append
              "        public ~a ~a(IEnumerable<~a> reqs, IDictionary<string, string> metadata = null, TimeSpan? timeout = null)\n"
              "        {\n"
              "            var resp = new ~a();\n"
              "            _channel.ClientStreamCall(~s, reqs, resp, metadata, timeout);\n"
              "            return resp;\n"
              "        }\n\n")
             resp name req resp path)]
    [(bidi)
     (format (string-append
              "        public ~a~aStream ~a(IEnumerable<~a> reqs, IDictionary<string, string> metadata = null, TimeSpan? timeout = null)\n"
              "        {\n"
              "            return new ~a~aStream(_channel.Bidi(~s, reqs, metadata, timeout));\n"
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
              "    /// <summary>Receiving stream for ~a.~a: Recv() throws EndOfStreamException at end. Dispose to abandon early (RST).</summary>\n"
              "    public sealed class ~a~aStream : IDisposable\n"
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
              "        }\n\n"
              "        /// <summary>Initial metadata (response headers); null until they arrive.</summary>\n"
              "        public Dictionary<string, string> Headers => _stream.Headers?.Metadata;\n\n"
              "        /// <summary>Trailing metadata of the terminal status; null until it arrives.</summary>\n"
              "        public Dictionary<string, string> Trailers => _stream.Trailers;\n\n"
              "        /// <summary>Abort this stream (sends RST, wakes a pending Recv).</summary>\n"
              "        public void Cancel() => _stream.Cancel();\n\n"
              "        /// <summary>Abandon the call if still live (RST); no-op once terminated.</summary>\n"
              "        public void Dispose() => _stream.Dispose();\n"
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
              "        public Task<~a> ~aAsync(~a req, IDictionary<string, string> metadata = null, TimeSpan? timeout = null,\n"
              "            CancellationToken cancellationToken = default)\n"
              "        {\n"
              "            return AsyncPump.Run(() => ~a(req, metadata, timeout), cancellationToken);\n"
              "        }\n\n")
             resp name req name)]
    [(server-streaming)
     (format (string-append
              "        public async IAsyncEnumerable<~a> ~aAsync(~a req, IDictionary<string, string> metadata = null, TimeSpan? timeout = null,\n"
              "            [EnumeratorCancellation] CancellationToken cancellationToken = default)\n"
              "        {\n"
              "            var stream = ~a(req, metadata, timeout);\n"
              "            await foreach (var item in AsyncPump.Stream(stream.Recv, stream.Cancel, cancellationToken))\n"
              "            {\n"
              "                yield return item;\n"
              "            }\n"
              "        }\n\n")
             resp name req name)]
    [(client-streaming)
     (format (string-append
              "        public Task<~a> ~aAsync(IEnumerable<~a> reqs, IDictionary<string, string> metadata = null, TimeSpan? timeout = null,\n"
              "            CancellationToken cancellationToken = default)\n"
              "        {\n"
              "            return AsyncPump.Run(() => ~a(reqs, metadata, timeout), cancellationToken);\n"
              "        }\n\n")
             resp name req name)]
    [(bidi)
     (format (string-append
              "        public async IAsyncEnumerable<~a> ~aAsync(IEnumerable<~a> reqs, IDictionary<string, string> metadata = null, TimeSpan? timeout = null,\n"
              "            [EnumeratorCancellation] CancellationToken cancellationToken = default)\n"
              "        {\n"
              "            var stream = ~a(reqs, metadata, timeout);\n"
              "            await foreach (var item in AsyncPump.Stream(stream.Recv, stream.Cancel, cancellationToken))\n"
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

;; ---------------------------------------------------------------------------
;; C# message types: one public class per top-level message and
;; one enum per top-level enum, plus an internal <Base>Pb wire
;; support class per proto file. Dependency-free (BCL only),
;; implementing Grpcdc.IMarshaler/IUnmarshaler. Mirrors the Java
;; emitter on the shared desc.rkt model.
;; ---------------------------------------------------------------------------

(define (cs-pb-pascal s)
  (string-join
   (map (lambda (part)
          (if (string=? part "") "" (string-append (string (char-upcase (string-ref part 0))) (substring part 1))))
        (string-split s "_")) ""))

;; Generated field name: PascalCase, with a trailing underscore
;; when it would collide with a nested message/enum type of the
;; same message (C# forbids a field and a nested type sharing a
;; name, e.g. field `middle` next to nested class `Middle`).
(define (cs-pb-field-name model f)
  (define n (cs-pb-pascal (hash-ref f 'name)))
  (define owner (field-owner model f))
  (if (and owner
           (or (equal? n (hash-ref owner 'name))
               (member n (map (lambda (m) (hash-ref m 'name)) (hash-ref owner 'nested)))
               (member n (map (lambda (e) (hash-ref e 'name)) (hash-ref owner 'enums)))))
      (string-append n "_")
      n))

;; Stub type reference for a method input/output: the simple class
;; name when the message lives in the stub file's own package,
;; namespace-qualified otherwise (C# cannot resolve a simple name
;; across namespaces). Generated message classes keep the proto
;; nesting under their file's namespace.
(define (cs-qualify-type pkg simple full)
  (cond [(or (not full) (string=? pkg "")
             (string-prefix? full (string-append pkg ".")))
         simple]
        [else (string-append (string (char-upcase (string-ref full 0)))
                             (substring full 1))]))

(define (cs-qualify-services pkg services)
  (for/list ([svc (in-list services)])
    (hash-set svc 'methods
              (for/list ([m (in-list (hash-ref svc 'methods))])
                (hash-set* m
                           'input (cs-qualify-type pkg (hash-ref m 'input)
                                                   (hash-ref m 'input-full #f))
                           'output (cs-qualify-type pkg (hash-ref m 'output)
                                                    (hash-ref m 'output-full #f)))))))

(define cs-pb-varint-types varint-scalar-types)
(define cs-pb-fixed (fixed-scalar-table 'csharp))

(define (cs-pb-resolve model type-name)
  (hash-ref (hash-ref model 'types) type-name
            (lambda () (error 'emit-csharp-pb-file "unresolved type ~a" type-name))))

(define (cs-pb-ns pkg)
  (if (string=? pkg "") "Proto" (pascal (string->symbol pkg))))

(define (cs-pb-rel pkg full)
  (define rel (if (and pkg (not (string=? pkg "")) (string-prefix? full (string-append pkg ".")))
                  (substring full (add1 (string-length pkg)))
                  full))
  (string-join (string-split rel ".") "."))

(define (cs-pb-entry-ref model entry)
  (define rel
    (if (eq? (hash-ref entry 'kind) 'enum)
        (let ([e (hash-ref entry 'enum)])
          (if (hash-ref entry 'msg)
              (string-append (cs-pb-rel (hash-ref entry 'pkg) (hash-ref (hash-ref entry 'msg) 'full-name)) "." (hash-ref e 'name))
              (cs-pb-rel (hash-ref entry 'pkg) (format "~a.~a" (hash-ref entry 'pkg) (hash-ref e 'name)))))
        (cs-pb-rel (hash-ref entry 'pkg) (hash-ref (hash-ref entry 'msg) 'full-name))))
  (if (equal? (hash-ref entry 'file) (hash-ref model 'name))
      rel
      (string-append (cs-pb-ns (hash-ref entry 'pkg)) "." rel)))

(define (cs-pb-scalar f) (scalar-type-entry 'csharp (hash-ref f 'type)))

(define (cs-pb-type model f)
  (define type (hash-ref f 'type))
  (define singular
    (cond [(= type 11)
           (define entry (cs-pb-resolve model (hash-ref f 'type-name)))
           (if (eq? (hash-ref entry 'kind) 'map)
               (let* ([em (hash-ref entry 'msg)]
                      [kf (findf (lambda (x) (= (hash-ref x 'number) 1)) (hash-ref em 'fields))]
                      [vf (findf (lambda (x) (= (hash-ref x 'number) 2)) (hash-ref em 'fields))])
                 (format "System.Collections.Generic.Dictionary<~a, ~a>"
                         (cs-pb-type model (hash-set kf 'label 1))
                         (cs-pb-type model (hash-set vf 'label 1))))
               (cs-pb-entry-ref model entry))]
          [(= type 14) (cs-pb-entry-ref model (cs-pb-resolve model (hash-ref f 'type-name)))]
          [else (first (cs-pb-scalar f))]))
  (cond [(and (= type 11)
              (eq? (hash-ref (cs-pb-resolve model (hash-ref f 'type-name)) 'kind) 'map))
         singular]
        [(= (hash-ref f 'label) 3) (format "System.Collections.Generic.List<~a>" (cs-pb-type model (hash-set f 'label 1)))]
        [else singular]))

(define (cs-pb-explicit-literal model f)
  (define d (field-explicit-default f))
  (and d
       (case (hash-ref f 'type)
         [(9) (format "~s" d)]
         [(8) d]
         [(14) (format "~a.~a" (cs-pb-entry-ref model (cs-pb-resolve model (hash-ref f 'type-name))) d)]
         [(2) (format "~af" d)]
         [else d])))

(define (cs-pb-default model f)
  (cond [(cs-pb-explicit-literal model f) => (lambda (lit) lit)]
        [(and (= (hash-ref f 'type) 11)
              (eq? (hash-ref (cs-pb-resolve model (hash-ref f 'type-name)) 'kind) 'map))
         (format "new ~a()" (cs-pb-type model f))]
        [(= (hash-ref f 'label) 3) (format "new ~a()" (cs-pb-type model f))]
        [(= (hash-ref f 'type) 11) "null"]
        [(= (hash-ref f 'type) 14)
         (define entry (cs-pb-resolve model (hash-ref f 'type-name)))
         (format "~a.~a" (cs-pb-entry-ref model entry) (hash-ref (car (hash-ref (hash-ref entry 'enum) 'values)) 'name))]
        [else (second (cs-pb-scalar f))]))

(define (cs-pb-varint-expr f v)
  (case (hash-ref f 'type)
    [(8) (format "(~a ? 1 : 0)" v)]
    [(17) (format "((~a << 1) ^ (~a >> 31))" v v)]
    [(18) (format "((~a << 1) ^ (~a >> 63))" v v)]
    [(14) (format "(int) ~a" v)]
    [(4) (format "(long) ~a" v)]
    [else v]))

(define (cs-pb-varint-decode f v)
  (case (hash-ref f 'type)
    [(5) (format "(int) ~a" v)]
    [(13) (format "(uint) ~a" v)]
    [(7) (format "(uint) ~a" v)]
    [(6) (format "(ulong) ~a" v)]
    [(4) (format "(ulong) ~a" v)]
    [(3) v] [(18) (format "((~a >> 1) ^ -(~a & 1))" v v)]
    [(17) (format "(int) ((~a >> 1) ^ -(~a & 1))" v v)]
    [(8) (format "~a != 0" v)]))

(define (cs-pb-nonzero f v)
  (case (hash-ref f 'type)
    [(8) v]
    [(14) (format "(int) ~a != 0" v)]
    [else (format "~a != 0" v)]))

(define (cs-pb-fixed-bits f v)
  (case (hash-ref f 'type)
    [(7) (format "(int) ~a" v)]
    [(6) (format "(long) ~a" v)]
    [else v]))

(define (cs-pb-encode-singular model f v indent)
  (define n (hash-ref f 'number))
  (define type (hash-ref f 'type))
  ;; Proto2 optional/required fields have explicit presence.
  (define proto2? (equal? (hash-ref model 'syntax "") "proto2"))
  (cond [(memv type cs-pb-varint-types)
         (if proto2?
             (format "~a{ w.Tag(~a, 0); w.Varint(~a); }\n" indent n (cs-pb-varint-expr f v))
             (format "~aif (~a) { w.Tag(~a, 0); w.Varint(~a); }\n" indent (cs-pb-nonzero f v) n (cs-pb-varint-expr f v)))]
        [(assv type cs-pb-fixed)
         => (lambda (info)
              (if proto2?
                  (format "~a{ w.Tag(~a, ~a); w.Fixed~a(~a); }\n" indent n
                          (if (= (second info) 8) 1 5) (third info) (cs-pb-fixed-bits f v))
                  (format "~aif (~a) { w.Tag(~a, ~a); w.Fixed~a(~a); }\n" indent (cs-pb-nonzero f v) n
                          (if (= (second info) 8) 1 5) (third info) (cs-pb-fixed-bits f v))))]
        [(= type 9)
         (if proto2?
             (format "~aif (~a != null) w.BytesField(~a, System.Text.Encoding.UTF8.GetBytes(~a));\n" indent v n v)
             (format "~aw.StringField(~a, ~a);\n" indent n v))]
        [(= type 12)
         (if proto2?
             (format "~aif (~a != null) w.BytesField(~a, ~a);\n" indent v n v)
             (format "~aif (~a != null && ~a.Length > 0) w.BytesField(~a, ~a);\n" indent v v n v))]
        [(= type 11) (format "~aif (~a != null) w.BytesField(~a, ~a.MarshalDc());\n" indent v n v)]
        [else (error 'emit-csharp-pb-file "unsupported field type ~a (groups)" type)]))

(define (cs-pb-set-expr model sib)
  (define v (cs-pb-field-name model sib))
  (case (hash-ref sib 'type)
    [(11 10) (format "~a != null" v)]
    [(9) (format "(~a != null && ~a.Length > 0)" v v)]
    [(12) (format "(~a != null && ~a.Length > 0)" v v)]
    [else (cs-pb-nonzero sib v)]))

;; Encode-side oneof clearing: suppress f when a later sibling is
;; set, so only the winning member is written.
(define (cs-pb-encode-guard model f code)
  (define later (oneof-later-siblings model f))
  (if (null? later)
      code
      (format "        if (!(~a)) {\n~a        }\n"
              (string-join (map (lambda (sib) (cs-pb-set-expr model sib)) later) " || ")
              (if (string-suffix? code "\n") code (string-append code "\n")))))

(define (cs-pb-encode-field model f support)
  (define v (cs-pb-field-name model f))
  (define n (hash-ref f 'number))
  (define type (hash-ref f 'type))
  (cond [(and (= type 11)
              (eq? (hash-ref (cs-pb-resolve model (hash-ref f 'type-name)) 'kind) 'map))
         (define entry (cs-pb-resolve model (hash-ref f 'type-name)))
         (define helper (format "~a.~aEncode" support (cs-pb-map-helper-name model entry)))
         (format "        if (~a != null) foreach (var e in ~a) w.BytesField(~a, ~a(e.Key, e.Value));\n" v v n helper)]
        [(not (= (hash-ref f 'label) 3)) (cs-pb-encode-singular model f v "        ")]
        [(memv type cs-pb-varint-types)
         (string-append
          (format "        if (~a != null && ~a.Count > 0) {\n" v v)
          (format "            var payload = new ~a.Writer();\n" support)
          (format "            foreach (var x in ~a) payload.Varint(~a);\n" v (cs-pb-varint-expr f "x"))
          (format "            w.BytesField(~a, payload.ToBytes());\n        }\n" n))]
        [(assv type cs-pb-fixed)
         => (lambda (info)
              (string-append
               (format "        if (~a != null && ~a.Count > 0) {\n" v v)
               (format "            var payload = new ~a.Writer();\n" support)
               (format "            foreach (var x in ~a) payload.Fixed~a(~a);\n" v (third info) (cs-pb-fixed-bits f "x"))
               (format "            w.BytesField(~a, payload.ToBytes());\n        }\n" n)))]
        [(= type 9) (format "        if (~a != null) foreach (var x in ~a) w.BytesField(~a, System.Text.Encoding.UTF8.GetBytes(x));\n" v v n)]
        [(= type 12) (format "        if (~a != null) foreach (var x in ~a) w.BytesField(~a, x);\n" v v n)]
        [(= type 11) (format "        if (~a != null) foreach (var x in ~a) w.BytesField(~a, x.MarshalDc());\n" v v n)]
        [else (error 'emit-csharp-pb-file "unsupported repeated field type ~a" type)]))

(define (cs-pb-decode-singular model f target src indent)
  (define type (hash-ref f 'type))
  (cond [(memv type cs-pb-varint-types)
         (format "~a~a = ~a;\n" indent target
                 (if (= type 14)
                     (format "(~a) ~a" (cs-pb-entry-ref model (cs-pb-resolve model (hash-ref f 'type-name))) (cs-pb-varint-decode (hash-set f 'type 5) src))
                     (cs-pb-varint-decode f src)))]
        [(assv type cs-pb-fixed)
         => (lambda (info)
              (format "~a~a = ~a;\n" indent target
                      (case (hash-ref f 'type)
                        [(2) (format "BitConverter.Int32BitsToSingle((int) ~a)" src)]
                        [(1) (format "BitConverter.Int64BitsToDouble(~a)" src)]
                        [(7) (format "(uint) ~a" src)]
                        [(15) (format "(int) ~a" src)]
                        [(6) (format "(ulong) ~a" src)]
                        [else src])))]
        [(= type 9) (format "~a~a = System.Text.Encoding.UTF8.GetString(~a);\n" indent target src)]
        [(= type 12) (format "~a~a = ~a;\n" indent target src)]
        [(= type 11)
         (define ref (cs-pb-entry-ref model (cs-pb-resolve model (hash-ref f 'type-name))))
         (string-append
          (format "~a~a = new ~a();\n" indent target ref)
          (format "~a~a.UnmarshalDc(~a);\n" indent target src))]
        [else (error 'emit-csharp-pb-file "unsupported field type ~a" type)]))

(define (cs-pb-oneof-clearing model f)
  (apply string-append
         (map (lambda (sib)
                (format "                    ~a = ~a;\n" (cs-pb-field-name model sib) (cs-pb-default model sib)))
              (oneof-siblings model f))))

(define (cs-pb-decode-case model f support)
  (define v (cs-pb-field-name model f))
  (define type (hash-ref f 'type))
  (define head (format "                case ~a: {\n" (hash-ref f 'number)))
  (define clearing (cs-pb-oneof-clearing model f))
  (define tail "                    break;\n                }\n")
  (cond [(and (= type 11)
              (eq? (hash-ref (cs-pb-resolve model (hash-ref f 'type-name)) 'kind) 'map))
         (define entry (cs-pb-resolve model (hash-ref f 'type-name)))
         (define helper (format "~a.~aDecode" support (cs-pb-map-helper-name model entry)))
         (string-append head
                        (format "                    var kv = ~a(field.BytesValue);\n" helper)
                        (format "                    ~a[(~a) kv[0]] = (~a) kv[1];\n" v
                                (cs-pb-type model (hash-set (findf (lambda (x) (= (hash-ref x 'number) 1)) (hash-ref (hash-ref entry 'msg) 'fields)) 'label 1))
                                (cs-pb-type model (hash-set (findf (lambda (x) (= (hash-ref x 'number) 2)) (hash-ref (hash-ref entry 'msg) 'fields)) 'label 1)))
                        tail)]
        [(not (= (hash-ref f 'label) 3))
         (string-append head
                        clearing
                        (cs-pb-decode-singular model f v
                                               (cond [(memv type cs-pb-varint-types) "field.VarintValue"]
                                                     [(assv type cs-pb-fixed) "field.FixedValue"]
                                                     [else "field.BytesValue"])
                                               "                    ")
                        tail)]
        [(memv type cs-pb-varint-types)
         (string-append head
                        "                    if (field.Wire == 2) {\n"
                        (format "                        var sub = new ~a.Reader(field.BytesValue);\n" support)
                        "                        while (!sub.Done) {\n"
                        (format "                            ~a.Add(~a);\n" v
                                (let ([conv (cs-pb-varint-decode f "sub.Varint()")])
                                  (if (= type 14)
                                      (format "(~a) ~a" (cs-pb-entry-ref model (cs-pb-resolve model (hash-ref f 'type-name))) (cs-pb-varint-decode (hash-set f 'type 5) "sub.Varint()"))
                                      conv)))
                        "                        }\n                    } else {\n"
                        (format "                        ~a.Add(~a);\n" v
                                (let ([conv (cs-pb-varint-decode f "field.VarintValue")])
                                  (if (= type 14)
                                      (format "(~a) ~a" (cs-pb-entry-ref model (cs-pb-resolve model (hash-ref f 'type-name))) (cs-pb-varint-decode (hash-set f 'type 5) "field.VarintValue"))
                                      conv)))
                        "                    }\n" tail)]
        [(assv type cs-pb-fixed)
         => (lambda (info)
              (string-append head
                             "                    if (field.Wire == 2) {\n"
                             (format "                        var sub = new ~a.Reader(field.BytesValue);\n" support)
                             (format "                        while (!sub.Done) ~a.Add(~a);\n" v
                                     (case (hash-ref f 'type)
                                       [(2) "BitConverter.Int32BitsToSingle(sub.Fixed32())"]
                                       [(1) "BitConverter.Int64BitsToDouble(sub.Fixed64())"]
                                       [(7) "(uint) sub.Fixed32()"]
                                       [(15) "sub.Fixed32()"]
                                       [else "sub.Fixed64()"]))
                             "                    } else {\n"
                             (format "                        ~a.Add(~a);\n" v
                                     (case (hash-ref f 'type)
                                       [(2) "BitConverter.Int32BitsToSingle((int) field.FixedValue)"]
                                       [(1) "BitConverter.Int64BitsToDouble(field.FixedValue)"]
                                       [(7) "(uint) field.FixedValue"]
                                       [(15) "(int) field.FixedValue"]
                                       [else "field.FixedValue"]))
                             "                    }\n" tail))]
        [(= type 9) (string-append head (format "                    ~a.Add(System.Text.Encoding.UTF8.GetString(field.BytesValue));\n" v) tail)]
        [(= type 12) (string-append head (format "                    ~a.Add(field.BytesValue);\n" v) tail)]
        [(= type 11)
         (string-append head
                        (format "                    var item = new ~a();\n" (cs-pb-type model (hash-set f 'label 1)))
                        "                    item.UnmarshalDc(field.BytesValue);\n"
                        (format "                    ~a.Add(item);\n" v) tail)]
        [else (error 'emit-csharp-pb-file "unsupported repeated field type ~a" type)]))

(define (cs-pb-map-helper-name model entry)
  (define rel (cs-pb-rel (hash-ref entry 'pkg) (hash-ref (hash-ref entry 'msg) 'full-name)))
  (string-join (string-split rel ".") ""))

(define (cs-pb-map-helpers model entry support)
  (define msg (hash-ref entry 'msg))
  (define base (cs-pb-map-helper-name model entry))
  (define key-f (findf (lambda (x) (= (hash-ref x 'number) 1)) (hash-ref msg 'fields)))
  (define val-f (findf (lambda (x) (= (hash-ref x 'number) 2)) (hash-ref msg 'fields)))
  (unless (and key-f val-f) (error 'emit-csharp-pb-file "map entry ~a lacks key/value" (hash-ref msg 'full-name)))
  (define kt (cs-pb-type model (hash-set key-f 'label 1)))
  (define vt (cs-pb-type model (hash-set val-f 'label 1)))
  (string-append
   (format "    internal static byte[] ~aEncode(~a key, ~a value) {\n" base kt vt)
   "        var w = new Writer();\n"
   (cs-pb-encode-singular model (hash-set key-f 'label 1) "key" "        ")
   (cs-pb-encode-singular model (hash-set val-f 'label 1) "value" "        ")
   "        return w.ToBytes();\n    }\n\n"
   (format "    internal static object[] ~aDecode(byte[] bytes) {\n" base)
   (format "        ~a key = ~a;\n" kt (cs-pb-default model (hash-set key-f 'label 1)))
   (format "        ~a value = ~a;\n" vt (cs-pb-default model (hash-set val-f 'label 1)))
   "        var r = new Reader(bytes);\n        Field field;\n        while ((field = r.Next()) != null) {\n            switch (field.Number) {\n"
   (format "                case ~a: ~a break;\n" (hash-ref key-f 'number)
           (string-trim (cs-pb-decode-singular model (hash-set key-f 'label 1) "key"
                                               (cond [(memv (hash-ref key-f 'type) cs-pb-varint-types) "field.VarintValue"]
                                                     [(assv (hash-ref key-f 'type) cs-pb-fixed) "field.FixedValue"]
                                                     [else "field.BytesValue"]) "") "\n" #:left? #f #:repeat? #t))
   (format "                case ~a: ~a break;\n" (hash-ref val-f 'number)
           (string-trim (cs-pb-decode-singular model (hash-set val-f 'label 1) "value"
                                               (cond [(memv (hash-ref val-f 'type) cs-pb-varint-types) "field.VarintValue"]
                                                     [(assv (hash-ref val-f 'type) cs-pb-fixed) "field.FixedValue"]
                                                     [else "field.BytesValue"]) "") "\n" #:left? #f #:repeat? #t))
   "                default: break;\n            }\n        }\n        return new object[] { key, value };\n    }\n\n"))

(define (cs-pb-support-class base pkg)
  (string-append
   "// @generated by protoc-gen-grpc-dc-csharp. DO NOT EDIT.\n"
   "using System;\n\n"
   (format "namespace ~a;\n\n" (cs-pb-ns pkg))
   (format "internal static class ~aPb {\n" (pascal (string->symbol base)))
   "    internal sealed class Writer {\n"
   "        private readonly System.IO.MemoryStream _out = new();\n"
   "        public void Varint(long value) { ulong v = unchecked((ulong) value); while ((v & ~0x7fUL) != 0) { _out.WriteByte((byte) ((v & 0x7f) | 0x80)); v >>= 7; } _out.WriteByte((byte) v); }\n"
   "        public void Tag(int field, int wire) { Varint((field << 3) | wire); }\n"
   "        public void BytesField(int field, byte[] payload) { Tag(field, 2); Varint(payload.Length); _out.Write(payload, 0, payload.Length); }\n"
   "        public void StringField(int field, string value) { if (string.IsNullOrEmpty(value)) return; BytesField(field, System.Text.Encoding.UTF8.GetBytes(value)); }\n"
   "        public void Raw(byte[] payload) { _out.Write(payload, 0, payload.Length); }\n"
   "        public void FixedInt(int value) { _out.WriteByte((byte) value); _out.WriteByte((byte) (value >> 8)); _out.WriteByte((byte) (value >> 16)); _out.WriteByte((byte) (value >> 24)); }\n"
   "        public void FixedLong(long value) { for (int i = 0; i < 8; i++) _out.WriteByte((byte) (value >> (8 * i))); }\n"
   "        public void FixedFloat(float value) { FixedInt(BitConverter.SingleToInt32Bits(value)); }\n"
   "        public void FixedDouble(double value) { FixedLong(BitConverter.DoubleToInt64Bits(value)); }\n"
   "        public byte[] ToBytes() => _out.ToArray();\n"
   "    }\n\n"
   "    internal static byte[] ConcatBytes(byte[] a, byte[] b) { var o = new byte[a.Length + b.Length]; Array.Copy(a, o, a.Length); Array.Copy(b, 0, o, a.Length, b.Length); return o; }\n\n"
   "    internal sealed class Field {\n"
   "        public int Number { get; } public int Wire { get; } public long VarintValue { get; } public byte[] BytesValue { get; } public long FixedValue { get; } public byte[] RawValue { get; }\n"
   "        internal Field(int number, int wire, long varintValue, byte[] bytesValue, long fixedValue, byte[] rawValue) { Number = number; Wire = wire; VarintValue = varintValue; BytesValue = bytesValue; FixedValue = fixedValue; RawValue = rawValue; }\n"
   "    }\n\n"
   "    internal sealed class Reader {\n"
   "        private readonly byte[] _buf; private int _pos;\n"
   "        internal Reader(byte[] buf) { _buf = buf; }\n"
   "        public bool Done => _pos >= _buf.Length;\n"
   "        public long Varint() { long result = 0; int shift = 0; while (true) { if (_pos >= _buf.Length) throw new ArgumentException(\"truncated varint\"); int b = _buf[_pos++]; result |= (long) (b & 0x7f) << shift; if ((b & 0x80) == 0) return result; shift += 7; if (shift >= 64) throw new ArgumentException(\"varint too long\"); } }\n"
   "        public byte[] Take(int n) { if (_pos + n > _buf.Length) throw new ArgumentException(\"truncated field\"); var v = new byte[n]; Array.Copy(_buf, _pos, v, 0, n); _pos += n; return v; }\n"
   "        public byte[] TakeFrom(int start) { var v = new byte[_pos - start]; Array.Copy(_buf, start, v, 0, v.Length); return v; }\n"
   "        public int Fixed32() { var b = Take(4); return b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24); }\n"
   "        public long Fixed64() { var b = Take(8); long v = 0; for (int i = 0; i < 8; i++) v |= (long) b[i] << (8 * i); return v; }\n"
   "        public Field Next() {\n"
   "            if (_pos >= _buf.Length) return null;\n"
   "            int start = _pos;\n"
   "            long tag = Varint(); int number = (int) (tag >> 3); int wire = (int) (tag & 7);\n"
   "            switch (wire) {\n"
   "                case 0: { long v = Varint(); return new Field(number, wire, v, null, 0, TakeFrom(start)); }\n"
   "                case 2: { int n = (int) Varint(); var b = Take(n); return new Field(number, wire, 0, b, 0, TakeFrom(start)); }\n"
   "                case 1: { var b = Take(8); long v = 0; for (int i = 0; i < 8; i++) v |= (long) b[i] << (8 * i); return new Field(number, wire, 0, b, v, TakeFrom(start)); }\n"
   "                case 5: { var b = Take(4); int v = b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24); return new Field(number, wire, 0, b, v, TakeFrom(start)); }\n"
   "                default: throw new ArgumentException(\"bad wire type \" + wire);\n"
   "            }\n"
   "        }\n"
   "    }\n"
   "}\n"))

(define (cs-pb-message-class model msg support indent decl)
  (define name (hash-ref msg 'name))
  (define fields (hash-ref msg 'fields))
  (define pad indent)
  (define pad2 (string-append indent "    "))
  (string-append
   (format "~a~a class ~a : IMarshaler, IUnmarshaler {\n" pad decl name)
   (apply string-append
          (map (lambda (f)
                 (format "~a    public ~a ~a = ~a;\n" pad (cs-pb-type model f)
                         (cs-pb-field-name model f) (cs-pb-default model f)))
               fields))
   (format "~a    public byte[] UnknownFields = new byte[0];\n" pad)
   (format "~a    public ~a() {}\n" pad name)
   (if (null? fields)
       ""
       (string-append
        (format "~a    public ~a(~a) {\n" pad name
                (string-join (map (lambda (f) (format "~a ~a" (cs-pb-type model f)
                                                      (let ([n (cs-pb-field-name model f)])
                                                        (string-append (string (char-downcase (string-ref n 0))) (substring n 1)))))
                                  fields) ", "))
        (apply string-append
               (map (lambda (f)
                      (let ([n (cs-pb-field-name model f)])
                        (format "~a        ~a = ~a;\n" pad n
                                (string-append (string (char-downcase (string-ref n 0))) (substring n 1)))))
                    fields))
        (format "~a    }\n" pad)))
   (format "~a    public byte[] MarshalDc() {\n" pad)
   (format "~a        var w = new ~a.Writer();\n" pad support)
   (apply string-append (map (lambda (f) (cs-pb-encode-guard model f (cs-pb-encode-field model f support))) fields))
   (format "~a        w.Raw(UnknownFields);\n" pad)
   (format "~a        return w.ToBytes();\n~a    }\n" pad pad)
   (format "~a    public void UnmarshalDc(byte[] data) {\n" pad)
   (format "~a        UnknownFields = new byte[0];\n" pad)
   (apply string-append
          (map (lambda (f) (format "~a        ~a = ~a;\n" pad (cs-pb-field-name model f) (cs-pb-default model f))) fields))
   (format "~a        var r = new ~a.Reader(data);\n" pad support)
   (format "~a        ~a.Field field;\n" pad support)
   (format "~a        while ((field = r.Next()) != null) {\n~a            switch (field.Number) {\n" pad pad)
   (apply string-append (map (lambda (f) (cs-pb-decode-case model f support)) fields))
   (format "~a                default: UnknownFields = ~a.ConcatBytes(UnknownFields, field.RawValue); break;\n~a            }\n~a        }\n~a    }\n" pad support pad pad pad)
   (apply string-append (map (lambda (n) (cs-pb-message-class model n support (string-append indent "    ") "public sealed")) (hash-ref msg 'nested)))
   (apply string-append (map (lambda (e) (cs-pb-nested-enum e (string-append indent "    "))) (hash-ref msg 'enums)))
   (format "~a}\n" pad)))

(define (cs-pb-nested-enum e indent)
  (string-append
   (format "~apublic enum ~a {\n" indent (hash-ref e 'name))
   (string-join (map (lambda (v) (format "~a    ~a = ~a" indent (hash-ref v 'name) (hash-ref v 'number)))
                     (hash-ref e 'values)) ",\n")
   (format "\n~a}\n" indent)))

(define (cs-pb-top-enum model e pkg)
  (string-append
   "// @generated by protoc-gen-grpc-dc-csharp. DO NOT EDIT.\n"
   (format "namespace ~a;\n\n" (cs-pb-ns pkg))
   (format "public enum ~a {\n" (hash-ref e 'name))
   (string-join (map (lambda (v) (format "    ~a = ~a" (hash-ref v 'name) (hash-ref v 'number)))
                     (hash-ref e 'values)) ",\n")
   "\n}\n"))

(define (emit-csharp-pb-files file-model)
  (and (hash-has-key? file-model 'messages)
       (hash-has-key? file-model 'types)
       (emit-csharp-pb-files/inner file-model)))

(define (emit-csharp-pb-files/inner file-model)
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
               (define e (cs-pb-resolve file-model (hash-ref f 'type-name)))
               (when (and (eq? (hash-ref e 'kind) 'map)
                          (not (set-member? seen-maps (hash-ref (hash-ref e 'msg) 'full-name))))
                 (set-add! seen-maps (hash-ref (hash-ref e 'msg) 'full-name))
                 (set! helpers (cons (cs-pb-map-helpers file-model e support) helpers)))))
           (for ([n (in-list (hash-ref msg 'nested))]) (collect n)))
         (for ([m (in-list messages)]) (collect m))
         (define support-content
           (string-append
            "// @generated by protoc-gen-grpc-dc-csharp. DO NOT EDIT.\n"
            "using System;\nusing Grpcdc;\n\n"
            (format "namespace ~a;\n\n" (cs-pb-ns pkg))))
         (define support-full
           (let ([sc (cs-pb-support-class base pkg)])
             (if (null? helpers)
                 sc
                 (string-replace sc "    internal sealed class Writer {"
                                 (string-append (apply string-append (reverse helpers))
                                                "    internal sealed class Writer {")))))
         (append
          (list (cons (string-append support ".cs") support-full))
          (map (lambda (m)
                 (cons (string-append (hash-ref m 'name) ".cs")
                       (string-append
                        "// @generated by protoc-gen-grpc-dc-csharp. DO NOT EDIT.\n"
                        "using System;\nusing Grpcdc;\n\n"
                        (format "namespace ~a;\n\n" (cs-pb-ns pkg))
                        (cs-pb-message-class file-model m support "" "public sealed"))))
               (filter (lambda (m) (not (hash-ref m 'map-entry))) messages))
          (map (lambda (e) (cons (string-append (hash-ref e 'name) ".cs")
                                 (cs-pb-top-enum file-model e pkg)))
               enums)))))

(define (emit-csharp-file file-model params)
  (define base (path->string (path-replace-extension
                              (file-name-from-path (hash-ref file-model 'name)) "")))
  (define class-name (string-append (pascal (string->symbol base)) "GrpcDc"))
  (define pkg (hash-ref file-model 'package))
  (define ns (if (string=? pkg "") "Proto" (pascal (string->symbol pkg))))
  (define stub
    (cons (string-append class-name ".cs")
          (string-append
           "// @generated by protoc-gen-grpc-dc-csharp. DO NOT EDIT.\n"
         (format "// source: ~a\n\n" (hash-ref file-model 'name))
         "using System;\n"
         "using System.Collections.Generic;\n"
         "using System.Runtime.CompilerServices;\n"
         "using System.Threading;\n"
         "using System.Threading.Tasks;\n"
         "using Grpcdc;\n\n"
         (format "namespace ~a;\n\n" ns)
         (format "/// <summary>Generated gRPC-over-DataChannels stubs for ~a.</summary>\n" (hash-ref file-model 'name))
         (format "public static class ~a\n{\n" class-name)
         ;; trace=hooks: delegate the tracer registrar to Grpcdc.Tracing.
         (if (equal? (hash-ref params 'trace #f) "hooks")
             (string-append
              "    // Tracing (trace=hooks): register an observer via SetTracer.\n"
              "    public static void SetTracer(ITracer tracer) => Tracing.SetTracer(tracer);\n"
              "    public static void SetTraceFilter(string patterns) => Tracing.SetTraceFilter(patterns);\n"
              (let ([methods (hash-ref params 'trace_methods #f)])
                (if methods
                    (format "    static ~a() { Tracing.SetTraceFilter(~s); }\n" class-name methods)
                    ""))
              "\n")
             "")
         (apply string-append
                (map csharp-service
                     (cs-qualify-services pkg (hash-ref file-model 'services))))
         "}\n")))
  (define pb-files (emit-csharp-pb-files file-model))
  (if pb-files (cons stub pb-files) stub))
