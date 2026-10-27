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
              "  /// Initial metadata (response headers); null until they arrive.\n"
              "  Map<String, String>? get headers => _stream.headers?.metadata;\n\n"
              "  /// Trailing metadata of the terminal status; null until it arrives.\n"
              "  Map<String, String>? get trailers => _stream.trailers;\n\n"
              "  /// Abort this stream (sends RST, wakes a pending recv).\n"
              "  void cancel() => _stream.cancel();\n\n"
              "  /// Abandon the call if still live (RST); no-op once terminated.\n"
              "  void close() => _stream.close();\n\n"
              "  /// Responses as a Dart Stream (native async surface).\n"
              "  /// Cancelling the subscription abandons the call:\n"
              "  /// RST CANCELLED is sent so the server stops.\n"
              "  Stream<~a> get responses {\n"
              "    var cancelled = false;\n"
              "    late StreamController<~a> controller;\n"
              "    controller = StreamController<~a>(\n"
              "      onListen: () {\n"
              "        () async {\n"
              "          try {\n"
              "            while (!cancelled) {\n"
              "              controller.add(await recv());\n"
              "            }\n"
              "          } on EndOfStreamError {\n"
              "            if (!cancelled) await controller.close();\n"
              "          } catch (e, st) {\n"
              "            if (!cancelled) {\n"
              "              controller.addError(e, st);\n"
              "              await controller.close();\n"
              "            }\n"
              "          }\n"
              "        }();\n"
              "      },\n"
              "      onCancel: () {\n"
              "        cancelled = true;\n"
              "        _stream.cancel();\n"
              "      },\n"
              "    );\n"
              "    return controller.stream;\n"
              "  }\n"
              "}\n\n")
             svc orig-name svc orig-name svc orig-name resp resp resp resp resp)]
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

;; ---------------------------------------------------------------------------
;; Dart message types (<base>_messages.dart, matching the stub's
;; import): classes implementing Marshaler/Unmarshaler plus
;; per-file <Base>Pb wire-support classes. Dependency-free
;; (dart: core only). Mirrors the Kotlin emitter on the shared
;; desc.rkt model.
;; ---------------------------------------------------------------------------

(define dart-pb-varint-types varint-scalar-types)
(define dart-pb-fixed (fixed-scalar-table 'dart))

(define (dart-pb-camel s)
  (define parts (string-split s "_"))
  (if (null? parts)
      s
      (apply string-append (car parts)
             (map (lambda (p) (if (string=? p "") "" (string-append (string (char-upcase (string-ref p 0))) (substring p 1))))
                  (cdr parts)))))

(define (dart-pb-field-name f)
  (define jn (hash-ref f 'json-name ""))
  (if (and jn (not (string=? jn ""))) jn (dart-pb-camel (hash-ref f 'name))))

(define (dart-pb-resolve model type-name)
  (hash-ref (hash-ref model 'types) type-name
            (lambda () (error 'emit-dart-pb-file "unresolved type ~a" type-name))))

(define (dart-pb-rel pkg full)
  (define rel (if (and pkg (not (string=? pkg "")) (string-prefix? full (string-append pkg ".")))
                  (substring full (add1 (string-length pkg)))
                  full))
  (string-join (string-split rel ".") "_"))

(define (dart-pb-entry-ref model entry)
  (dart-pb-rel (hash-ref entry 'pkg)
               (if (eq? (hash-ref entry 'kind) 'enum)
                   ;; The registry's 'full is the fully-qualified
                   ;; name (nested enums included); 'msg is #f for
                   ;; enums, so build from 'full.
                   (or (hash-ref entry 'full #f)
                       (let ([e (hash-ref entry 'enum)])
                         (format "~a.~a" (hash-ref entry 'pkg) (hash-ref e 'name))))
                   (hash-ref (hash-ref entry 'msg) 'full-name))))

;; Dart type name for a message/enum entry: nested types flatten
;; with _ like the JS emitter.
(define (dart-pb-type-ref model entry)
  (string-replace (dart-pb-entry-ref model entry) "." "_"))

(define (dart-pb-scalar f) (scalar-type-entry 'dart (hash-ref f 'type)))

(define (dart-pb-type model f)
  (define type (hash-ref f 'type))
  (define singular
    (cond [(= type 11)
           (define entry (dart-pb-resolve model (hash-ref f 'type-name)))
           (if (eq? (hash-ref entry 'kind) 'map)
               (let* ([em (hash-ref entry 'msg)]
                      [kf (findf (lambda (x) (= (hash-ref x 'number) 1)) (hash-ref em 'fields))]
                      [vf (findf (lambda (x) (= (hash-ref x 'number) 2)) (hash-ref em 'fields))])
                 (format "Map<~a, ~a>" (dart-pb-type model (hash-set kf 'label 1))
                         (if (= (hash-ref vf 'type) 11)
                             (dart-pb-type-ref model (dart-pb-resolve model (hash-ref vf 'type-name)))
                             (dart-pb-type model (hash-set vf 'label 1)))))
               (format "~a?" (dart-pb-type-ref model entry)))]
          [(= type 14) (dart-pb-type-ref model (dart-pb-resolve model (hash-ref f 'type-name)))]
          [else (first (dart-pb-scalar f))]))
  (cond [(and (= type 11)
              (eq? (hash-ref (dart-pb-resolve model (hash-ref f 'type-name)) 'kind) 'map))
         singular]
        [(= (hash-ref f 'label) 3)
         (format "List<~a>" (if (= type 11)
                                (dart-pb-type-ref model (dart-pb-resolve model (hash-ref f 'type-name)))
                                (dart-pb-type model (hash-set f 'label 1))))]
        [else singular]))

(define (dart-pb-explicit-literal model f)
  (define d (field-explicit-default f))
  (and d
       (case (hash-ref f 'type)
         [(9) (format "~s" d)]
         [(8) d]
         [(14) (format "~a.~a" (dart-pb-entry-ref model (dart-pb-resolve model (hash-ref f 'type-name))) d)]
         [(2) (format "~a" d)]
         [else d])))

(define (dart-pb-default model f)
  (cond [(dart-pb-explicit-literal model f) => (lambda (lit) lit)]
        [(and (= (hash-ref f 'type) 11)
              (eq? (hash-ref (dart-pb-resolve model (hash-ref f 'type-name)) 'kind) 'map))
         "{}"]
        [(= (hash-ref f 'label) 3) "[]"]
        [(= (hash-ref f 'type) 11) "null"]
        [(= (hash-ref f 'type) 14)
         (define entry (dart-pb-resolve model (hash-ref f 'type-name)))
         (format "~a.~a" (dart-pb-type-ref model entry) (hash-ref (car (hash-ref (hash-ref entry 'enum) 'values)) 'name))]
        [else (second (dart-pb-scalar f))]))

(define (dart-pb-varint-expr f v)
  (case (hash-ref f 'type)
    [(8) (format "(~a ? 1 : 0)" v)]
    [(17) (format "(((~a << 1) ^ (~a >> 31)) & 0xffffffff)" v v)]
    [(18) (format "((~a << 1) ^ (~a >> 63))" v v)]
    [(14) (format "~a.index" v)]
    [else v]))

(define (dart-pb-varint-decode f v)
  (case (hash-ref f 'type)
    [(5) (format "(~a).toSigned(32)" v)]
    [(13 7 4 6) (format "(~a).toUnsigned(64)" v)]
    [(8) (format "~a != 0" v)]
    [(17) (format "(((~a >> 1) ^ -(~a & 1))).toSigned(32)" v v)]
    [(18) (format "((~a >> 1) ^ -(~a & 1))" v v)]
    [else v]))

(define (dart-pb-nonzero f v)
  (case (hash-ref f 'type)
    [(8) v]
    [(14) (format "~a.index != 0" v)]
    [else (format "~a != 0" v)]))

(define (dart-pb-encode-singular model f v indent support)
  (define n (hash-ref f 'number))
  (define type (hash-ref f 'type))
  ;; Proto2 optional/required fields have explicit presence.
  (define proto2? (equal? (hash-ref model 'syntax "") "proto2"))
  (cond [(memv type dart-pb-varint-types)
         (if proto2?
             (format "~a{ w.tag(~a, 0); w.varint(~a); }\n" indent n (dart-pb-varint-expr f v))
             (format "~aif (~a) { w.tag(~a, 0); w.varint(~a); }\n" indent (dart-pb-nonzero f v) n (dart-pb-varint-expr f v)))]
        [(assv type dart-pb-fixed)
         => (lambda (info)
              (if proto2?
                  (format "~a{ w.tag(~a, ~a); w.fixed~a(~a); }\n" indent n
                          (if (= (second info) 8) 1 5) (third info) v)
                  (format "~aif (~a) { w.tag(~a, ~a); w.fixed~a(~a); }\n" indent (dart-pb-nonzero f v) n
                          (if (= (second info) 8) 1 5) (third info) v)))]
        [(= type 9)
         (if proto2?
             (format "~aw.bytesField(~a, utf8.encode(~a));\n" indent n v)
             (format "~aw.stringField(~a, ~a);\n" indent n v))]
        [(= type 12)
         (if proto2?
             (format "~aw.bytesField(~a, ~a);\n" indent n v)
             (format "~aif (~a.isNotEmpty) w.bytesField(~a, ~a);\n" indent v n v))]
        [(= type 11) (format "~aif (~a != null) w.bytesField(~a, ~a!.marshalDc());\n" indent v n v)]
        [else (error 'emit-dart-pb-file "unsupported field type ~a (groups)" type)]))

(define (dart-pb-set-expr sib)
  (define v (dart-pb-field-name sib))
  (case (hash-ref sib 'type)
    [(11 10) (format "~a != null" v)]
    [(9 12) (format "~a.isNotEmpty" v)]
    [else (dart-pb-nonzero sib v)]))

;; Encode-side oneof clearing: suppress f when a later sibling is
;; set, so only the winning member is written.
(define (dart-pb-encode-guard model f code)
  (define later (oneof-later-siblings model f))
  (if (null? later)
      code
      (format "    if (!(~a)) {\n~a    }\n"
              (string-join (map dart-pb-set-expr later) " || ")
              (if (string-suffix? code "\n") code (string-append code "\n")))))

(define (dart-pb-encode-field model f support)
  (define v (dart-pb-field-name f))
  (define n (hash-ref f 'number))
  (define type (hash-ref f 'type))
  (cond [(and (= type 11)
              (eq? (hash-ref (dart-pb-resolve model (hash-ref f 'type-name)) 'kind) 'map))
         (define entry (dart-pb-resolve model (hash-ref f 'type-name)))
         (define helper (format "~a~aEncode" support (dart-pb-map-helper-name model entry)))
         (format "    ~a.forEach((k, val) { w.bytesField(~a, ~a(k, val)); });\n" v n helper)]
        [(not (= (hash-ref f 'label) 3)) (dart-pb-encode-singular model f v "    " support)]
        [(memv type dart-pb-varint-types)
         (string-append
          (format "    if (~a.isNotEmpty) {\n" v)
          (format "        final payload = ~aWriter();\n" support)
          (format "        for (final x in ~a) { payload.varint(~a); }\n" v (dart-pb-varint-expr f "x"))
          (format "        w.bytesField(~a, payload.toBytes());\n    }\n" n))]
        [(assv type dart-pb-fixed)
         => (lambda (info)
              (string-append
               (format "    if (~a.isNotEmpty) {\n" v)
               (format "        final payload = ~aWriter();\n" support)
               (format "        for (final x in ~a) { payload.fixed~a(x); }\n" v (third info))
               (format "        w.bytesField(~a, payload.toBytes());\n    }\n" n)))]
        [(= type 9) (format "    for (final x in ~a) { w.bytesField(~a, utf8.encode(x)); }\n" v n)]
        [(= type 12) (format "    for (final x in ~a) { w.bytesField(~a, x); }\n" v n)]
        [(= type 11) (format "    for (final x in ~a) { w.bytesField(~a, x.marshalDc()); }\n" v n)]
        [else (error 'emit-dart-pb-file "unsupported repeated field type ~a" type)]))

(define (dart-pb-decode-singular model f target src indent support)
  (define type (hash-ref f 'type))
  (cond [(memv type dart-pb-varint-types)
         (format "~a~a = ~a;\n" indent target
                 (if (= type 14)
                     (format "~a.values[~a] " (dart-pb-type-ref model (dart-pb-resolve model (hash-ref f 'type-name))) (dart-pb-varint-decode (hash-set f 'type 5) src))
                     (dart-pb-varint-decode f src)))]
        [(assv type dart-pb-fixed)
         => (lambda (info)
              (format "~a~a = ~a;\n" indent target
                      (case (hash-ref f 'type)
                        [(2) (format "~aBitsToFloat32(~a)" support src)]
                        [(1) (format "~aBitsToFloat64(~a)" support src)]
                        [(7) (format "(~a).toUnsigned(32)" src)]
                        [(15) (format "(~a).toSigned(32)" src)]
                        [(6) (format "(~a).toUnsigned(64)" src)]
                        [(16) (format "(~a).toSigned(64)" src)]
                        [else src])))]
        [(= type 9) (format "~a~a = utf8.decode(~a);\n" indent target src)]
        [(= type 12) (format "~a~a = ~a;\n" indent target src)]
        [(= type 11)
         (define ref (dart-pb-type-ref model (dart-pb-resolve model (hash-ref f 'type-name))))
         (string-append
          (format "~a~a = ~a();\n" indent target ref)
          (format "~a~a!.unmarshalDc(~a);\n" indent target src))]
        [else (error 'emit-dart-pb-file "unsupported field type ~a" type)]))

(define (dart-pb-oneof-clearing model f)
  (apply string-append
         (map (lambda (sib)
                (format "          ~a = ~a;\n" (dart-pb-field-name sib) (dart-pb-default model sib)))
              (oneof-siblings model f))))

(define (dart-pb-decode-case model f support)
  (define v (dart-pb-field-name f))
  (define type (hash-ref f 'type))
  (define head (format "        case ~a:\n" (hash-ref f 'number)))
  (define clearing (dart-pb-oneof-clearing model f))
  (define tail "          break;\n")
  (cond [(and (= type 11)
              (eq? (hash-ref (dart-pb-resolve model (hash-ref f 'type-name)) 'kind) 'map))
         (define entry (dart-pb-resolve model (hash-ref f 'type-name)))
         (define helper (format "~a~aDecode" support (dart-pb-map-helper-name model entry)))
         (string-append head
                        (format "          final kv = ~a(field.bytesValue);\n" helper)
                        (format "          ~a[kv.key] = kv.value;\n" v)
                        tail)]
        [(not (= (hash-ref f 'label) 3))
         (string-append head
                        clearing
                        (dart-pb-decode-singular model f v
                                                 (cond [(memv type dart-pb-varint-types) "field.varintValue"]
                                                       [(assv type dart-pb-fixed) "field.fixedValue"]
                                                       [else "field.bytesValue"])
                                                 "          " support)
                        tail)]
        [(memv type dart-pb-varint-types)
         (string-append head
                        "          if (field.wire == 2) {\n"
                        (format "            final sub = ~aReader(field.bytesValue);\n" support)
                        "            while (!sub.done()) {\n"
                        (format "              ~a.add(~a);\n" v
                                (let ([conv (dart-pb-varint-decode f "sub.varint()")])
                                  (if (= type 14)
                                      (format "~a.values[~a]" (dart-pb-type-ref model (dart-pb-resolve model (hash-ref f 'type-name))) (dart-pb-varint-decode (hash-set f 'type 5) "sub.varint()"))
                                      conv)))
                        "            }\n          } else {\n"
                        (format "            ~a.add(~a);\n" v
                                (let ([conv (dart-pb-varint-decode f "field.varintValue")])
                                  (if (= type 14)
                                      (format "~a.values[~a]" (dart-pb-type-ref model (dart-pb-resolve model (hash-ref f 'type-name))) (dart-pb-varint-decode (hash-set f 'type 5) "field.varintValue"))
                                      conv)))
                        "          }\n" tail)]
        [(assv type dart-pb-fixed)
         => (lambda (info)
              (string-append head
                             "          if (field.wire == 2) {\n"
                             (format "            final sub = ~aReader(field.bytesValue);\n" support)
                             (format "            while (!sub.done()) { ~a.add(~a); }\n" v
                                     (case (hash-ref f 'type)
                                       [(2) (format "~aBitsToFloat32(sub.fixed32())" support)]
                                       [(1) (format "~aBitsToFloat64(sub.fixed64())" support)]
                                       [(7) "(sub.fixed32()).toUnsigned(32)"]
                                       [(15) "(sub.fixed32()).toSigned(32)"]
                                       [(6) "(sub.fixed64()).toUnsigned(64)"]
                                       [else "(sub.fixed64()).toSigned(64)"]))
                             "          } else {\n"
                             (format "            ~a.add(~a);\n" v
                                     (case (hash-ref f 'type)
                                       [(2) (format "~aBitsToFloat32(field.fixedValue)" support)]
                                       [(1) (format "~aBitsToFloat64(field.fixedValue)" support)]
                                       [(7) "(field.fixedValue).toUnsigned(32)"]
                                       [(15) "(field.fixedValue).toSigned(32)"]
                                       [(6) "(field.fixedValue).toUnsigned(64)"]
                                       [else "(field.fixedValue).toSigned(64)"]))
                             "          }\n" tail))]
        [(= type 9) (string-append head (format "          ~a.add(utf8.decode(field.bytesValue));\n" v) tail)]
        [(= type 12) (string-append head (format "          ~a.add(field.bytesValue);\n" v) tail)]
        [(= type 11)
         (string-append head
                        (format "          final item = ~a();\n" (dart-pb-type-ref model (dart-pb-resolve model (hash-ref f 'type-name))))
                        "          item.unmarshalDc(field.bytesValue);\n"
                        (format "          ~a.add(item);\n" v) tail)]
        [else (error 'emit-dart-pb-file "unsupported repeated field type ~a" type)]))

(define (dart-pb-map-helper-name model entry)
  (define rel (dart-pb-rel (hash-ref entry 'pkg) (hash-ref (hash-ref entry 'msg) 'full-name)))
  rel)

(define (dart-pb-map-helpers model entry support)
  (define msg (hash-ref entry 'msg))
  (define base (dart-pb-map-helper-name model entry))
  (define key-f (findf (lambda (x) (= (hash-ref x 'number) 1)) (hash-ref msg 'fields)))
  (define val-f (findf (lambda (x) (= (hash-ref x 'number) 2)) (hash-ref msg 'fields)))
  (unless (and key-f val-f) (error 'emit-dart-pb-file "map entry ~a lacks key/value" (hash-ref msg 'full-name)))
  (define kt (dart-pb-type model (hash-set key-f 'label 1)))
  (define vt (dart-pb-type model (hash-set val-f 'label 1)))
  (define vt-plain (if (and (= (hash-ref val-f 'type) 11)
                            (not (eq? (hash-ref (dart-pb-resolve model (hash-ref val-f 'type-name)) 'kind) 'map)))
                       (dart-pb-type-ref model (dart-pb-resolve model (hash-ref val-f 'type-name)))
                       vt))
  (string-append
   (format "Uint8List ~a~aEncode(~a key, ~a value) {\n" support base kt vt-plain)
   (format "  final w = ~aWriter();\n" support)
   (dart-pb-encode-singular model (hash-set key-f 'label 1) "key" "  " support)
   (if (= (hash-ref val-f 'type) 11)
       (format "  w.bytesField(~a, value.marshalDc());\n" (hash-ref val-f 'number))
       (dart-pb-encode-singular model (hash-set val-f 'label 1) "value" "  " support))
   "  return w.toBytes();\n}\n\n"
   (format "MapEntry<~a, ~a> ~a~aDecode(Uint8List bytes) {\n" kt vt-plain support base)
   (format "  ~a key = ~a;\n" kt (dart-pb-default model (hash-set key-f 'label 1)))
   (format "  ~a value = ~a;\n" vt-plain (if (= (hash-ref val-f 'type) 11) (format "~a()" vt-plain) (dart-pb-default model (hash-set val-f 'label 1))))
   (format "  final r = ~aReader(bytes);\n" support)
   "  while (true) {\n    final field = r.next();\n    if (field == null) break;\n    switch (field.number) {\n"
   (format "      case ~a:\n~a        break;\n" (hash-ref key-f 'number)
           (dart-pb-decode-singular model (hash-set key-f 'label 1) "key"
                                    (cond [(memv (hash-ref key-f 'type) dart-pb-varint-types) "field.varintValue"]
                                          [(assv (hash-ref key-f 'type) dart-pb-fixed) "field.fixedValue"]
                                          [else "field.bytesValue"]) "        " support))
   (format "      case ~a:\n~a        break;\n" (hash-ref val-f 'number)
           (if (= (hash-ref val-f 'type) 11)
               "        value.unmarshalDc(field.bytesValue);\n"
               (dart-pb-decode-singular model (hash-set val-f 'label 1) "value"
                                        (cond [(memv (hash-ref val-f 'type) dart-pb-varint-types) "field.varintValue"]
                                              [(assv (hash-ref val-f 'type) dart-pb-fixed) "field.fixedValue"]
                                              [else "field.bytesValue"]) "        " support)))
   "      default:\n        break;\n    }\n  }\n  return MapEntry(key, value);\n}\n\n"))

(define (dart-pb-support base helpers)
  (define p (string-append (pascal (string->symbol base)) "Pb"))
  (string-append
   "// @generated by protoc-gen-grpc-dc-dart. DO NOT EDIT.\n"
   "import 'dart:convert';\n"
   "import 'dart:typed_data';\n\n"
   "import '../grpcdc/transport.dart';\n\n"
   (format "class ~aWriter {\n" p)
   "  final BytesBuilder _out = BytesBuilder();\n"
   "  void varint(int value) { var v = BigInt.from(value) & ((BigInt.one << 64) - BigInt.one); final continuation = BigInt.from(0x80); while (v >= continuation) { _out.addByte(((v & BigInt.from(0x7f)) | continuation).toInt()); v = v >> 7; } _out.addByte(v.toInt()); }\n"
   "  void tag(int field, int wire) { varint((field << 3) | wire); }\n"
   "  void bytesField(int field, List<int> payload) { tag(field, 2); varint(payload.length); _out.add(payload); }\n"
   "  void stringField(int field, String value) { if (value.isEmpty) return; bytesField(field, utf8.encode(value)); }\n"
   "  void fixedUint32(int value) { final b = ByteData(4); b.setUint32(0, value, Endian.little); _out.add(b.buffer.asUint8List()); }\n"
   "  void fixedInt32(int value) { final b = ByteData(4); b.setInt32(0, value, Endian.little); _out.add(b.buffer.asUint8List()); }\n"
   "  void fixedUint64(int value) { final b = ByteData(8); b.setUint64(0, value, Endian.little); _out.add(b.buffer.asUint8List()); }\n"
   "  void fixedInt64(int value) { final b = ByteData(8); b.setInt64(0, value, Endian.little); _out.add(b.buffer.asUint8List()); }\n"
   "  void raw(List<int> payload) { _out.add(payload); }\n"
   "  void fixedFloat32(double value) { final b = ByteData(4); b.setFloat32(0, value, Endian.little); _out.add(b.buffer.asUint8List()); }\n"
   "  void fixedFloat64(double value) { final b = ByteData(8); b.setFloat64(0, value, Endian.little); _out.add(b.buffer.asUint8List()); }\n"
   "  Uint8List toBytes() => _out.toBytes();\n"
   "}\n\n"
   (format "double ~aBitsToFloat32(int bits) { final b = ByteData(4); b.setUint32(0, bits, Endian.little); return b.getFloat32(0, Endian.little); }\n" p)
   (format "double ~aBitsToFloat64(int bits) { final b = ByteData(8); b.setUint64(0, bits, Endian.little); return b.getFloat64(0, Endian.little); }\n\n" p)
   (format "class ~aField {\n" p)
   "  final int number; final int wire; final int varintValue; final Uint8List bytesValue; final int fixedValue; final Uint8List rawValue;\n"
   (format "  ~aField(this.number, this.wire, this.varintValue, this.bytesValue, this.fixedValue, this.rawValue);\n" p)
   "}\n\n"
   (format "class ~aReader {\n" p)
   "  final Uint8List _buf; int _pos = 0;\n"
   (format "  ~aReader(this._buf);\n" p)
   "  int _signed64(BigInt value) { final masked = value & ((BigInt.one << 64) - BigInt.one); return (masked >= (BigInt.one << 63) ? masked - (BigInt.one << 64) : masked).toInt(); }\n"
   "  bool done() => _pos >= _buf.length;\n"
   "  int varint() { var result = BigInt.zero; var shift = 0; while (true) { if (_pos >= _buf.length) throw StateError('truncated varint'); final b = _buf[_pos++]; result |= BigInt.from(b & 0x7f) << shift; if ((b & 0x80) == 0) return _signed64(result); shift += 7; if (shift >= 70) throw StateError('varint too long'); } }\n"
   "  Uint8List take(int n) { if (_pos + n > _buf.length) throw StateError('truncated field'); final v = Uint8List.fromList(_buf.sublist(_pos, _pos + n)); _pos += n; return v; }\n"
   "  int fixed32() { final b = take(4); return b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24); }\n"
   "  int fixed64() { final b = take(8); var v = BigInt.zero; for (var i = 0; i < 8; i++) { v |= BigInt.from(b[i]) << (8 * i); } return _signed64(v); }\n"
   (format "  ~aField? next() {\n" p)
   "    if (_pos >= _buf.length) return null;\n"
   "    final start = _pos;\n"
   "    final tag = varint(); final number = tag >> 3; final wire = tag & 7;\n"
   "    switch (wire) {\n"
   (format "      case 0: return ~aField(number, wire, varint(), Uint8List(0), 0, Uint8List.fromList(_buf.sublist(start, _pos)));\n" p)
   (format "      case 2: final n = varint(); return ~aField(number, wire, 0, take(n), 0, Uint8List.fromList(_buf.sublist(start, _pos)));\n" p)
   (format "      case 1: final b = take(8); var v = BigInt.zero; for (var i = 0; i < 8; i++) { v |= BigInt.from(b[i]) << (8 * i); } return ~aField(number, wire, 0, b, _signed64(v), Uint8List.fromList(_buf.sublist(start, _pos)));\n" p)
   (format "      case 5: final b = take(4); final v = b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24); return ~aField(number, wire, 0, b, v, Uint8List.fromList(_buf.sublist(start, _pos)));\n" p)
   "      default: throw StateError('bad wire type');\n"
   "    }\n"
   "  }\n"
   "}\n\n"
   helpers))

(define (dart-pb-message-class model msg support indent)
  (define name (dart-pb-type-ref model (hasheq 'kind 'message 'msg msg 'enum #f 'file "" 'pkg (hash-ref model 'package))))
  (define fields (hash-ref msg 'fields))
  (string-append
   (format "~aclass ~a implements Marshaler, Unmarshaler {\n" indent name)
   (apply string-append
          (map (lambda (f)
                 (format "~a  ~a ~a;\n" indent (dart-pb-type model f) (dart-pb-field-name f)))
               fields))
   (format "~a  Uint8List unknownFields = Uint8List(0);\n" indent)
   (let ([params (filter (lambda (f) (not (or (= (hash-ref f 'label) 3)
                                              (= (hash-ref f 'type) 12)
                                              (and (= (hash-ref f 'type) 11)
                                                   (eq? (hash-ref (dart-pb-resolve model (hash-ref f 'type-name)) 'kind) 'map)))))
                         fields)]
         [inits (filter (lambda (f) (or (= (hash-ref f 'label) 3)
                                        (= (hash-ref f 'type) 12)
                                        (and (= (hash-ref f 'type) 11)
                                             (eq? (hash-ref (dart-pb-resolve model (hash-ref f 'type-name)) 'kind) 'map))))
                        fields)])
     (if (and (null? params) (null? inits))
         (format "~a  ~a();\n" indent name)
         (string-append
          (format "~a  ~a(" indent name)
          (if (null? params)
              ""
              (string-append "[" (string-join (map (lambda (f) (format "this.~a = ~a" (dart-pb-field-name f) (dart-pb-default model f))) params) ", ") "]"))
          (if (null? inits)
              ");\n"
              (string-append
               ") : "
               (string-join (map (lambda (f) (format "~a = ~a" (dart-pb-field-name f) (dart-pb-default model f))) inits) ", ")
               ";\n")))))
   (format "~a  @override\n~a  Uint8List marshalDc() {\n" indent indent)
   (format "~a    final w = ~aWriter();\n" indent support)
   (apply string-append (map (lambda (f) (dart-pb-encode-guard model f (dart-pb-encode-field model f support))) fields))
   (format "~a    w.raw(unknownFields);\n" indent)
   (format "~a    return w.toBytes();\n~a  }\n" indent indent)
   (format "~a  @override\n~a  void unmarshalDc(List<int> data) {\n" indent indent)
   (format "~a    unknownFields = Uint8List(0);\n" indent)
   (apply string-append
          (map (lambda (f) (format "~a    ~a = ~a;\n" indent (dart-pb-field-name f) (dart-pb-default model f))) fields))
   (format "~a    final r = ~aReader(Uint8List.fromList(data));\n" indent support)
   (format "~a    while (true) {\n~a      final field = r.next();\n~a      if (field == null) break;\n~a      switch (field.number) {\n" indent indent indent indent)
   (apply string-append (map (lambda (f) (dart-pb-decode-case model f support)) fields))
   (format "~a        default:\n~a          unknownFields = Uint8List.fromList([...unknownFields, ...field.rawValue]);\n~a          break;\n~a      }\n~a    }\n~a  }\n" indent indent indent indent indent indent)
   (format "~a}\n" indent)
   (apply string-append (map (lambda (n) (dart-pb-message-class model n support indent)) (hash-ref msg 'nested)))
   (apply string-append (map (lambda (e) (dart-pb-enum model msg e indent)) (hash-ref msg 'enums)))))

(define (dart-pb-enum model msg e indent)
  (define name (if msg
                   (string-append (dart-pb-type-ref model (hasheq 'kind 'message 'msg msg 'enum #f 'file "" 'pkg (hash-ref model 'package))) "_" (hash-ref e 'name))
                   (hash-ref e 'name)))
  (string-append
   (format "~aenum ~a {\n" indent name)
   (string-join (map (lambda (v) (format "~a  ~a" indent (hash-ref v 'name))) (hash-ref e 'values)) ",\n")
   (format "\n~a}\n" indent)))

(define (emit-dart-pb-file file-model)
  (and (hash-has-key? file-model 'messages)
       (hash-has-key? file-model 'types)
       (emit-dart-pb-file/inner file-model)))

(define (emit-dart-pb-file/inner file-model)
  (define messages (hash-ref file-model 'messages))
  (define enums (hash-ref file-model 'enums))
  (and (or (pair? messages) (pair? enums))
       (let ()
         (define base (path->string (path-replace-extension
                                     (file-name-from-path (hash-ref file-model 'name)) "")))
         (define support (string-append (pascal (string->symbol base)) "Pb"))
         (define seen-maps (mutable-set))
         (define helpers '())
         (define (collect msg)
           (for ([f (in-list (hash-ref msg 'fields))])
             (when (= (hash-ref f 'type) 11)
               (define e (dart-pb-resolve file-model (hash-ref f 'type-name)))
               (when (and (eq? (hash-ref e 'kind) 'map)
                          (not (set-member? seen-maps (hash-ref (hash-ref e 'msg) 'full-name))))
                 (set-add! seen-maps (hash-ref (hash-ref e 'msg) 'full-name))
                 (set! helpers (cons (dart-pb-map-helpers file-model e support) helpers)))))
           (for ([n (in-list (hash-ref msg 'nested))]) (collect n)))
         (for ([m (in-list messages)]) (collect m))
         (define dep-imports
           (apply string-append
                  (map (lambda (d)
                         (format "import '~a_messages.dart';\n"
                                 (path->string (path-replace-extension (file-name-from-path d) ""))))
                       (hash-ref file-model 'dependencies))))
         (define content
           (string-append
            dep-imports
            (dart-pb-support base (apply string-append (reverse helpers)))
            (apply string-append
                   (map (lambda (e) (dart-pb-enum file-model #f e "")) enums))
            (apply string-append
                   (map (lambda (m) (dart-pb-message-class file-model m support ""))
                        (filter (lambda (m) (not (hash-ref m 'map-entry))) messages)))))
         (cons (string-append base "_messages.dart") content))))

;; Message imports for a stub: one <base>_messages.dart per file
;; that defines a method input/output type (which may live in an
;; imported proto, not the service's own file).
(define (dart-stub-imports file-model)
  (cond [(not (hash-has-key? file-model 'types))
         (format "import '~a_messages.dart';\n"
                 (path->string (path-replace-extension
                                (file-name-from-path (hash-ref file-model 'name)) "")))]
        [else
         (define files
           (remove-duplicates
            (for*/list ([svc (in-list (hash-ref file-model 'services))]
                        [m (in-list (hash-ref svc 'methods))]
                        [k (in-list '(input-full output-full))])
              (hash-ref (dart-pb-resolve file-model (hash-ref m k))
                        'file))))
         (apply string-append
                (map (lambda (fn)
                       (format "import '~a_messages.dart';\n"
                               (path->string (path-replace-extension
                                              (file-name-from-path fn) ""))))
                     files))]))

(define (emit-dart-file file-model params)
  (define base (path->string (path-replace-extension
                              (file-name-from-path (hash-ref file-model 'name)) "")))
  (define class-name (string-append (pascal (string->symbol base)) "GrpcDc"))
  (define stub
    (cons (string-append base "_grpc_dc.dart")
          (string-append
           "// @generated by protoc-gen-grpc-dc-dart. DO NOT EDIT.\n"
         (format "// source: ~a\n\n" (hash-ref file-model 'name))
         "import 'dart:async';\n\n"
         "import '../grpcdc/channel.dart';\n"
         "import '../grpcdc/endpoint.dart';\n"
         "import '../grpcdc/server.dart';\n"
         "import '../grpcdc/status.dart';\n"
         "import '../grpcdc/wire.dart';\n"
         (dart-stub-imports file-model)
         ;; trace=hooks: re-export the tracer registrar; bake filter.
         (if (equal? (hash-ref params 'trace #f) "hooks")
             (string-append
              "\n// Tracing (trace=hooks): register an observer via setTracer.\n"
              "export '../grpcdc/status.dart' show setTracer, setTraceFilter;\n"
              (let ([methods (hash-ref params 'trace_methods #f)])
                (if methods
                    (format "final _grpcdcTraceFilterApplied = () { setTraceFilter(~s); return true; }();\n" methods)
                    "")))
             "")
         "\n"
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
  (define pb-file (emit-dart-pb-file file-model))
  (if pb-file (list stub pb-file) stub))
