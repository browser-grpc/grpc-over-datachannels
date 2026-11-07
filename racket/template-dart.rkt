#lang racket

;;; template-dart.rkt — emitter body spliced into
;;; protoc-gen-grpc-dc-dart.
;;;
;;; Generated code is beside hand-written message types implementing
;;; Marshaler / Unmarshaler. Method names keep the proto spelling,
;;; mirroring the other language stubs. Dart async is native
;;; (Future/Stream), so there is no separate async surface: every
;;; method already returns Future / exposes Stream.

(require "spec.rkt" "desc.rkt" "segments.rkt")
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
  (run-segments dart-deprecated-program m "" #f (list indent)))
(define (dart-client-method m)
  (run-segments dart-client-method-program m ""))
(define (dart-client-stream-class m)
  (run-segments dart-client-stream-class-program m (current-service)))
(define (dart-server-stream-iface m)
  (run-segments dart-server-stream-iface-program m (current-service)))
(define (dart-server-iface-method m)
  (run-segments dart-server-iface-method-program m (current-service)))
(define (dart-stream-impl m)
  (run-segments dart-stream-impl-program m (current-service)))
(define (dart-register-method m)
  (run-segments dart-register-method-program m (current-service)))
(define (dart-service svc)
  (run-segments dart-service-program svc (hash-ref svc 'name)))
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
  (run-segments dt-pb-type-program f "" model))
(define (dart-pb-explicit-literal model f)
  (define lit (run-segments dt-pb-explicit-literal-program f "" model))
  (and (not (string=? lit "")) lit))
(define (dart-pb-default model f)
  (run-segments dt-pb-default-program f "" model))
(define (dart-pb-varint-expr f v)
  (run-segments dt-pb-varint-expr-program f "" #f (list v)))
(define (dart-pb-varint-decode f v)
  (run-segments dt-pb-varint-decode-program f "" #f (list v)))
(define (dart-pb-nonzero f v)
  (run-segments dt-pb-nonzero-program f "" #f (list v)))
(define (dart-pb-encode-singular model f v indent support)
  (run-segments dt-pb-encode-singular-program f "" model (list v indent)))
(define (dart-pb-encode-field model f support)
  (run-segments dt-pb-encode-field-program f "" model (list support)))
(define (dart-pb-decode-singular model f target src indent support)
  (run-segments dt-pb-decode-singular-program f "" model (list target src indent support)))
(define (dart-pb-oneof-clearing model f)
  (run-segments dt-pb-oneof-clearing-program f "" model))
(define (dart-pb-decode-case model f support)
  (run-segments dt-pb-decode-case-program f "" model (list support)))
(define (dart-pb-map-helpers model entry support)
  (run-segments dt-pb-map-helpers-program entry "" model (list support)))
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
  (run-segments dt-pb-message-program msg "" model (list support indent)))
(define (dart-pb-enum model msg e indent)
  (run-segments dt-pb-enum-program e "" model
                (list indent
                      (if msg
                          (string-append (dart-pb-type-ref model (hasheq 'kind 'message 'msg msg 'enum #f 'file "" 'pkg (hash-ref model 'package))) "_" (hash-ref e 'name))
                          (hash-ref e 'name)))))
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
  ;; Body first: the wire.dart import is emitted only when the
  ;; body actually references Wire (else dart analyze flags it).
  (define body
    (string-append
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
         "}\n"))
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
         (if (string-contains? body "Wire.")
             "import '../grpcdc/wire.dart';\n"
             "")
         (dart-stub-imports file-model)
         ;; trace=hooks: re-export the tracer registrar; bake filter.
         (if (equal? (hash-ref params 'trace #f) "hooks")
             (string-append
              "\n// Tracing (trace=hooks@@TRACING_BETA@@): register an observer via setTracer.\n"
              "export '../grpcdc/status.dart' show setTracer, setTraceFilter;\n"
              (let ([methods (hash-ref params 'trace_methods #f)])
                (if methods
                    (format "final _grpcdcTraceFilterApplied = () { setTraceFilter(~s); return true; }();\n" methods)
                    "")))
             "")
         "\n"
         body)))
  (define pb-file (emit-dart-pb-file file-model))
  (if pb-file (list stub pb-file) stub))
