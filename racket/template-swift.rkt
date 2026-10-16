#lang racket

;;; template-swift.rkt — emitter body spliced into
;;; protoc-gen-grpc-dc-swift.
;;;
;;; Generated code is one enum <Base>GrpcDc namespace in the proto
;;; package, beside hand-written message types conforming to
;;; Marshaler / Unmarshaler. Method names keep the proto spelling,
;;; mirroring the other language stubs.

(require "spec.rkt" "desc.rkt")
(provide emit-swift-file)

(define current-service (make-parameter ""))

(define (pascal sym) ; echo_service -> EchoService ; echo -> Echo
  (apply string-append
         (for/list ([part (in-list (string-split (symbol->string sym) "[_.-]"))])
           (if (string=? part "")
               ""
               (string-append (string (char-upcase (string-ref part 0)))
                              (substring part 1))))))

(define (swift-deprecated m indent)
  (if (hash-ref m 'deprecated #f)
      (format "~a@available(*, deprecated, message: \"deprecated in the proto schema\")\n" indent)
      ""))

(define (swift-client-method/raw m)
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define path (hash-ref m 'path))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(unary)
     (format (string-append
              "        func ~a(_ req: ~a, _ metadata: [String: String]? = nil, _ timeout: Double? = nil) throws -> ~a {\n"
              "            let resp = ~a()\n"
              "            try channel.Unary(~s, req, resp, metadata, timeout)\n"
              "            return resp\n"
              "        }\n\n")
             name req resp resp path)]
    [(server-streaming)
     (format (string-append
              "        func ~a(_ req: ~a, _ metadata: [String: String]? = nil, _ timeout: Double? = nil) throws -> ~a~aStream {\n"
              "            return ~a~aStream(try channel.ServerStream(~s, req, metadata, timeout))\n"
              "        }\n\n")
             name req svc name svc name path)]
    [(client-streaming)
     (format (string-append
              "        func ~a(_ reqs: [~a], _ metadata: [String: String]? = nil, _ timeout: Double? = nil) throws -> ~a {\n"
              "            let resp = ~a()\n"
              "            try channel.ClientStreamCall(~s, reqs, resp, metadata, timeout)\n"
              "            return resp\n"
              "        }\n\n")
             name req resp resp path)]
    [(bidi)
     (format (string-append
              "        func ~a(_ reqs: [~a], _ metadata: [String: String]? = nil, _ timeout: Double? = nil) throws -> ~a~aStream {\n"
              "            return ~a~aStream(try channel.Bidi(~s, reqs, metadata, timeout))\n"
              "        }\n\n")
             name req svc name svc name path)]))

(define (swift-client-method m)
  (string-append (swift-deprecated m "        ") (swift-client-method/raw m)))

(define (swift-client-stream-class m)
  (define name (hash-ref m 'name))
  (define resp (hash-ref m 'output))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(server-streaming bidi)
     (format (string-append
              "        final class ~a~aStream {\n"
              "            private let stream: Channel.ClientStream\n"
              "            init(_ stream: Channel.ClientStream) { self.stream = stream }\n"
              "            func Recv() throws -> ~a {\n"
              "                let resp = ~a()\n"
              "                try stream.Recv(resp)\n"
              "                return resp\n"
              "            }\n"
              "        }\n\n")
             svc name resp resp)]
    [else ""]))

(define (swift-client-async-method m)
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (case (hash-ref m 'kind)
    [(unary)
     (format (string-append
              "        func ~aAsync(_ req: ~a, _ metadata: [String: String]? = nil, _ timeout: Double? = nil) async throws -> ~a {\n"
              "            try await Task.detached { try self.~a(req, metadata, timeout) }.value\n"
              "        }\n\n")
             name req resp name)]
    [(server-streaming bidi)
     (format (string-append
              "        func ~aAsync(_ reqs: ~a, _ metadata: [String: String]? = nil, _ timeout: Double? = nil) -> AsyncThrowingStream<~a, Error> {\n"
              "            AsyncThrowingStream { continuation in\n"
              "                let task = Task.detached {\n"
              "                    do {\n"
              "                        let stream = try self.~a(reqs, metadata, timeout)\n"
              "                        while true {\n"
              "                            continuation.yield(try stream.Recv())\n"
              "                        }\n"
              "                    } catch is EndOfStreamError {\n"
              "                        continuation.finish()\n"
              "                    } catch {\n"
              "                        continuation.finish(throwing: error)\n"
              "                    }\n"
              "                }\n"
              "                continuation.onTermination = { _ in task.cancel() }\n"
              "            }\n"
              "        }\n\n")
             name (if (eq? (hash-ref m 'kind) 'bidi) (format "[~a]" req) req) resp name)]
    [(client-streaming)
     (format (string-append
              "        func ~aAsync(_ reqs: [~a], _ metadata: [String: String]? = nil, _ timeout: Double? = nil) async throws -> ~a {\n"
              "            try await Task.detached { try self.~a(reqs, metadata, timeout) }.value\n"
              "        }\n\n")
             name req resp name)]))

(define (swift-server-stream-iface m)
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(unary) ""]
    [(server-streaming)
     (format (string-append
              "    /// Server-streaming sink passed to service implementations.\n"
              "    protocol ~a~aServer: AnyObject {\n"
              "        func Send(_ resp: ~a) throws\n"
              "        var context: Endpoint.CallContext { get }\n"
              "    }\n\n")
             svc name resp)]
    [(client-streaming)
     (format (string-append
              "    /// Client-streaming stream passed to service implementations.\n"
              "    protocol ~a~aServer: AnyObject {\n"
              "        func Recv() throws -> ~a\n"
              "        func SendAndClose(_ resp: ~a)\n"
              "        var context: Endpoint.CallContext { get }\n"
              "    }\n\n")
             svc name req resp)]
    [(bidi)
     (format (string-append
              "    /// Bidi stream passed to service implementations.\n"
              "    protocol ~a~aServer: AnyObject {\n"
              "        func Send(_ resp: ~a) throws\n"
              "        func Recv() throws -> ~a\n"
              "        var context: Endpoint.CallContext { get }\n"
              "    }\n\n")
             svc name resp req)]))

(define (swift-server-iface-method/raw m)
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(unary)
     (format "        func ~a(_ ctx: Endpoint.CallContext, _ req: ~a) throws -> ~a\n" name req resp)]
    [(server-streaming)
     (format "        func ~a(_ req: ~a, _ stream: ~a~aServer) throws\n" name req svc name)]
    [(client-streaming)
     (format "        func ~a(_ stream: ~a~aServer) throws\n" name svc name)]
    [(bidi)
     (format "        func ~a(_ stream: ~a~aServer) throws\n" name svc name)]))

(define (swift-server-iface-method m)
  (string-append (swift-deprecated m "        ") (swift-server-iface-method/raw m)))

(define (swift-server-async-iface-method m)
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(unary)
     (format "        func ~aAsync(_ ctx: Endpoint.CallContext, _ req: ~a) async throws -> ~a\n" name req resp)]
    [(server-streaming)
     (format "        func ~aAsync(_ req: ~a, _ stream: ~a~aServer) async throws\n" name req svc name)]
    [(client-streaming)
     (format "        func ~aAsync(_ stream: ~a~aServer) async throws\n" name svc name)]
    [(bidi)
     (format "        func ~aAsync(_ stream: ~a~aServer) async throws\n" name svc name)]))

(define (swift-server-async-adapter-method m)
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(unary)
     (format (string-append
              "        func ~a(_ ctx: Endpoint.CallContext, _ req: ~a) throws -> ~a {\n"
              "            try RunBlocking { try await self.impl.~aAsync(ctx, req) }\n"
              "        }\n")
             name req resp name)]
    [(server-streaming)
     (format (string-append
              "        func ~a(_ req: ~a, _ stream: ~a~aServer) throws {\n"
              "            try RunBlocking { try await self.impl.~aAsync(req, stream) }\n"
              "        }\n")
             name req svc name name)]
    [(client-streaming)
     (format (string-append
              "        func ~a(_ stream: ~a~aServer) throws {\n"
              "            try RunBlocking { try await self.impl.~aAsync(stream) }\n"
              "        }\n")
             name svc name name)]
    [(bidi)
     (format (string-append
              "        func ~a(_ stream: ~a~aServer) throws {\n"
              "            try RunBlocking { try await self.impl.~aAsync(stream) }\n"
              "        }\n")
             name svc name name)]))

(define (swift-stream-impl m)
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(unary) ""]
    [(server-streaming)
     (format (string-append
              "    private final class ~a~aServerImpl: ~a~aServer {\n"
              "        private var ctxRef: Endpoint.CallContext\n"
              "        private let sink: Server.ServerSink\n"
              "        init(_ ctx: Endpoint.CallContext, _ sink: @escaping Server.ServerSink) {\n"
              "            ctxRef = ctx\n"
              "            self.sink = sink\n"
              "        }\n"
              "        func Send(_ resp: ~a) throws { try sink(resp.MarshalDc()) }\n"
              "        var context: Endpoint.CallContext { ctxRef }\n"
              "    }\n\n")
             svc name svc name resp)]
    [(client-streaming)
     (format (string-append
              "    private final class ~a~aServerImpl: ~a~aServer {\n"
              "        private var ctxRef: Endpoint.CallContext\n"
              "        private let reqs: Server.RequestStream\n"
              "        private(set) var resp: ~a?\n"
              "        init(_ ctx: Endpoint.CallContext, _ reqs: Server.RequestStream) {\n"
              "            ctxRef = ctx\n"
              "            self.reqs = reqs\n"
              "        }\n"
              "        func Recv() throws -> ~a {\n"
              "            let req = ~a()\n"
              "            try reqs.RecvInto(req)\n"
              "            return req\n"
              "        }\n"
              "        func SendAndClose(_ resp: ~a) { self.resp = resp }\n"
              "        var context: Endpoint.CallContext { ctxRef }\n"
              "    }\n\n")
             svc name svc name resp req req resp)]
    [(bidi)
     (format (string-append
              "    private final class ~a~aServerImpl: ~a~aServer {\n"
              "        private var ctxRef: Endpoint.CallContext\n"
              "        private let reqs: Server.RequestStream\n"
              "        private let sink: Server.ServerSink\n"
              "        init(_ ctx: Endpoint.CallContext, _ reqs: Server.RequestStream, _ sink: @escaping Server.ServerSink) {\n"
              "            ctxRef = ctx\n"
              "            self.reqs = reqs\n"
              "            self.sink = sink\n"
              "        }\n"
              "        func Send(_ resp: ~a) throws { try sink(resp.MarshalDc()) }\n"
              "        func Recv() throws -> ~a {\n"
              "            let req = ~a()\n"
              "            try reqs.RecvInto(req)\n"
              "            return req\n"
              "        }\n"
              "        var context: Endpoint.CallContext { ctxRef }\n"
              "    }\n\n")
             svc name svc name resp req req)]))

(define (swift-register-method m)
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
              "            Server.Method(name: ~s, path: ~s, kind: Server.~a) { ctx, reqs, sink in\n"
              "                let req = ~a()\n"
              "                try reqs.RecvInto(req)\n"
              "                let resp = try impl.~a(ctx, req)\n"
              "                try sink(resp.MarshalDc())\n"
              "            },\n")
             name (hash-ref m 'path) kind-const req impl-name)]
    [(server-streaming)
     (format (string-append
              "            Server.Method(name: ~s, path: ~s, kind: Server.~a) { ctx, reqs, sink in\n"
              "                let req = ~a()\n"
              "                try reqs.RecvInto(req)\n"
              "                try impl.~a(req, ~a~aServerImpl(ctx, sink))\n"
              "            },\n")
             name (hash-ref m 'path) kind-const req impl-name svc name)]
    [(client-streaming)
     (format (string-append
              "            Server.Method(name: ~s, path: ~s, kind: Server.~a) { ctx, reqs, sink in\n"
              "                let stream = ~a~aServerImpl(ctx, reqs)\n"
              "                try impl.~a(stream)\n"
              "                guard let resp = stream.resp else {\n"
              "                    throw StatusException(Wire.CodeInternal, \"client-streaming handler never called SendAndClose\")\n"
              "                }\n"
              "                try sink(resp.MarshalDc())\n"
              "            },\n")
             name (hash-ref m 'path) kind-const svc name impl-name)]
    [(bidi)
     (format (string-append
              "            Server.Method(name: ~s, path: ~s, kind: Server.~a) { ctx, reqs, sink in\n"
              "                try impl.~a(~a~aServerImpl(ctx, reqs, sink))\n"
              "            },\n")
             name (hash-ref m 'path) kind-const impl-name svc name)]))

(define (swift-service svc)
  (define sname (hash-ref svc 'name))
  (define methods (hash-ref svc 'methods))
  (parameterize ([current-service sname])
    (string-append
     (format "    /// Client for ~a.\n" (hash-ref svc 'full-name))
     (format "    final class ~aClient {\n" sname)
     "        private let channel: Channel\n\n"
     "        init(_ channel: Channel) {\n            self.channel = channel\n        }\n\n"
     (apply string-append (map swift-client-stream-class methods))
     (apply string-append (map swift-client-method (append methods (alias-client-methods svc))))
     "        // -- async (Swift concurrency) surface ---------------------------\n"
     "        #if canImport(Foundation)\n\n"
     (apply string-append (map swift-client-async-method (append methods (alias-client-methods svc))))
     "        #endif\n"
     "    }\n\n"
     (apply string-append (map swift-server-stream-iface methods))
     (format "    /// Service implementation interface for ~a.\n" (hash-ref svc 'full-name))
     (format "    protocol ~aServer: AnyObject {\n" sname)
     (apply string-append (map swift-server-iface-method methods))
     "    }\n\n"
     "    #if canImport(Foundation)\n"
     (format "    /// Async service implementation interface for ~a.\n" (hash-ref svc 'full-name))
     (format "    protocol ~aServerAsync: AnyObject {\n" sname)
     (apply string-append (map swift-server-async-iface-method methods))
     "    }\n\n"
     (apply string-append (map swift-stream-impl methods))
     (format "    private final class ~aServerAsyncAdapter: ~aServer {\n" sname sname)
     (format "        private let impl: ~aServerAsync\n" sname)
     (format "        init(_ impl: ~aServerAsync) { self.impl = impl }\n" sname)
     (apply string-append (map swift-server-async-adapter-method methods))
     "    }\n\n"
     (format "    /// Register an implementation of ~a on a Server.\n" (hash-ref svc 'full-name))
     (format "    static func Register~aServer(_ server: Server, _ impl: ~aServer) {\n" sname sname)
     (format "        server.RegisterService(Server.ServiceDesc(name: ~s, methods: [\n"
             (hash-ref svc 'full-name))
     (apply string-append (map swift-register-method (append methods (alias-server-methods svc))))
     "        ]))\n    }\n\n"
     (format "    /// Register an async implementation of ~a on a Server.\n" (hash-ref svc 'full-name))
     (format "    static func Register~aServerAsync(_ server: Server, _ impl: ~aServerAsync) {\n" sname sname)
     "        // Adapters are retained for the process lifetime: registration is\n"
     "        // once-per-process and bounded by service count.\n"
     (format "        adapters.append(~aServerAsyncAdapter(impl))\n" sname)
     (format "        Register~aServer(server, adapters.last!)\n    }\n\n" sname)
     (format "    private static var adapters: [~aServerAsyncAdapter] = []\n" sname)
     "    #endif\n")))

(define (emit-swift-file file-model params)
  (define base (path->string (path-replace-extension
                              (file-name-from-path (hash-ref file-model 'name)) "")))
  (define enum-name (string-append (pascal (string->symbol base)) "GrpcDc"))
  (cons (string-append (pascal (string->symbol base)) "GrpcDc.swift")
        (string-append
         "// @generated by protoc-gen-grpc-dc-swift (Racket metaprogram). DO NOT EDIT.\n"
         (format "// source: ~a\n\n" (hash-ref file-model 'name))
         "#if canImport(Foundation)\nimport Foundation\n#endif\n\n"
         (format "/// Generated gRPC-over-DataChannels stubs for ~a.\n" (hash-ref file-model 'name))
         (format "enum ~a {\n" enum-name)
         (apply string-append
                (map swift-service (hash-ref file-model 'services)))
         "}\n\n"
         "#if canImport(Foundation)\n"
         "/// Run an async operation to completion on a blocking thread.\n"
         "func RunBlocking<T>(_ body: @escaping () async throws -> T) throws -> T {\n"
         "    let semaphore = DispatchSemaphore(value: 0)\n"
         "    var result: Result<T, Error>!\n"
         "    Task.detached {\n"
         "        do {\n"
         "            result = .success(try await body())\n"
         "        } catch {\n"
         "            result = .failure(error)\n"
         "        }\n"
         "        semaphore.signal()\n"
         "    }\n"
         "    semaphore.wait()\n"
         "    return try result.get()\n"
         "}\n"
         "#endif\n")))
