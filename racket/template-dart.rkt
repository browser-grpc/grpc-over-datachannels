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
         (define struct-imports
           (if (seg-struct-codec)
               (let ([names '()])
                 (define (collect-structs msg)
                   (unless (hash-ref msg 'map-entry)
                     (set! names (cons (dt-struct-type-name file-model msg) names)))
                   (for ([n (in-list (hash-ref msg 'nested))]) (collect-structs n)))
                 (for ([m (in-list messages)]) (collect-structs m))
                 (apply string-append
                        (map (lambda (tn) (format "import '~aStructStub.dart' if (dart.library.ffi) '~aStruct.dart';\n" tn tn))
                             (reverse names))))
               ""))
         (define content
           (string-append
            dep-imports
            struct-imports
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
  (define pb-file (parameterize ([seg-struct-codec (equal? (hash-ref params 'struct_codec #f) "true")])
                    (emit-dart-pb-file file-model)))
  (define struct-files (emit-dart-struct-files file-model params base))
  (if (null? struct-files)
      (if pb-file (list stub pb-file) stub)
      (append (list stub pb-file) struct-files)))

;; ------------------------------------------------------------------
;; Struct codec (struct_codec=true): <Msg>Struct class per message
;; with the packed layout from SPEC.md (byte-identical to the
;; Go/Rust/Java/Kotlin/Scala/Swift struct codecs; verified by
;; conformance/struct).
(define (dt-struct-fingerprint s)
  (for/fold ([h 2166136261]) ([c (in-string s)])
    (modulo (* (bitwise-xor h (char->integer c)) 16777619) 4294967296)))

(define (dt-struct-fixed32-type? t) (member t '(2 7 15)))
(define (dt-struct-fixed64-type? t) (member t '(1 6 16)))

(define (dt-struct-slot-size f)
  (if (dt-struct-fixed32-type? (hash-ref f 'type)) 4 8))

(define (dt-struct-sorted-fields msg)
  (sort (hash-ref msg 'fields) < #:key (lambda (f) (hash-ref f 'number))))

(define (dt-struct-map-entry model f)
  (and (= (hash-ref f 'type) 11)
       (let ([e (dart-pb-resolve model (hash-ref f 'type-name))])
         (and (eq? (hash-ref e 'kind) 'map) e))))

(define (dt-struct-map-key-field model f)
  (define em (hash-ref (dt-struct-map-entry model f) 'msg))
  (findf (lambda (x) (= (hash-ref x 'number) 1)) (hash-ref em 'fields)))
(define (dt-struct-map-val-field model f)
  (define em (hash-ref (dt-struct-map-entry model f) 'msg))
  (findf (lambda (x) (= (hash-ref x 'number) 2)) (hash-ref em 'fields)))

(define (dt-struct-type-name model msg)
  (dart-pb-type-ref model (hasheq 'kind 'message 'msg msg 'enum #f
                                  'file "" 'pkg (hash-ref model 'package))))

(define (dt-struct-companion model f)
  (string-append (dt-struct-class-name model f) "Struct"))

(define (dt-struct-class-name model f)
  (define e (dart-pb-resolve model (hash-ref f 'type-name)))
  (dart-pb-type-ref model e))

(define (dt-struct-present f dn)
  (define t (hash-ref f 'type))
  (cond [(= (hash-ref f 'label) 3) (format "m.~a.isNotEmpty" dn)]
        [(= t 11) (format "m.~a != null" dn)]
        [(= t 9) (format "m.~a.isNotEmpty" dn)]
        [(= t 12) (format "m.~a.isNotEmpty" dn)]
        [(= t 8) (format "m.~a" dn)]
        [(= t 14) (format "m.~a.index != 0" dn)]
        [else (format "m.~a != 0" dn)]))

(define (dt-struct-scalar-encode f v)
  (define t (hash-ref f 'type))
  (cond [(dt-struct-fixed32-type? t)
         (cond [(= t 2) (format "put32(buf, off, floatBits(~a));" v)]
               [else (format "put32(buf, off, ~a);" v)])]
        [(dt-struct-fixed64-type? t)
         (cond [(= t 1) (format "put64(buf, off, doubleBits(~a));" v)]
               [else (format "put64(buf, off, ~a);" v)])]
        [(= t 8) (format "buf[off] = ~a ? 1 : 0;" v)]
        [(= t 14) (format "put64(buf, off, ~a.index);" v)]
        [else (format "put64(buf, off, ~a);" v)]))

(define (dt-struct-scalar-value/off model f offv)
  (define t (hash-ref f 'type))
  (cond [(dt-struct-fixed32-type? t)
         (cond [(= t 2) (format "bitsFloat(get32(data, ~a))" offv)]
               [else (format "get32signed(data, ~a)" offv)])]
        [(dt-struct-fixed64-type? t)
         (cond [(= t 1) (format "bitsDouble(get64(data, ~a))" offv)]
               [else (format "get64(data, ~a)" offv)])]
        [(= t 8) (format "(data[~a] != 0)" offv)]
        [(= t 14) (format "enumAt(~a.values, get64(data, ~a).toInt())"
                          (dart-pb-type model (hash-set f 'label 1)) offv)]
        [(member t '(5 17)) (format "get64(data, ~a).toInt()" offv)]
        [else (format "get64(data, ~a)" offv)]))

(define (dt-struct-value-size model f v)
  (define t (hash-ref f 'type))
  (cond [(= t 9) (format "utf8.encode(~a).length" v)]
        [(= t 12) (format "~a.length" v)]
        [(= t 11) (format "(~a == null ? 0 : ~a.size(~a))" v (dt-struct-companion model f) v)]
        [(dt-struct-fixed32-type? t) "4"]
        [else "8"]))

(define (dt-struct-message model msg)
  (define type-name (dt-struct-type-name model msg))
  (define out (open-output-string))
  (fprintf out "class ~aStruct {\n" type-name)
  (fprintf out "  static int size(~a m) => marshal(m).length;\n\n" type-name)
  (fprintf out "  static Uint8List marshal(~a m) => structdcTranscode(true, '~a', m.marshalDc());\n\n" type-name (hash-ref msg 'full-name))
  (fprintf out "  static ~a unmarshal(Uint8List data) {\n    final m = ~a();\n    m.unmarshalDc(structdcTranscode(false, '~a', data));\n    return m;\n  }\n}\n" type-name type-name (hash-ref msg 'full-name))
  (get-output-string out))

(define (dt-struct-value-write model f v)
  (define t (hash-ref f 'type))
  (define out (open-output-string))
  (cond [(= t 9)
         (fprintf out "                final sb = utf8.encode(~a); buf.setRange(vp, vp + sb.length, sb); vp += sb.length;\n" v)]
        [(= t 12)
         (fprintf out "                buf.setRange(vp, vp + ~a.length, ~a); vp += ~a.length;\n" v v v)]
        [(= t 11)
         (fprintf out "                if (~a != null) { final nb = ~a.marshal(~a); buf.setRange(vp, vp + nb.length, nb); vp += nb.length; }\n" v (dt-struct-companion model f) v)]
        [else
         (fprintf out "                { final off = vp; ~a } vp += ~a;\n"
                  (dt-struct-scalar-encode f v) (if (dt-struct-fixed32-type? t) 4 8))])
  (get-output-string out))

(define (dt-struct-marshal-field model f off)
  (define dn (dart-pb-field-name f))
  (define t (hash-ref f 'type))
  (define out (open-output-string))
  (define mv (format "m.~a" dn))
  (cond [(dt-struct-map-entry model f)
         (define kf (dt-struct-map-key-field model f))
         (define vf (dt-struct-map-val-field model f))
         (fprintf out "    if (~a.isNotEmpty) {\n      put32(buf, ~a, vp); put32(buf, ~a, ~a.length);\n" mv off (+ off 4) mv)
         (fprintf out "      final keys = ~a.keys.toList()..sort();\n" mv)
         (fprintf out "      for (final k in keys) {\n        final v = ~a[k]!;\n        put32(buf, vp, ~a); put32(buf, vp + 4, ~a); vp += 8;\n"
                  mv (dt-struct-value-size model kf "k") (dt-struct-value-size model vf "v"))
         (display (dt-struct-value-write model kf "k") out)
         (display (dt-struct-value-write model vf "v") out)
         (fprintf out "      }\n    }\n")]
        [(= (hash-ref f 'label) 3)
         (cond [(member t '(9 12))
                (fprintf out "    if (~a.isNotEmpty) {\n      put32(buf, ~a, vp); put32(buf, ~a, ~a.length);\n      var doff = vp + 8 * ~a.length;\n      for (final e in ~a) { put32(buf, vp, doff); put32(buf, vp + 4, ~a); doff += ~a; vp += 8; }\n      for (final e in ~a) { ~a }\n    }\n"
                         mv off (+ off 4) mv mv mv
                         (if (= t 9) "utf8.encode(e).length" "e.length")
                         (if (= t 9) "utf8.encode(e).length" "e.length")
                         mv
                         (if (= t 9) "final sb = utf8.encode(e); buf.setRange(vp, vp + sb.length, sb); vp += sb.length;"
                             "buf.setRange(vp, vp + e.length, e); vp += e.length;"))]
               [(= t 11)
                (fprintf out "    if (~a.isNotEmpty) {\n      put32(buf, ~a, vp); put32(buf, ~a, ~a.length);\n      var doff = vp + 8 * ~a.length;\n      for (final e in ~a) { final es = ~a.size(e); put32(buf, vp, doff); put32(buf, vp + 4, es); doff += es; vp += 8; }\n      for (final e in ~a) { final nb = ~a.marshal(e); buf.setRange(vp, vp + nb.length, nb); vp += nb.length; }\n    }\n"
                         mv off (+ off 4) mv mv mv (dt-struct-companion model f)
                         mv (dt-struct-companion model f))]
               [else
                (fprintf out "    if (~a.isNotEmpty) {\n      put32(buf, ~a, vp); put32(buf, ~a, ~a.length);\n      for (final e in ~a) { final off = vp; ~a vp += ~a; }\n    }\n"
                         mv off (+ off 4) mv
                         mv
                         (dt-struct-scalar-encode f "e")
                         (if (dt-struct-fixed32-type? t) 4 8))])]
        [(= t 11)
         (fprintf out "    if (~a != null) {\n      put32(buf, ~a, vp); put32(buf, ~a, ~a.size(~a!));\n      final nb = ~a.marshal(~a!); buf.setRange(vp, vp + nb.length, nb); vp += nb.length;\n    }\n"
                  mv off (+ off 4) (dt-struct-companion model f) mv (dt-struct-companion model f) mv)]
        [(member t '(9 12))
         (fprintf out "    if (~a.isNotEmpty) {\n      put32(buf, ~a, vp); put32(buf, ~a, ~a);\n      ~a\n    }\n"
                  mv off (+ off 4)
                  (if (= t 9) (format "utf8.encode(~a).length" mv) (format "~a.length" mv))
                  (if (= t 9)
                      (format "final sb = utf8.encode(~a); buf.setRange(vp, vp + sb.length, sb); vp += sb.length;" mv)
                      (format "buf.setRange(vp, vp + ~a.length, ~a); vp += ~a.length;" mv mv mv)))]
        [else
         (fprintf out "    { final off = ~a; ~a }\n" off (dt-struct-scalar-encode f mv))])
  (get-output-string out))

(define (dt-struct-value-expr/off model f lenvar offv)
  (define t (hash-ref f 'type))
  (cond [(= t 9) (format "utf8.decode(data.sublist(~a, ~a + ~a))" offv offv lenvar)]
        [(= t 12) (format "Uint8List.fromList(data.sublist(~a, ~a + ~a))" offv offv lenvar)]
        [(= t 11) (format "(~a > 0 ? ~a.unmarshal(Uint8List.fromList(data.sublist(~a, ~a + ~a))) : ~a())"
                          lenvar (dt-struct-companion model f) offv offv lenvar
                          (dt-struct-class-name model f))]
        [else (dt-struct-scalar-value/off model f offv)]))

(define (dt-struct-decode-field model f foff)
  (define dn (dart-pb-field-name f))
  (define t (hash-ref f 'type))
  (define out (open-output-string))
  (define mv (format "m.~a" dn))
  (cond [(dt-struct-map-entry model f)
         (define kf (dt-struct-map-key-field model f))
         (define vf (dt-struct-map-val-field model f))
         (fprintf out "      final off = get32(data, ~a); final n = get32(data, ~a);\n" foff (+ foff 4))
         (fprintf out "      var p = off;\n      for (var i = 0; i < n; i++) {\n")
         (fprintf out "        check(data, p, 8);\n        final kl = get32(data, p); final vl = get32(data, p + 4); p += 8;\n        check(data, p, kl + vl);\n")
         (fprintf out "        final k = () { final io = p; return ~a; }();\n" (dt-struct-value-expr/off model kf "kl" "io"))
         (fprintf out "        final v = () { final io = p + kl; return ~a; }();\n" (dt-struct-value-expr/off model vf "vl" "io"))
         (fprintf out "        ~a[k] = v;\n        p += kl + vl;\n      }\n      if (p > vend) { vend = p; }\n" mv)]
        [(= (hash-ref f 'label) 3)
         (fprintf out "      final off = get32(data, ~a); final n = get32(data, ~a);\n" foff (+ foff 4))
         (cond [(member t '(9 12))
                (fprintf out "      for (var i = 0; i < n; i++) {\n        final eo = get32(data, off + 8 * i); final el = get32(data, off + 8 * i + 4);\n        check(data, eo, el);\n        ~a.add(~a);\n        if (eo + el > vend) { vend = eo + el; }\n      }\n"
                         mv (if (= t 9) "utf8.decode(data.sublist(eo, eo + el))" "Uint8List.fromList(data.sublist(eo, eo + el))"))]
               [(= t 11)
                (fprintf out "      for (var i = 0; i < n; i++) {\n        final eo = get32(data, off + 8 * i); final el = get32(data, off + 8 * i + 4);\n        if (el > 0) {\n          check(data, eo, el);\n          ~a.add(~a.unmarshal(Uint8List.fromList(data.sublist(eo, eo + el))));\n          if (eo + el > vend) { vend = eo + el; }\n        }\n      }\n"
                         mv (dt-struct-companion model f))]
               [else
                (define esz (if (dt-struct-fixed32-type? t) 4 8))
                (fprintf out "      check(data, off, n * ~a);\n      for (var i = 0; i < n; i++) {\n        final eo = off + i * ~a;\n        ~a.add(~a);\n      }\n      if (off + n * ~a > vend) { vend = off + n * ~a; }\n"
                         esz esz mv (dt-struct-scalar-value/off model f "eo") esz esz)])]
        [(= t 11)
         (fprintf out "      final off = get32(data, ~a); final el = get32(data, ~a);\n" foff (+ foff 4))
         (fprintf out "      check(data, off, el);\n      ~a = ~a.unmarshal(Uint8List.fromList(data.sublist(off, off + el)));\n      if (off + el > vend) { vend = off + el; }\n" mv (dt-struct-companion model f))]
        [(member t '(9 12))
         (fprintf out "      final off = get32(data, ~a); final el = get32(data, ~a);\n" foff (+ foff 4))
         (fprintf out "      check(data, off, el);\n")
         (if (= t 9)
             (fprintf out "      ~a = utf8.decode(data.sublist(off, off + el));\n" mv)
             (fprintf out "      ~a = Uint8List.fromList(data.sublist(off, off + el));\n" mv))
         (fprintf out "      if (off + el > vend) { vend = off + el; }\n")]
        [else
         (fprintf out "      final off = ~a;\n      ~a = ~a;\n" foff mv
                  (dt-struct-scalar-value/off model f "off"))])
  (get-output-string out))

(define (dt-struct-imports model msg base)
  (define seen (mutable-set))
  (define imports '())
  (for ([f (in-list (hash-ref msg 'fields))])
    (when (or (= (hash-ref f 'type) 11) (= (hash-ref f 'type) 14))
      (when (= (hash-ref f 'type) 11)
        (define e (dart-pb-resolve model (hash-ref f 'type-name)))
        (when (eq? (hash-ref e 'kind) 'message)
          (define tn (dt-struct-type-name model (hash-ref e 'msg)))
          (unless (set-member? seen tn)
            (set-add! seen tn)
            (set! imports (cons tn imports)))))))
  (apply string-append
         (map (lambda (tn) (format "import '~aStruct.dart';\n" tn))
              (reverse imports))))

(define (emit-dart-struct-files file-model params base)
  (if (equal? (hash-ref params 'struct_codec #f) "true")
      (let ()
        (define descriptor
          (string-join
           (for/list ([b (in-bytes (hash-ref file-model 'descriptor-set #""))])
             (number->string b))
           ","))
        (define bridge
          (cons (string-append base "_structdc.dart")
                (string-append
                 "// @generated by protoc-gen-grpc-dc-dart. DO NOT EDIT.\n"
                 (format "// source: ~a\n\n" (hash-ref file-model 'name))
                 "import 'dart:convert';\n"
                 "import 'dart:ffi';\n"
                 "import 'dart:io';\n"
                 "import 'dart:typed_data';\n\n"
                 (format "final Uint8List structdcDescriptor = Uint8List.fromList([~a]);\n\n" descriptor)
                 "typedef _TranscodeNative = Int32 Function(Pointer<Uint8>, Size, Pointer<Uint8>, Size, Pointer<Uint8>, Size, Pointer<Pointer<Uint8>>, Pointer<Size>, Pointer<Pointer<Uint8>>);\n"
                 "typedef _TranscodeDart = int Function(Pointer<Uint8>, int, Pointer<Uint8>, int, Pointer<Uint8>, int, Pointer<Pointer<Uint8>>, Pointer<Size>, Pointer<Pointer<Uint8>>);\n"
                 "typedef _FreeNative = Void Function(Pointer<Uint8>, Size);\n"
                 "typedef _FreeDart = void Function(Pointer<Uint8>, int);\n"
                 "typedef _ErrFreeNative = Void Function(Pointer<Uint8>);\n"
                 "typedef _ErrFreeDart = void Function(Pointer<Uint8>);\n"
                 "typedef _MallocNative = Pointer<Void> Function(Size);\n"
                 "typedef _MallocDart = Pointer<Void> Function(int);\n"
                 "typedef _LibcFreeNative = Void Function(Pointer<Void>);\n"
                 "typedef _LibcFreeDart = void Function(Pointer<Void>);\n\n"
                 "final _malloc = DynamicLibrary.open('libc.so.6').lookupFunction<_MallocNative, _MallocDart>('malloc');\n"
                 "final _libcFree = DynamicLibrary.open('libc.so.6').lookupFunction<_LibcFreeNative, _LibcFreeDart>('free');\n"
                 "Pointer<Uint8> _allocBytes(int n) => _malloc(n).cast<Uint8>();\n\n"
                 "DynamicLibrary _structdcLib() {\n"
                 "  final path = Platform.environment['GRPCDC_STRUCTDC_LIB'];\n"
                 "  return DynamicLibrary.open((path != null && path.isNotEmpty) ? path : 'libgrpc_dc.so');\n"
                 "}\n\n"
                 "/// One protobuf <-> struct transcode through the shared\n"
                 "/// Rust struct codec (libgrpc_dc).\n"
                 "Uint8List structdcTranscode(bool encode, String typeName, Uint8List input) {\n"
                 "  final lib = _structdcLib();\n"
                 "  final fn = lib.lookupFunction<_TranscodeNative, _TranscodeDart>(encode ? 'grpcdc_struct_encode' : 'grpcdc_struct_decode');\n"
                 "  final freeFn = lib.lookupFunction<_FreeNative, _FreeDart>('grpcdc_struct_free');\n"
                 "  final errFreeFn = lib.lookupFunction<_ErrFreeNative, _ErrFreeDart>('grpcdc_struct_error_free');\n"
                 "  final typeBytes = utf8.encode(typeName);\n"
                 "  final descPtr = _allocBytes(structdcDescriptor.length);\n"
                 "  final typePtr = _allocBytes(typeBytes.length);\n"
                 "  final inPtr = _allocBytes(input.length);\n"
                 "  final outPtr = _malloc(sizeOf<Pointer<Uint8>>()).cast<Pointer<Uint8>>();\n"
                 "  final outLenPtr = _malloc(sizeOf<Size>()).cast<Size>();\n"
                 "  final errPtr = _malloc(sizeOf<Pointer<Uint8>>()).cast<Pointer<Uint8>>();\n"
                 "  try {\n"
                 "    descPtr.asTypedList(structdcDescriptor.length).setAll(0, structdcDescriptor);\n"
                 "    typePtr.asTypedList(typeBytes.length).setAll(0, typeBytes);\n"
                 "    inPtr.asTypedList(input.length).setAll(0, input);\n"
                 "    final rc = fn(descPtr, structdcDescriptor.length, typePtr, typeBytes.length, inPtr, input.length, outPtr, outLenPtr, errPtr);\n"
                 "    if (rc != 0) {\n"
                 "      var msg = 'struct codec transcode failed';\n"
                 "      if (errPtr.value != nullptr) { final eb = <int>[]; for (var i = 0; errPtr.value[i] != 0; i++) { eb.add(errPtr.value[i]); } msg = utf8.decode(eb); errFreeFn(errPtr.value); }\n"
                 "      throw StateError(msg);\n"
                 "    }\n"
                 "    final result = Uint8List.fromList(outPtr.value.asTypedList(outLenPtr.value));\n"
                 "    freeFn(outPtr.value, outLenPtr.value);\n"
                 "    return result;\n"
                 "  } finally {\n"
                 "    _libcFree(descPtr.cast<Void>()); _libcFree(typePtr.cast<Void>()); _libcFree(inPtr.cast<Void>());\n"
                 "    _libcFree(outPtr.cast<Void>()); _libcFree(outLenPtr.cast<Void>()); _libcFree(errPtr.cast<Void>());\n"
                 "  }\n"
                 "}\n")))
        (define comps (list bridge))
        (define (emit-comp msg)
          (unless (hash-ref msg 'map-entry)
            (set! comps
                  (cons (cons (string-append (dt-struct-type-name file-model msg) "StructStub.dart")
                              (string-append
                               "// @generated by protoc-gen-grpc-dc-dart. DO NOT EDIT.\n"
                               (format "// source: ~a\n\n" (hash-ref file-model 'name))
                               "import 'dart:typed_data';\n\n"
                               (format "import '~a_messages.dart';\n\n" base)
                               (let ([tn (dt-struct-type-name file-model msg)])
                                 (format "class ~aStruct {\n  static int size(~a m) => throw UnsupportedError('struct codec unavailable on this platform');\n  static Uint8List marshal(~a m) => throw UnsupportedError('struct codec unavailable on this platform');\n  static ~a unmarshal(Uint8List data) => throw UnsupportedError('struct codec unavailable on this platform');\n}\n" tn tn tn tn))))
                        comps))
            (set! comps
                  (cons (cons (string-append (dt-struct-type-name file-model msg) "Struct.dart")
                              (string-append
                               "// @generated by protoc-gen-grpc-dc-dart. DO NOT EDIT.\n"
                               (format "// source: ~a\n\n" (hash-ref file-model 'name))
                               "import 'dart:convert';\nimport 'dart:typed_data';\n\n"
                               (format "import '~a_messages.dart';\n" base)
                               (format "import '~a_structdc.dart';\n" base)
                               (dt-struct-imports file-model msg base)
                               "\n"
                               (dt-struct-message file-model msg)))
                        comps)))
          (for ([n (in-list (hash-ref msg 'nested))]) (emit-comp n)))
        (for ([m (in-list (hash-ref file-model 'messages))]) (emit-comp m))
        (reverse comps))
      '()))
