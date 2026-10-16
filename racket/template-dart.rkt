#lang racket

;;; template-dart.rkt — emitter body spliced into
;;; protoc-gen-grpc-dc-dart.
;;;
;;; Generated code is beside hand-written message types implementing
;;; Marshaler / Unmarshaler. Method names keep the proto spelling,
;;; mirroring the other language stubs. Dart async is native
;;; (Future/Stream), so there is no separate async surface: every
;;; method already returns Future / exposes Stream.

(require "spec.rkt" "desc.rkt")
(provide emit-dart-file)

(define current-service (make-parameter ""))

(define (pascal sym) ; echo_service -> EchoService ; echo -> Echo
  (apply string-append
         (for/list ([part (in-list (string-split (symbol->string sym) "[_.-]"))])
           (if (string=? part "")
               ""
               (string-append (string (char-upcase (string-ref part 0)))
                              (substring part 1))))))

(define (lower-first s)
  (if (string=? s "")
      s
      (string-append (string (char-downcase (string-ref s 0))) (substring s 1))))

(define (dart-deprecated m indent)
  (if (hash-ref m 'deprecated #f)
      (format "~a@Deprecated('deprecated in the proto schema')\n" indent)
      ""))

(define (dart-client-method/raw m)
  (define name (lower-first (hash-ref m 'name)))
  (define orig-name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define path (hash-ref m 'path))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(unary)
     (format (string-append
              "  Future<~a> ~a(~a req,\n"
              "      {Map<String, String>? metadata, Duration? timeout}) async {\n"
              "    final resp = ~a();\n"
              "    await _channel.unary(~s, req, resp, metadata: metadata, timeout: timeout);\n"
              "    return resp;\n"
              "  }\n\n")
             resp name req resp path)]
    [(server-streaming)
     (format (string-append
              "  Future<~a~aStream> ~a(~a req,\n"
              "      {Map<String, String>? metadata, Duration? timeout}) async {\n"
              "    return ~a~aStream(\n"
              "        await _channel.serverStream(~s, req,\n"
              "            metadata: metadata, timeout: timeout));\n"
              "  }\n\n")
             svc orig-name name req svc orig-name path)]
    [(client-streaming)
     (format (string-append
              "  Future<~a> ~a(List<~a> reqs,\n"
              "      {Map<String, String>? metadata, Duration? timeout}) async {\n"
              "    final resp = ~a();\n"
              "    await _channel.clientStreamCall(~s, reqs, resp,\n"
              "        metadata: metadata, timeout: timeout);\n"
              "    return resp;\n"
              "  }\n\n")
             resp name req resp path)]
    [(bidi)
     (format (string-append
              "  Future<~a~aStream> ~a(List<~a> reqs,\n"
              "      {Map<String, String>? metadata, Duration? timeout}) async {\n"
              "    return ~a~aStream(\n"
              "        await _channel.bidi(~s, reqs, metadata: metadata, timeout: timeout));\n"
              "  }\n\n")
             svc orig-name name req svc orig-name path)]))

(define (dart-client-method m)
  (string-append (dart-deprecated m "  ") (dart-client-method/raw m)))

(define (dart-client-stream-class m)
  (define orig-name (hash-ref m 'name))
  (define resp (hash-ref m 'output))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(server-streaming bidi)
     (format (string-append
              "/// Receiving stream for ~a/~a responses.\n"
              "class ~a~aStream {\n"
              "  final ClientStream _stream;\n\n"
              "  ~a~aStream(this._stream);\n\n"
              "  Future<~a> recv() async {\n"
              "    final resp = ~a();\n"
              "    await _stream.recv(resp);\n"
              "    return resp;\n"
              "  }\n\n"
              "  /// Responses as a Dart Stream (native async surface).\n"
              "  Stream<~a> get responses async* {\n"
              "    while (true) {\n"
              "      try {\n"
              "        yield await recv();\n"
              "      } on EndOfStreamError {\n"
              "        return;\n"
              "      }\n"
              "    }\n"
              "  }\n"
              "}\n\n")
             svc orig-name svc orig-name svc orig-name resp resp resp)]
    [else ""]))

(define (dart-server-stream-iface m)
  (define orig-name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(unary) ""]
    [(server-streaming)
     (format (string-append
              "/// Server-streaming sink passed to service implementations.\n"
              "abstract class ~a~aServer {\n"
              "  void send(~a resp);\n"
              "  CallContext get context;\n"
              "}\n\n")
             svc orig-name resp)]
    [(client-streaming)
     (format (string-append
              "/// Client-streaming stream passed to service implementations.\n"
              "abstract class ~a~aServer {\n"
              "  Future<~a> recv();\n"
              "  void sendAndClose(~a resp);\n"
              "  CallContext get context;\n"
              "}\n\n")
             svc orig-name req resp)]
    [(bidi)
     (format (string-append
              "/// Bidi stream passed to service implementations.\n"
              "abstract class ~a~aServer {\n"
              "  void send(~a resp);\n"
              "  Future<~a> recv();\n"
              "  CallContext get context;\n"
              "}\n\n")
             svc orig-name resp req)]))

(define (dart-server-iface-method/raw m)
  (define name (lower-first (hash-ref m 'name)))
  (define orig-name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(unary)
     (format "  Future<~a> ~a(CallContext ctx, ~a req);\n" resp name req)]
    [(server-streaming)
     (format "  Future<void> ~a(~a req, ~a~aServer stream);\n" name req svc orig-name)]
    [(client-streaming)
     (format "  Future<void> ~a(~a~aServer stream);\n" name svc orig-name)]
    [(bidi)
     (format "  Future<void> ~a(~a~aServer stream);\n" name svc orig-name)]))

(define (dart-server-iface-method m)
  (string-append (dart-deprecated m "  ") (dart-server-iface-method/raw m)))

(define (dart-stream-impl m)
  (define orig-name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(unary) ""]
    [(server-streaming)
     (format (string-append
              "class _~a~aServerImpl implements ~a~aServer {\n"
              "  @override\n"
              "  final CallContext context;\n"
              "  final ServerSink _sink;\n\n"
              "  _~a~aServerImpl(this.context, this._sink);\n\n"
              "  @override\n"
              "  void send(~a resp) {\n"
              "    _sink(resp.marshalDc());\n"
              "  }\n"
              "}\n\n")
             svc orig-name svc orig-name svc orig-name resp)]
    [(client-streaming)
     (format (string-append
              "class _~a~aServerImpl implements ~a~aServer {\n"
              "  @override\n"
              "  final CallContext context;\n"
              "  final RequestStream _reqs;\n"
              "  ~a? resp;\n\n"
              "  _~a~aServerImpl(this.context, this._reqs);\n\n"
              "  @override\n"
              "  Future<~a> recv() async {\n"
              "    final req = ~a();\n"
              "    await _reqs.recvInto(req);\n"
              "    return req;\n"
              "  }\n\n"
              "  @override\n"
              "  void sendAndClose(~a resp) {\n"
              "    this.resp = resp;\n"
              "  }\n"
              "}\n\n")
             svc orig-name svc orig-name resp svc orig-name req req resp)]
    [(bidi)
     (format (string-append
              "class _~a~aServerImpl implements ~a~aServer {\n"
              "  @override\n"
              "  final CallContext context;\n"
              "  final RequestStream _reqs;\n"
              "  final ServerSink _sink;\n\n"
              "  _~a~aServerImpl(this.context, this._reqs, this._sink);\n\n"
              "  @override\n"
              "  void send(~a resp) {\n"
              "    _sink(resp.marshalDc());\n"
              "  }\n\n"
              "  @override\n"
              "  Future<~a> recv() async {\n"
              "    final req = ~a();\n"
              "    await _reqs.recvInto(req);\n"
              "    return req;\n"
              "  }\n"
              "}\n\n")
             svc orig-name svc orig-name svc orig-name resp req req)]))

(define (dart-register-method m)
  (define name (hash-ref m 'name))
  (define impl-name (lower-first (method-impl-name m)))
  (define req (hash-ref m 'input))
  (define svc (current-service))
  (define kind-const
    (case (hash-ref m 'kind)
      [(unary) "kindUnary"]
      [(server-streaming) "kindServerStreaming"]
      [(client-streaming) "kindClientStreaming"]
      [(bidi) "kindBidi"]))
  (case (hash-ref m 'kind)
    [(unary)
     (format (string-append
              "      Method(~s, ~s, Server.~a,\n"
              "          (ctx, reqs, sink) async {\n"
              "        final req = ~a();\n"
              "        await reqs.recvInto(req);\n"
              "        sink((await impl.~a(ctx, req)).marshalDc());\n"
              "      }),\n")
             name (hash-ref m 'path) kind-const req impl-name)]
    [(server-streaming)
     (format (string-append
              "      Method(~s, ~s,\n"
              "          Server.~a, (ctx, reqs, sink) async {\n"
              "        final req = ~a();\n"
              "        await reqs.recvInto(req);\n"
              "        await impl.~a(req, _~a~aServerImpl(ctx, sink));\n"
              "      }),\n")
             name (hash-ref m 'path) kind-const req impl-name svc name)]
    [(client-streaming)
     (format (string-append
              "      Method(~s, ~s,\n"
              "          Server.~a, (ctx, reqs, sink) async {\n"
              "        final stream = _~a~aServerImpl(ctx, reqs);\n"
              "        await impl.~a(stream);\n"
              "        final resp = stream.resp;\n"
              "        if (resp == null) {\n"
              "          throw StatusException(Wire.codeInternal,\n"
              "              'client-streaming handler never called sendAndClose');\n"
              "        }\n"
              "        sink(resp.marshalDc());\n"
              "      }),\n")
             name (hash-ref m 'path) kind-const svc name impl-name)]
    [(bidi)
     (format (string-append
              "      Method(~s, ~s, Server.~a,\n"
              "          (ctx, reqs, sink) async {\n"
              "        await impl.~a(_~a~aServerImpl(ctx, reqs, sink));\n"
              "      }),\n")
             name (hash-ref m 'path) kind-const impl-name svc name)]))

(define (dart-service svc)
  (define sname (hash-ref svc 'name))
  (define methods (hash-ref svc 'methods))
  (parameterize ([current-service sname])
    (string-append
     (format "/// Client for ~a.\n" (hash-ref svc 'full-name))
     (format "class ~aClient {\n" sname)
     "  final Channel _channel;\n\n"
     (format "  ~aClient(this._channel);\n\n" sname)
     (apply string-append (map dart-client-method (append methods (alias-client-methods svc))))
     "}\n\n"
     (apply string-append (map dart-client-stream-class methods))
     (apply string-append (map dart-server-stream-iface methods))
     (format "/// Service implementation interface for ~a.\n" (hash-ref svc 'full-name))
     (format "abstract class ~aServer {\n" sname)
     (apply string-append (map dart-server-iface-method methods))
     "}\n\n"
     (apply string-append (map dart-stream-impl methods)))))

(define (emit-dart-file file-model params)
  (define base (path->string (path-replace-extension
                              (file-name-from-path (hash-ref file-model 'name)) "")))
  (define class-name (string-append (pascal (string->symbol base)) "GrpcDc"))
  (cons (string-append base "_grpc_dc.dart")
        (string-append
         "// @generated by protoc-gen-grpc-dc-dart (Racket metaprogram). DO NOT EDIT.\n"
         (format "// source: ~a\n\n" (hash-ref file-model 'name))
         "import 'dart:async';\n\n"
         "import '../grpcdc/channel.dart';\n"
         "import '../grpcdc/endpoint.dart';\n"
         "import '../grpcdc/server.dart';\n"
         "import '../grpcdc/status.dart';\n"
         "import '../grpcdc/wire.dart';\n"
         (format "import '~a_messages.dart';\n\n" base)
         (apply string-append
                (map (lambda (svc)
                       (let ([body (dart-service svc)])
                         body))
                     (hash-ref file-model 'services)))
         (format "/// Generated gRPC-over-DataChannels stubs for ~a.\n" (hash-ref file-model 'name))
         (format "class ~a {\n" class-name)
         (apply string-append
                (map (lambda (svc)
                       (define sname (hash-ref svc 'name))
                       (string-append
                        (format "  /// Register an implementation of ~a on a Server.\n" (hash-ref svc 'full-name))
                        (format "  static void register~aServer(Server server, ~aServer impl) {\n" sname sname)
                        (format "    server.registerService(ServiceDesc(~s, [\n" (hash-ref svc 'full-name))
                        (parameterize ([current-service sname])
                          (apply string-append
                                 (map dart-register-method
                                      (append (hash-ref svc 'methods)
                                              (alias-server-methods svc)))))
                        "    ]));\n"
                        "  }\n"))
                     (hash-ref file-model 'services)))
         "}\n")))
