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
     "    #endif\n\n"
     (apply string-append (map swift-stream-impl methods))
     "    #if canImport(Foundation)\n"
     (format "    private final class ~aServerAsyncAdapter: ~aServer {\n" sname sname)
     (format "        private let impl: ~aServerAsync\n" sname)
     (format "        init(_ impl: ~aServerAsync) { self.impl = impl }\n" sname)
     (apply string-append (map swift-server-async-adapter-method methods))
     "    }\n\n"
     "    #endif\n\n"
     (format "    /// Register an implementation of ~a on a Server.\n" (hash-ref svc 'full-name))

     (format "    static func Register~aServer(_ server: Server, _ impl: ~aServer) {\n" sname sname)
     (format "        server.RegisterService(Server.ServiceDesc(name: ~s, methods: [\n"
             (hash-ref svc 'full-name))
     (apply string-append (map swift-register-method (append methods (alias-server-methods svc))))
     "        ]))\n    }\n\n"
     "    #if canImport(Foundation)\n"
     (format "    /// Register an async implementation of ~a on a Server.\n" (hash-ref svc 'full-name))
     (format "    static func Register~aServerAsync(_ server: Server, _ impl: ~aServerAsync) {\n" sname sname)
     "        // Adapters are retained for the process lifetime: registration is\n"
     "        // once-per-process and bounded by service count.\n"
     (format "        adapters.append(~aServerAsyncAdapter(impl))\n" sname)
     (format "        Register~aServer(server, adapters.last!)\n    }\n\n" sname)
     (format "    private static var adapters: [~aServerAsyncAdapter] = []\n" sname)
     "    #endif\n")))

;; ---------------------------------------------------------------------------
;; Swift message types (<Base>Messages.swift): final classes
;; implementing Marshaler/Unmarshaler plus a <Base>Pb wire-support
;; enum per proto file. Dependency-free (Foundation only). Mirrors
;; the Java emitter on the shared desc.rkt model.
;; ---------------------------------------------------------------------------

(define swift-pb-varint-types '(5 3 13 4 17 18 8 14))
(define swift-pb-fixed '((2 4 "Float") (1 8 "Double") (7 4 "UInt32") (15 4 "Int32") (6 8 "UInt64") (16 8 "Int64")))

(define (swift-pb-camel s)
  (define parts (string-split s "_"))
  (if (null? parts)
      s
      (apply string-append (car parts)
             (map (lambda (p) (if (string=? p "") "" (string-append (string (char-upcase (string-ref p 0))) (substring p 1))))
                  (cdr parts)))))

(define (swift-pb-field-name f)
  (define jn (hash-ref f 'json-name ""))
  (if (and jn (not (string=? jn ""))) jn (swift-pb-camel (hash-ref f 'name))))

(define (swift-pb-resolve model type-name)
  (hash-ref (hash-ref model 'types) type-name
            (lambda () (error 'emit-swift-pb-file "unresolved type ~a" type-name))))

(define (swift-pb-rel pkg full)
  (define rel (if (and pkg (not (string=? pkg "")) (string-prefix? full (string-append pkg ".")))
                  (substring full (add1 (string-length pkg)))
                  full))
  (string-join (string-split rel ".") "."))

(define (swift-pb-entry-ref model entry)
  (swift-pb-rel (hash-ref entry 'pkg)
                (if (eq? (hash-ref entry 'kind) 'enum)
                    (let ([e (hash-ref entry 'enum)])
                      (if (hash-ref entry 'msg)
                          (format "~a.~a" (hash-ref (hash-ref entry 'msg) 'full-name) (hash-ref e 'name))
                          (format "~a.~a" (hash-ref entry 'pkg) (hash-ref e 'name))))
                    (hash-ref (hash-ref entry 'msg) 'full-name))))

(define (swift-pb-scalar f)
  (case (hash-ref f 'type)
    [(1) '("Double" "0")] [(2) '("Float" "0")] [(3) '("Int64" "0")] [(4) '("UInt64" "0")]
    [(5) '("Int32" "0")] [(6) '("UInt64" "0")] [(7) '("UInt32" "0")] [(8) '("Bool" "false")]
    [(9) '("String" "\"\"")] [(12) '("[UInt8]" "[]")] [(13) '("UInt32" "0")]
    [(15) '("Int32" "0")] [(16) '("Int64" "0")] [(17) '("Int32" "0")] [(18) '("Int64" "0")]
    [else #f]))

(define (swift-pb-type model f)
  (define type (hash-ref f 'type))
  (define singular
    (cond [(= type 11)
           (define entry (swift-pb-resolve model (hash-ref f 'type-name)))
           (if (eq? (hash-ref entry 'kind) 'map)
               (let* ([em (hash-ref entry 'msg)]
                      [kf (findf (lambda (x) (= (hash-ref x 'number) 1)) (hash-ref em 'fields))]
                      [vf (findf (lambda (x) (= (hash-ref x 'number) 2)) (hash-ref em 'fields))])
                 (format "[~a: ~a]" (swift-pb-type model (hash-set kf 'label 1))
                         (if (= (hash-ref vf 'type) 11)
                             (swift-pb-entry-ref model (swift-pb-resolve model (hash-ref vf 'type-name)))
                             (swift-pb-type model (hash-set vf 'label 1)))))
               (format "~a?" (swift-pb-entry-ref model entry)))]
          [(= type 14) (swift-pb-entry-ref model (swift-pb-resolve model (hash-ref f 'type-name)))]
          [else (first (swift-pb-scalar f))]))
  (cond [(and (= type 11)
              (eq? (hash-ref (swift-pb-resolve model (hash-ref f 'type-name)) 'kind) 'map))
         singular]
        [(= (hash-ref f 'label) 3)
         (format "[~a]" (if (= type 11)
                            (swift-pb-entry-ref model (swift-pb-resolve model (hash-ref f 'type-name)))
                            (swift-pb-type model (hash-set f 'label 1))))]
        [else singular]))

(define (swift-pb-explicit-literal model f)
  (define d (field-explicit-default f))
  (and d
       (case (hash-ref f 'type)
         [(9) (format "~s" d)]
         [(8) d]
         [(14) (format "~a.~a" (swift-pb-entry-ref model (swift-pb-resolve model (hash-ref f 'type-name))) d)]
         [(2) (format "~a" d)]
         [else d])))

(define (swift-pb-default model f)
  (cond [(swift-pb-explicit-literal model f) => (lambda (lit) lit)]
        [(and (= (hash-ref f 'type) 11)
              (eq? (hash-ref (swift-pb-resolve model (hash-ref f 'type-name)) 'kind) 'map))
         "[:]"]
        [(= (hash-ref f 'label) 3) "[]"]
        [(= (hash-ref f 'type) 11) "nil"]
        [(= (hash-ref f 'type) 14)
         (define entry (swift-pb-resolve model (hash-ref f 'type-name)))
         (format "~a.~a" (swift-pb-entry-ref model entry) (hash-ref (car (hash-ref (hash-ref entry 'enum) 'values)) 'name))]
        [else (second (swift-pb-scalar f))]))

(define (swift-pb-varint-expr f v)
  (case (hash-ref f 'type)
    [(8) (format "(~a ? Int64(1) : Int64(0))" v)]
    [(17) (format "UInt64(UInt32(bitPattern: (~a << 1) ^ (~a >> 31)))" v v)]
    [(18) (format "UInt64(bitPattern: (~a << 1) ^ (~a >> 63))" v v)]
    [(14) (format "Int64(~a.rawValue)" v)]
    [(5) (format "Int64(~a)" v)]
    [(13 7) (format "UInt64(~a)" v)]
    [(3) (format "UInt64(bitPattern: ~a)" v)]
    [else v]))

(define (swift-pb-varint-decode f v)
  (case (hash-ref f 'type)
    [(5) (format "Int32(truncatingIfNeeded: ~a)" v)]
    [(13 7) (format "UInt32(truncatingIfNeeded: ~a)" v)]
    [(3) (format "Int64(bitPattern: ~a)" v)]
    [(4 6) v]
    [(8) (format "~a != 0" v)]
    [(17) (format "Int32(bitPattern: UInt32(truncatingIfNeeded: (~a >> 1) ^ UInt64(bitPattern: -Int64(bitPattern: ~a & 1))))" v v)]
    [(18) (format "Int64(bitPattern: (~a >> 1) ^ UInt64(bitPattern: -Int64(bitPattern: ~a & 1)))" v v)]))

(define (swift-pb-nonzero f v)
  (case (hash-ref f 'type)
    [(8) v]
    [(14) (format "~a.rawValue != 0" v)]
    [else (format "~a != 0" v)]))

(define (swift-pb-encode-singular model f v indent)
  (define n (hash-ref f 'number))
  (define type (hash-ref f 'type))
  ;; Proto2 optional/required fields have explicit presence.
  (define proto2? (equal? (hash-ref model 'syntax "") "proto2"))
  (cond [(memv type swift-pb-varint-types)
         (if proto2?
             (format "~a{ w.Tag(~a, 0); w.Varint(~a) }\n" indent n (swift-pb-varint-expr f v))
             (format "~aif ~a { w.Tag(~a, 0); w.Varint(~a) }\n" indent (swift-pb-nonzero f v) n (swift-pb-varint-expr f v)))]
        [(assv type swift-pb-fixed)
         => (lambda (info)
              (if proto2?
                  (format "~a{ w.Tag(~a, ~a); w.Fixed~a(~a) }\n" indent n
                          (if (= (second info) 8) 1 5) (third info) v)
                  (format "~aif ~a { w.Tag(~a, ~a); w.Fixed~a(~a) }\n" indent (swift-pb-nonzero f v) n
                          (if (= (second info) 8) 1 5) (third info) v)))]
        [(= type 9)
         (if proto2?
             (format "~aw.BytesField(~a, [UInt8](~a.utf8))\n" indent n v)
             (format "~aw.StringField(~a, ~a)\n" indent n v))]
        [(= type 12)
         (if proto2?
             (format "~aw.BytesField(~a, ~a)\n" indent n v)
             (format "~aif !~a.isEmpty { w.BytesField(~a, ~a) }\n" indent v n v))]
        [(= type 11) (format "~aif let v = ~a { w.BytesField(~a, v.MarshalDc()) }\n" indent v n)]
        [else (error 'emit-swift-pb-file "unsupported field type ~a (groups)" type)]))

(define (swift-pb-set-expr sib)
  (define v (swift-pb-field-name sib))
  (case (hash-ref sib 'type)
    [(11 10) (format "~a != nil" v)]
    [(9 12) (format "!~a.isEmpty" v)]
    [else (swift-pb-nonzero sib v)]))

;; Encode-side oneof clearing: suppress f when a later sibling is
;; set, so only the winning member is written.
(define (swift-pb-encode-guard model f code)
  (define later (oneof-later-siblings model f))
  (if (null? later)
      code
      (format "        if !(~a) {\n~a        }\n"
              (string-join (map swift-pb-set-expr later) " || ")
              (if (string-suffix? code "\n") code (string-append code "\n")))))

(define (swift-pb-encode-field model f support)
  (define v (swift-pb-field-name f))
  (define n (hash-ref f 'number))
  (define type (hash-ref f 'type))
  (cond [(and (= type 11)
              (eq? (hash-ref (swift-pb-resolve model (hash-ref f 'type-name)) 'kind) 'map))
         (define entry (swift-pb-resolve model (hash-ref f 'type-name)))
         (define helper (format "~a.~aEncode" support (swift-pb-map-helper-name model entry)))
         (format "        for (k, val) in ~a { w.BytesField(~a, ~a(k, val)) }\n" v n helper)]
        [(not (= (hash-ref f 'label) 3)) (swift-pb-encode-singular model f v "        ")]
        [(memv type swift-pb-varint-types)
         (string-append
          (format "        if !~a.isEmpty {\n" v)
          (format "            let payload = ~a.Writer()\n" support)
          (format "            for x in ~a { payload.Varint(~a) }\n" v (swift-pb-varint-expr f "x"))
          (format "            w.BytesField(~a, payload.ToBytes())\n        }\n" n))]
        [(assv type swift-pb-fixed)
         => (lambda (info)
              (string-append
               (format "        if !~a.isEmpty {\n" v)
               (format "            let payload = ~a.Writer()\n" support)
               (format "            for x in ~a { payload.Fixed~a(x) }\n" v (third info))
               (format "            w.BytesField(~a, payload.ToBytes())\n        }\n" n)))]
        [(= type 9) (format "        for x in ~a { w.BytesField(~a, [UInt8](x.utf8)) }\n" v n)]
        [(= type 12) (format "        for x in ~a { w.BytesField(~a, x) }\n" v n)]
        [(= type 11) (format "        for x in ~a { w.BytesField(~a, x.MarshalDc()) }\n" v n)]
        [else (error 'emit-swift-pb-file "unsupported repeated field type ~a" type)]))

(define (swift-pb-decode-singular model f target src indent)
  (define type (hash-ref f 'type))
  (cond [(memv type swift-pb-varint-types)
         (format "~a~a = ~a\n" indent target
                 (if (= type 14)
                     (format "~a(rawValue: ~a) ?? ~a" (swift-pb-entry-ref model (swift-pb-resolve model (hash-ref f 'type-name)))
                             (swift-pb-varint-decode (hash-set f 'type 5) src)
                             (swift-pb-default model f))
                     (swift-pb-varint-decode f src)))]
        [(assv type swift-pb-fixed)
         => (lambda (info)
              (format "~a~a = ~a\n" indent target
                      (case (hash-ref f 'type)
                        [(2) (format "~a.BitsToFloat(UInt32(truncatingIfNeeded: ~a))" "SUPPORT" src)]
                        [(1) (format "~a.BitsToDouble(~a)" "SUPPORT" src)]
                        [(7) (format "UInt32(truncatingIfNeeded: ~a)" src)]
                        [(15) (format "Int32(truncatingIfNeeded: ~a)" src)]
                        [(16) (format "Int64(bitPattern: ~a)" src)]
                        [else src])))]
        [(= type 9) (format "~a~a = String(decoding: ~a, as: UTF8.self)\n" indent target src)]
        [(= type 12) (format "~a~a = ~a\n" indent target src)]
        [(= type 11)
         (define ref (swift-pb-entry-ref model (swift-pb-resolve model (hash-ref f 'type-name))))
         (string-append
          (format "~a~a = ~a()\n" indent target ref)
          (format "~a~a!.UnmarshalDc(~a)\n" indent target src))]
        [else (error 'emit-swift-pb-file "unsupported field type ~a" type)]))

(define (swift-pb-oneof-clearing model f)
  (apply string-append
         (map (lambda (sib)
                (format "                ~a = ~a\n" (swift-pb-field-name sib) (swift-pb-default model sib)))
              (oneof-siblings model f))))

(define (swift-pb-decode-case model f support)
  (define v (swift-pb-field-name f))
  (define type (hash-ref f 'type))
  (define head (format "            case ~a:\n" (hash-ref f 'number)))
  (define clearing (swift-pb-oneof-clearing model f))
  (cond [(and (= type 11)
              (eq? (hash-ref (swift-pb-resolve model (hash-ref f 'type-name)) 'kind) 'map))
         (define entry (swift-pb-resolve model (hash-ref f 'type-name)))
         (define helper (format "~a.~aDecode" support (swift-pb-map-helper-name model entry)))
         (string-append head
                        (format "                let kv = ~a(field.bytesValue)\n" helper)
                        (format "                ~a[kv.0] = kv.1\n" v))]
        [(not (= (hash-ref f 'label) 3))
         (string-append head
                        clearing
                        (swift-pb-decode-singular/support model f v
                                                          (cond [(memv type swift-pb-varint-types) "field.varintValue"]
                                                                [(assv type swift-pb-fixed) "field.fixedValue"]
                                                                [else "field.bytesValue"])
                                                          "                " support))]
        [(memv type swift-pb-varint-types)
         (string-append head
                        "                if field.wire == 2 {\n"
                        (format "                    let sub = ~a.Reader(field.bytesValue)\n" support)
                        "                    while !sub.Done() {\n"
                        (format "                        ~a.append(~a)\n" v
                                (let ([conv (swift-pb-varint-decode f "sub.Varint()")])
                                  (if (= type 14)
                                      (format "~a(rawValue: ~a) ?? ~a" (swift-pb-entry-ref model (swift-pb-resolve model (hash-ref f 'type-name))) (swift-pb-varint-decode (hash-set f 'type 5) "sub.Varint()") (swift-pb-default model f))
                                      conv)))
                        "                    }\n                } else {\n"
                        (format "                    ~a.append(~a)\n" v
                                (let ([conv (swift-pb-varint-decode f "field.varintValue")])
                                  (if (= type 14)
                                      (format "~a(rawValue: ~a) ?? ~a" (swift-pb-entry-ref model (swift-pb-resolve model (hash-ref f 'type-name))) (swift-pb-varint-decode (hash-set f 'type 5) "field.varintValue") (swift-pb-default model f))
                                      conv)))
                        "                }\n")]
        [(assv type swift-pb-fixed)
         => (lambda (info)
              (string-append head
                             "                if field.wire == 2 {\n"
                             (format "                    let sub = ~a.Reader(field.bytesValue)\n" support)
                             (format "                    while !sub.Done() { ~a.append(~a) }\n" v
                                     (case (hash-ref f 'type)
                                       [(2) (format "~a.BitsToFloat(sub.Fixed32())" support)]
                                       [(1) (format "~a.BitsToDouble(sub.Fixed64())" support)]
                                       [(7) "sub.Fixed32()"]
                                       [(15) "Int32(bitPattern: sub.Fixed32())"]
                                       [else "sub.Fixed64()"]))
                             "                } else {\n"
                             (format "                    ~a.append(~a)\n" v
                                     (case (hash-ref f 'type)
                                       [(2) (format "~a.BitsToFloat(UInt32(truncatingIfNeeded: field.fixedValue))" support)]
                                       [(1) (format "~a.BitsToDouble(field.fixedValue)" support)]
                                       [(7) "UInt32(truncatingIfNeeded: field.fixedValue)"]
                                       [(15) "Int32(truncatingIfNeeded: field.fixedValue)"]
                                       [else "field.fixedValue"]))
                             "                }\n"))]
        [(= type 9) (string-append head (format "                ~a.append(String(decoding: field.bytesValue, as: UTF8.self))\n" v))]
        [(= type 12) (string-append head (format "                ~a.append(field.bytesValue)\n" v))]
        [(= type 11)
         (string-append head
                        (format "                let item = ~a()\n" (swift-pb-entry-ref model (swift-pb-resolve model (hash-ref f 'type-name))))
                        "                item.UnmarshalDc(field.bytesValue)\n"
                        (format "                ~a.append(item)\n" v))]
        [else (error 'emit-swift-pb-file "unsupported repeated field type ~a" type)]))

(define (swift-pb-decode-singular/support model f target src indent support)
  (define s (swift-pb-decode-singular model f target src indent))
  (string-replace s "SUPPORT" support))

(define (swift-pb-map-helper-name model entry)
  (define rel (swift-pb-rel (hash-ref entry 'pkg) (hash-ref (hash-ref entry 'msg) 'full-name)))
  (string-join (string-split rel ".") ""))

(define (swift-pb-map-helpers model entry support)
  (define msg (hash-ref entry 'msg))
  (define base (swift-pb-map-helper-name model entry))
  (define key-f (findf (lambda (x) (= (hash-ref x 'number) 1)) (hash-ref msg 'fields)))
  (define val-f (findf (lambda (x) (= (hash-ref x 'number) 2)) (hash-ref msg 'fields)))
  (unless (and key-f val-f) (error 'emit-swift-pb-file "map entry ~a lacks key/value" (hash-ref msg 'full-name)))
  (define kt (swift-pb-type model (hash-set key-f 'label 1)))
  (define vt (swift-pb-type model (hash-set val-f 'label 1)))
  (define vt-plain (if (and (= (hash-ref val-f 'type) 11)
                            (not (eq? (hash-ref (swift-pb-resolve model (hash-ref val-f 'type-name)) 'kind) 'map)))
                       (swift-pb-entry-ref model (swift-pb-resolve model (hash-ref val-f 'type-name)))
                       vt))
  (string-append
   (format "    static func ~aEncode(_ key: ~a, _ value: ~a) -> [UInt8] {\n" base kt vt-plain)
   "        let w = Writer()\n"
   (swift-pb-encode-singular model (hash-set key-f 'label 1) "key" "        ")
   (if (= (hash-ref val-f 'type) 11)
       (format "        w.BytesField(~a, value.MarshalDc())\n" (hash-ref val-f 'number))
       (swift-pb-encode-singular model (hash-set val-f 'label 1) "value" "        "))
   "        return w.ToBytes()\n    }\n\n"
   (format "    static func ~aDecode(_ bytes: [UInt8]) -> (~a, ~a) {\n" base kt vt-plain)
   (format "        var key: ~a = ~a\n" kt (swift-pb-default model (hash-set key-f 'label 1)))
   (format "        var value: ~a = ~a\n" vt-plain (if (= (hash-ref val-f 'type) 11) (format "~a()" vt-plain) (swift-pb-default model (hash-set val-f 'label 1))))
   "        let r = Reader(bytes)\n        while true {\n            let next: Field?\n            do { next = try r.Next() } catch { break }\n            guard let field = next else { break }\n            switch field.number {\n"
   (format "            case ~a: ~a\n" (hash-ref key-f 'number)
           (string-trim (swift-pb-decode-singular/support model (hash-set key-f 'label 1) "key"
                                                          (cond [(memv (hash-ref key-f 'type) swift-pb-varint-types) "field.varintValue"]
                                                                [(assv (hash-ref key-f 'type) swift-pb-fixed) "field.fixedValue"]
                                                                [else "field.bytesValue"]) "" support) "\n" #:left? #f #:repeat? #t))
   (format "            case ~a: ~a\n" (hash-ref val-f 'number)
           (if (= (hash-ref val-f 'type) 11)
               "value.UnmarshalDc(field.bytesValue)"
               (string-trim (swift-pb-decode-singular/support model (hash-set val-f 'label 1) "value"
                                                              (cond [(memv (hash-ref val-f 'type) swift-pb-varint-types) "field.varintValue"]
                                                                    [(assv (hash-ref val-f 'type) swift-pb-fixed) "field.fixedValue"]
                                                                    [else "field.bytesValue"]) "" support) "\n" #:left? #f #:repeat? #t)))
   "            default: break\n            }\n        }\n        return (key, value)\n    }\n\n"))

(define (swift-pb-support base helpers)
  (string-append
   "// @generated by protoc-gen-grpc-dc-swift (Racket metaprogram). DO NOT EDIT.\n"
   "#if canImport(Foundation)\nimport Foundation\n#endif\n\n"
   (format "enum ~aPb {\n" (pascal (string->symbol base)))
   "    struct BadWireType: Error {}\n"
   "    final class Writer {\n"
   "        private var out: [UInt8] = []\n"
   "        func Varint(_ value: UInt64) { var v = value; while v > 0x7f { out.append(UInt8((v & 0x7f) | 0x80)); v >>= 7 }; out.append(UInt8(v)) }\n"
   "        func Varint(_ value: Int64) { Varint(UInt64(bitPattern: value)) }\n"
   "        func Tag(_ field: Int, _ wire: Int) { Varint(UInt64((field << 3) | wire)) }\n"
   "        func BytesField(_ field: Int, _ payload: [UInt8]) { Tag(field, 2); Varint(UInt64(payload.count)); out += payload }\n"
   "        func StringField(_ field: Int, _ value: String) { if value.isEmpty { return }; BytesField(field, [UInt8](value.utf8)) }\n"
   "        func FixedInt32(_ value: Int32) { FixedUInt32(UInt32(bitPattern: value)) }\n"
   "        func FixedUInt32(_ value: UInt32) { for i in 0..<4 { out.append(UInt8((value >> (8 * i)) & 0xff)) } }\n"
   "        func FixedInt64(_ value: Int64) { FixedUInt64(UInt64(bitPattern: value)) }\n"
   "        func FixedUInt64(_ value: UInt64) { for i in 0..<8 { out.append(UInt8((value >> (8 * i)) & 0xff)) } }\n"
   "        func FixedFloat(_ value: Float) { FixedUInt32(value.bitPattern) }\n"
   "        func FixedDouble(_ value: Double) { FixedUInt64(value.bitPattern) }\n"
   "        func Raw(_ payload: [UInt8]) { out += payload }\n"
   "        func ToBytes() -> [UInt8] { out }\n"
   "    }\n\n"
   "    static func BitsToFloat(_ u: UInt32) -> Float { Float(bitPattern: u) }\n"
   "    static func BitsToDouble(_ u: UInt64) -> Double { Double(bitPattern: u) }\n\n"
   "    struct Field {\n"
   "        var number: Int; var wire: Int; var varintValue: UInt64; var bytesValue: [UInt8]; var fixedValue: UInt64; var rawValue: [UInt8]\n"
   "    }\n\n"
   "    final class Reader {\n"
   "        private let buf: [UInt8]; private var pos = 0\n"
   "        init(_ buf: [UInt8]) { self.buf = buf }\n"
   "        func Done() -> Bool { pos >= buf.count }\n"
   "        func Varint() -> UInt64 { var result: UInt64 = 0; var shift: UInt64 = 0; while true { precondition(pos < buf.count, \"truncated varint\"); let b = buf[pos]; pos += 1; result |= UInt64(b & 0x7f) << shift; if (b & 0x80) == 0 { return result }; shift += 7; precondition(shift < 64, \"varint too long\") } }\n"
   "        func Take(_ n: Int) -> [UInt8] { precondition(pos + n <= buf.count, \"truncated field\"); let v = [UInt8](buf[pos..<(pos + n)]); pos += n; return v }\n"
   "        func Fixed32() -> UInt32 { let b = Take(4); return UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24) }\n"
   "        func Fixed64() -> UInt64 { let b = Take(8); var v: UInt64 = 0; for i in 0..<8 { v |= UInt64(b[i]) << (8 * i) }; return v }\n"
   "        func Next() throws -> Field? {\n"
   "            if pos >= buf.count { return nil }\n"
   "            let start = pos\n"
   "            let tag = Varint(); let number = Int(tag >> 3); let wire = Int(tag & 7)\n"
   "            switch wire {\n"
   "            case 0: let v = Varint(); return Field(number: number, wire: wire, varintValue: v, bytesValue: [], fixedValue: 0, rawValue: [UInt8](buf[start..<pos]))\n"
   "            case 2: let n = Int(Varint()); let b = Take(n); return Field(number: number, wire: wire, varintValue: 0, bytesValue: b, fixedValue: 0, rawValue: [UInt8](buf[start..<pos]))\n"
   "            case 1: let b = Take(8); var v: UInt64 = 0; for i in 0..<8 { v |= UInt64(b[i]) << (8 * i) }; return Field(number: number, wire: wire, varintValue: 0, bytesValue: b, fixedValue: v, rawValue: [UInt8](buf[start..<pos]))\n"
   "            case 5: let b = Take(4); let v = UInt64(UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)); return Field(number: number, wire: wire, varintValue: 0, bytesValue: b, fixedValue: v, rawValue: [UInt8](buf[start..<pos]))\n"
   "            default: throw BadWireType()\n"
   "            }\n"
   "        }\n"
   "    }\n\n"
   helpers
   "}\n\n"))

(define (swift-pb-message-class model msg support indent decl)
  (define name (hash-ref msg 'name))
  (define fields (hash-ref msg 'fields))
  (string-append
   (format "~a~a class ~a: Marshaler, Unmarshaler {\n" indent decl name)
   (apply string-append
          (map (lambda (f)
                 (format "~a    var ~a: ~a = ~a\n" indent (swift-pb-field-name f) (swift-pb-type model f) (swift-pb-default model f)))
               fields))
   (format "~a    var unknownFields: [UInt8] = []\n" indent)
   (format "~a    init() {}\n" indent)
   (if (null? fields)
       ""
       (string-append
        (format "~a    init(~a) {\n" indent
                (string-join (map (lambda (f) (format "_ ~a: ~a = ~a" (swift-pb-field-name f) (swift-pb-type model f) (swift-pb-default model f))) fields) ", "))
        (apply string-append
               (map (lambda (f) (format "~a        self.~a = ~a\n" indent (swift-pb-field-name f) (swift-pb-field-name f))) fields))
        (format "~a    }\n" indent)))
   (format "~a    func MarshalDc() -> [UInt8] {\n" indent)
   (format "~a        let w = ~a.Writer()\n" indent support)
   (apply string-append (map (lambda (f) (swift-pb-encode-guard model f (swift-pb-encode-field model f support))) fields))
   (format "~a        w.Raw(unknownFields)\n" indent)
   (format "~a        return w.ToBytes()\n~a    }\n" indent indent)
   (format "~a    func UnmarshalDc(_ data: [UInt8]) {\n" indent)
   (format "~a        unknownFields = []\n" indent)
   (apply string-append
          (map (lambda (f) (format "~a        ~a = ~a\n" indent (swift-pb-field-name f) (swift-pb-default model f))) fields))
   (format "~a        let r = ~a.Reader(data)\n" indent support)
   (format "~a        while true {\n" indent)
   (format "~a            let next: ~a.Field?\n" indent support)
   (format "~a            do { next = try r.Next() } catch { break }\n" indent)
   (format "~a            guard let field = next else { break }\n" indent)
   (format "~a            switch field.number {\n" indent)
   (apply string-append (map (lambda (f) (swift-pb-decode-case model f support)) fields))
   (format "~a            default: unknownFields += field.rawValue\n~a            }\n~a        }\n~a    }\n" indent indent indent indent)
   (apply string-append (map (lambda (n) (swift-pb-message-class model n support (string-append indent "    ") "final")) (hash-ref msg 'nested)))
   (apply string-append (map (lambda (e) (swift-pb-nested-enum e (string-append indent "    "))) (hash-ref msg 'enums)))
   (format "~a}\n" indent)))

(define (swift-pb-nested-enum e indent)
  (string-append
   (format "~aenum ~a: Int32 {\n" indent (hash-ref e 'name))
   (string-join (map (lambda (v) (format "~a    case ~a = ~a" indent (hash-ref v 'name) (hash-ref v 'number)))
                     (hash-ref e 'values)) "\n")
   (format "\n~a}\n" indent)))

(define (emit-swift-pb-file file-model)
  (and (hash-has-key? file-model 'messages)
       (hash-has-key? file-model 'types)
       (emit-swift-pb-file/inner file-model)))

(define (emit-swift-pb-file/inner file-model)
  (define messages (hash-ref file-model 'messages))
  (define enums (hash-ref file-model 'enums))
  (and (or (pair? messages) (pair? enums))
       (let ()
         (define base (path->string (path-replace-extension
                                     (file-name-from-path (hash-ref file-model 'name)) "")))
         (define support (format "~aPb" (pascal (string->symbol base))))
         (define seen-maps (mutable-set))
         (define helpers '())
         (define (collect msg)
           (for ([f (in-list (hash-ref msg 'fields))])
             (when (= (hash-ref f 'type) 11)
               (define e (swift-pb-resolve file-model (hash-ref f 'type-name)))
               (when (and (eq? (hash-ref e 'kind) 'map)
                          (not (set-member? seen-maps (hash-ref (hash-ref e 'msg) 'full-name))))
                 (set-add! seen-maps (hash-ref (hash-ref e 'msg) 'full-name))
                 (set! helpers (cons (swift-pb-map-helpers file-model e support) helpers)))))
           (for ([n (in-list (hash-ref msg 'nested))]) (collect n)))
         (for ([m (in-list messages)]) (collect m))
         (define content
           (string-append
            (swift-pb-support base (apply string-append (reverse helpers)))
            (apply string-append
                   (map (lambda (e)
                          (string-append
                           (format "enum ~a: Int32 {\n" (hash-ref e 'name))
                           (string-join (map (lambda (v) (format "    case ~a = ~a" (hash-ref v 'name) (hash-ref v 'number)))
                                             (hash-ref e 'values)) "\n")
                           "\n}\n\n"))
                        enums))
            (apply string-append
                   (map (lambda (m) (swift-pb-message-class file-model m support "" "final"))
                        (filter (lambda (m) (not (hash-ref m 'map-entry))) messages)))))
         (cons (string-append (pascal (string->symbol base)) "Messages.swift") content))))

(define (emit-swift-file file-model params)
  (define base (path->string (path-replace-extension
                              (file-name-from-path (hash-ref file-model 'name)) "")))
  (define enum-name (string-append (pascal (string->symbol base)) "GrpcDc"))
  (define stub
    (cons (string-append (pascal (string->symbol base)) "GrpcDc.swift")
          (string-append
           "// @generated by protoc-gen-grpc-dc-swift (Racket metaprogram). DO NOT EDIT.\n"
         (format "// source: ~a\n\n" (hash-ref file-model 'name))
         "#if canImport(Foundation)\nimport Foundation\n#endif\n\n"
         (format "/// Generated gRPC-over-DataChannels stubs for ~a.\n" (hash-ref file-model 'name))
         (format "enum ~a {\n" enum-name)
         ;; trace=hooks: delegate the tracer registrar to Tracing.
         (if (equal? (hash-ref params 'trace #f) "hooks")
             (string-append
              "    // Tracing (trace=hooks): register an observer via SetTracer.\n"
              "    static func SetTracer(_ t: Tracer?) { Tracing.SetTracer(t) }\n"
              "    static func SetTraceFilter(_ patterns: String) { Tracing.SetTraceFilter(patterns) }\n"
              (let ([methods (hash-ref params 'trace_methods #f)])
                (if methods
                    (format "    static let _traceFilterApplied: Bool = { Tracing.SetTraceFilter(~s); return true }()\n" methods)
                    ""))
              "\n")
             "")
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
  (define pb-file (emit-swift-pb-file file-model))
  (if pb-file (list stub pb-file) stub))
