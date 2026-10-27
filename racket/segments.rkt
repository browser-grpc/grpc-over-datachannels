#lang racket

;;; segments.rkt -- shared emitter segments: template emission
;;; expressed as data, interpreted twice (WEBGEN-SINGLESOURCE-
;;; SPEC option 1). A segment program is a list of nodes:
;;;
;;;   "text"                      literal output
;;;   (fmt "template" expr ...)   Racket format over the exprs
;;;                               (~a display, ~s write); the JS
;;;                               interpreter substitutes ~a as
;;;                               String(v), ~s as JSON string
;;;   (ref name)                  field `name` of the current
;;;                               model node; (ref impl-name) is
;;;                               the method-impl-name rule
;;;                               (impl-name field, else name)
;;;   (svc)                       the enclosing service name
;;;                               (the template's parameter)
;;;   (kind-case (kind seg ...) ...)
;;;                               dispatch on (ref kind)
;;;   (when (ref key) seg ...)    segs when field `key` is true
;;;   (call Name)                 run program Name on this node
;;;   (each field seg ...)        run segs per element of the
;;;                               list field, element as node
;;;   (each+ field client|server seg ...)
;;;                               like each, with the service's
;;;                               alias methods appended
;;;                               (node must be a service)
;;;
;;; The Racket interpreter below runs the native templates; the
;;; same datum is serialized by webgen.rkt into the browser
;;; generators (SEGMENT_PROGRAMS) with a JS interpreter, so the
;;; emission exists exactly once. Programs are rolled out one
;;; emitter function at a time; unconverted functions stay
;;; hand-mirrored and parity-pinned.

(require "spec.rkt" "desc.rkt")

(provide go-register-method-program go-deprecated-program
         go-client-method-program go-server-iface-method-program
         go-server-iface-method-deprecated-program
         go-stream-ifaces-program go-stream-impls-program
         go-service-program segment-programs run-segments
         js-deprecated-program js-client-method-program
         js-method-table-entry-program js-service-program
         js-pb-varint-expr-program js-pb-varint-decode-program
         js-pb-explicit-literal-program js-pb-default-program
         js-pb-set-expr-program js-pb-oneof-clearing-program
         js-pb-encode-singular-program js-pb-encode-field-program
         js-pb-decode-singular-program js-pb-decode-case-program
         js-pb-map-helpers-program js-pb-enum-const-program
         js-pb-message-program
         wasm-swift-client-method-program wasm-swift-server-iface-method-program
         wasm-swift-serve-export-program wasm-swift-stream-iface-method-program
         wasm-swift-stream-feed-export-program wasm-swift-service-program
         wasm-go-client-method-program wasm-go-server-iface-method-program
         wasm-go-register-method-program wasm-go-stream-iface-method-program
         wasm-go-stream-register-method-program wasm-go-service-program
         wasm-kotlin-client-method-program wasm-kotlin-server-iface-method-program
         wasm-kotlin-register-method-program wasm-kotlin-stream-iface-method-program
         wasm-kotlin-stream-register-method-program wasm-kotlin-service-program)

;; ---------------------------------------------------------------------------
;; Go stub: RegisterMethod handler table entries (one per method).
;; Mirrors template-go.rkt's go-register-method case dispatch.
;; ---------------------------------------------------------------------------

(define go-register-method-program
  '((kind-case
     (unary
      (fmt "\t\t{Name: ~s, Path: ~s, Kind: grpcdc.KindUnary, Handler: func(ctx context.Context, reqs *grpcdc.RequestStream, sink grpcdc.ServerSink) error {\n\t\t\treq := new(~a)\n\t\t\tif err := reqs.RecvInto(req); err != nil {\n\t\t\t\treturn err\n\t\t\t}\n\t\t\tresp, err := srv.~a(ctx, req)\n\t\t\tif err != nil {\n\t\t\t\treturn err\n\t\t\t}\n\t\t\treturn sink.Send(resp.MarshalDC())\n\t\t}},\n"
           (ref name) (ref path) (ref input) (ref impl-name)))
     (server-streaming
      (fmt "\t\t{Name: ~s, Path: ~s, Kind: grpcdc.KindServerStreaming, Handler: func(ctx context.Context, reqs *grpcdc.RequestStream, sink grpcdc.ServerSink) error {\n\t\t\treq := new(~a)\n\t\t\tif err := reqs.RecvInto(req); err != nil {\n\t\t\t\treturn err\n\t\t\t}\n\t\t\treturn srv.~a(req, &~a~aServerImpl{ctx: ctx, sink: sink})\n\t\t}},\n"
           (ref name) (ref path) (ref input) (ref impl-name) (svc) (ref impl-name)))
     (client-streaming
      (fmt "\t\t{Name: ~s, Path: ~s, Kind: grpcdc.KindClientStreaming, Handler: func(ctx context.Context, reqs *grpcdc.RequestStream, sink grpcdc.ServerSink) error {\n\t\t\tstream := &~a~aServerImpl{ctx: ctx, reqs: reqs}\n\t\t\tif err := srv.~a(stream); err != nil {\n\t\t\t\treturn err\n\t\t\t}\n\t\t\tif stream.resp == nil {\n\t\t\t\treturn grpcdc.NewStatus(grpcdc.CodeInternal, \"client-streaming handler never called SendAndClose\")\n\t\t\t}\n\t\t\treturn sink.Send(stream.resp.MarshalDC())\n\t\t}},\n"
           (ref name) (ref path) (svc) (ref impl-name) (ref impl-name)))
     (bidi
      (fmt "\t\t{Name: ~s, Path: ~s, Kind: grpcdc.KindBidi, Handler: func(ctx context.Context, reqs *grpcdc.RequestStream, sink grpcdc.ServerSink) error {\n\t\t\treturn srv.~a(&~a~aServerImpl{ctx: ctx, reqs: reqs, sink: sink})\n\t\t}},\n"
           (ref name) (ref path) (ref impl-name) (svc) (ref impl-name))))))

;; ---------------------------------------------------------------------------
;; Go stub: the remaining service-assembly programs.
;; ---------------------------------------------------------------------------

(define go-deprecated-program
  '((when (ref deprecated)
      "// Deprecated: marked deprecated in the proto schema.\n")))

(define go-client-method-program
  '((kind-case
     (unary
      (fmt "func (c *~aClient) ~a(ctx context.Context, req *~a) (*~a, error) {\n\tresp := new(~a)\n\tif err := c.Channel.Unary(ctx, ~s, req, resp); err != nil {\n\t\treturn nil, err\n\t}\n\treturn resp, nil\n}\n"
           (svc) (ref name) (ref input) (ref output) (ref output) (ref path)))
     (server-streaming
      (fmt "func (c *~aClient) ~a(ctx context.Context, req *~a) (*~a~aStream, error) {\n\tstream, err := c.Channel.ServerStream(ctx, ~s, req)\n\tif err != nil {\n\t\treturn nil, err\n\t}\n\treturn &~a~aStream{stream: stream}, nil\n}\n\ntype ~a~aStream struct{ stream *grpcdc.ClientStream }\n\nfunc (s *~a~aStream) Recv() (*~a, error) {\n\tresp := new(~a)\n\tif err := s.stream.Recv(resp); err != nil {\n\t\treturn nil, err\n\t}\n\treturn resp, nil\n}\n"
           (svc) (ref name) (ref input) (svc) (ref name) (ref path) (svc) (ref name) (svc) (ref name) (svc) (ref name) (ref output) (ref output)))
     (client-streaming
      (fmt "func (c *~aClient) ~a(ctx context.Context, reqs ...*~a) (*~a, error) {\n\tgrpcdcReqs := make([]grpcdc.Marshaler, len(reqs))\n\tfor i, r := range reqs {\n\t\tgrpcdcReqs[i] = r\n\t}\n\tresp := new(~a)\n\tif err := c.Channel.ClientStreamCall(ctx, ~s, grpcdcReqs, resp); err != nil {\n\t\treturn nil, err\n\t}\n\treturn resp, nil\n}\n"
           (svc) (ref name) (ref input) (ref output) (ref output) (ref path)))
     (bidi
      (fmt "func (c *~aClient) ~a(ctx context.Context, reqs ...*~a) (*~a~aStream, error) {\n\tgrpcdcReqs := make([]grpcdc.Marshaler, len(reqs))\n\tfor i, r := range reqs {\n\t\tgrpcdcReqs[i] = r\n\t}\n\tstream, err := c.Channel.Bidi(ctx, ~s, grpcdcReqs)\n\tif err != nil {\n\t\treturn nil, err\n\t}\n\treturn &~a~aStream{stream: stream}, nil\n}\n\ntype ~a~aStream struct{ stream *grpcdc.ClientStream }\n\nfunc (s *~a~aStream) Recv() (*~a, error) {\n\tresp := new(~a)\n\tif err := s.stream.Recv(resp); err != nil {\n\t\treturn nil, err\n\t}\n\treturn resp, nil\n}\n"
           (svc) (ref name) (ref input) (svc) (ref name) (ref path) (svc) (ref name) (svc) (ref name) (svc) (ref name) (ref output) (ref output))))))

(define go-server-iface-method-program
  '((kind-case
     (unary (fmt "\t~a(context.Context, *~a) (*~a, error)\n" (ref name) (ref input) (ref output)))
     (server-streaming (fmt "\t~a(*~a, ~a~aServer) error\n" (ref name) (ref input) (svc) (ref name)))
     (client-streaming (fmt "\t~a(~a~aServer) error\n" (ref name) (svc) (ref name)))
     (bidi (fmt "\t~a(~a~aServer) error\n" (ref name) (svc) (ref name))))))

(define go-server-iface-method-deprecated-program
  '((when (ref deprecated)
      "\t// Deprecated: marked deprecated in the proto schema.\n")
    (call goServerIfaceMethod)))

(define go-stream-ifaces-program
  '((kind-case
     (unary)
     (server-streaming
      (fmt "type ~a~aServer interface {\n\tSend(*~a) error\n\tContext() context.Context\n}\n\n"
           (svc) (ref name) (ref output)))
     (client-streaming
      (fmt "type ~a~aServer interface {\n\tRecv() (*~a, error)\n\tSendAndClose(*~a) error\n\tContext() context.Context\n}\n\n"
           (svc) (ref name) (ref input) (ref output)))
     (bidi
      (fmt "type ~a~aServer interface {\n\tSend(*~a) error\n\tRecv() (*~a, error)\n\tContext() context.Context\n}\n\n"
           (svc) (ref name) (ref output) (ref input))))))

(define go-stream-impls-program
  '((kind-case
     (unary)
     (server-streaming
      (fmt "type ~a~aServerImpl struct {\n\tctx  context.Context\n\tsink grpcdc.ServerSink\n}\n\nfunc (s *~a~aServerImpl) Send(resp *~a) error {\n\treturn s.sink.Send(resp.MarshalDC())\n}\nfunc (s *~a~aServerImpl) Context() context.Context { return s.ctx }\n\n"
           (svc) (ref name) (svc) (ref name) (ref output) (svc) (ref name)))
     (client-streaming
      (fmt "type ~a~aServerImpl struct {\n\tctx  context.Context\n\treqs *grpcdc.RequestStream\n\tresp *~a\n}\n\nfunc (s *~a~aServerImpl) Recv() (*~a, error) {\n\treq := new(~a)\n\tif err := s.reqs.RecvInto(req); err != nil {\n\t\treturn nil, err\n\t}\n\treturn req, nil\n}\nfunc (s *~a~aServerImpl) SendAndClose(resp *~a) error {\n\ts.resp = resp\n\treturn nil\n}\nfunc (s *~a~aServerImpl) Context() context.Context { return s.ctx }\n\n"
           (svc) (ref name) (ref output) (svc) (ref name) (ref input) (ref input) (svc) (ref name) (ref output) (svc) (ref name)))
     (bidi
      (fmt "type ~a~aServerImpl struct {\n\tctx  context.Context\n\treqs *grpcdc.RequestStream\n\tsink grpcdc.ServerSink\n}\n\nfunc (s *~a~aServerImpl) Send(resp *~a) error {\n\treturn s.sink.Send(resp.MarshalDC())\n}\nfunc (s *~a~aServerImpl) Recv() (*~a, error) {\n\treq := new(~a)\n\tif err := s.reqs.RecvInto(req); err != nil {\n\t\treturn nil, err\n\t}\n\treturn req, nil\n}\nfunc (s *~a~aServerImpl) Context() context.Context { return s.ctx }\n\n"
           (svc) (ref name) (svc) (ref name) (ref output) (svc) (ref name) (ref input) (ref input) (svc) (ref name))))))

(define go-service-program
  '((fmt "type ~aClient struct {\n\tChannel *grpcdc.Channel\n}\n\n" (ref name))
    (fmt "func New~aClient(ch *grpcdc.Channel) *~aClient {\n\treturn &~aClient{Channel: ch}\n}\n\n"
         (ref name) (ref name) (ref name))
    (each+ methods client (call goDeprecated) (call goClientMethod))
    "\n"
    (fmt "type ~aServer interface {\n" (ref name))
    (each methods (call goServerIfaceMethodDeprecated))
    "}\n\n"
    (each methods (call goStreamIfaces))
    (each methods (call goStreamImpls))
    (fmt "func Register~aServer(s *grpcdc.Server, srv ~aServer) {\n" (ref name) (ref name))
    (fmt "\ts.RegisterService(grpcdc.ServiceDesc{\n\t\tName: ~s,\n\t\tMethods: []grpcdc.Method{\n"
         (ref full-name))
    (each+ methods server (call goRegisterMethod))
    "\t\t},\n\t})\n}\n"))

;; ---------------------------------------------------------------------------
;; Go pb emitter programs. Node conventions: field programs
;; take the field as node with (arg 0..) carrying the value /
;; target / source / indent strings the template functions
;; received; goPbEnum takes the registry entry with the type
;; name as (arg 0); goPbMapHelpers takes the map entry.
;; ---------------------------------------------------------------------------

(define go-pb-varint-expr-program
  '((case-on (type)
      ((8 (fmt "boolToUint64(~a)" (arg 0)))
       (17 (fmt "zz32(~a)" (arg 0)))
       (18 (fmt "zz64(~a)" (arg 0)))
       (5 (fmt "uint64(int64(~a))" (arg 0)))
       (14 (fmt "uint64(int64(~a))" (arg 0)))
       (else (fmt "uint64(~a)" (arg 0)))))))

(define go-pb-varint-decode-program
  '((case-on (type)
      ((5 (fmt "int32(~a)" (arg 0)))
       (14 (fmt "int32(~a)" (arg 0)))
       (13 (fmt "uint32(~a)" (arg 0)))
       (3 (fmt "int64(~a)" (arg 0)))
       (4 (arg 0))
       (8 (fmt "~a != 0" (arg 0)))
       (17 (fmt "unzz32(~a)" (arg 0)))
       (18 (fmt "unzz64(~a)" (arg 0)))))))

(define go-pb-fixed-encode-program
  '((case-on (fixed-name)
      (("Float32" (fmt "fixed32Bytes(pbFloat32Bits(~a))" (arg 0)))
       ("Float64" (fmt "fixed64Bytes(pbFloat64Bits(~a))" (arg 0)))
       ("Uint32" (fmt "fixed32Bytes(~a)" (arg 0)))
       ("Int32" (fmt "fixed32Bytes(uint32(~a))" (arg 0)))
       ("BigUint64" (fmt "fixed64Bytes(~a)" (arg 0)))
       ("BigInt64" (fmt "fixed64Bytes(uint64(~a))" (arg 0)))))))

(define go-pb-fixed-decode-program
  '((case-on (fixed-name)
      (("Float32" (fmt "pbFloat32FromBits(binary.LittleEndian.Uint32(~a))" (arg 0)))
       ("Float64" (fmt "pbFloat64FromBits(binary.LittleEndian.Uint64(~a))" (arg 0)))
       ("Uint32" (fmt "binary.LittleEndian.Uint32(~a)" (arg 0)))
       ("Int32" (fmt "int32(binary.LittleEndian.Uint32(~a))" (arg 0)))
       ("BigUint64" (fmt "binary.LittleEndian.Uint64(~a)" (arg 0)))
       ("BigInt64" (fmt "int64(binary.LittleEndian.Uint64(~a))" (arg 0)))))))

(define go-pb-zero-program
  '((case-on (type)
      ((11 "nil")
       (12 "nil")
       (9 "\"\"")
       (8 "false")
       (else "0")))))

(define go-pb-encode-singular-program
  '((case-on (category)
      (("varint"
        (if (proto2)
            (then (fmt "~aout = appendTag(out, ~a, 0)\n" (arg 1) (ref number))
                  (fmt "~aout = appendVarint(out, ~a)\n" (arg 1) (call goPbVarintExpr (arg 0))))
            (else (fmt "~aif ~a {\n" (arg 1) (if (type-is 8) (then (arg 0)) (else (fmt "~a != 0" (arg 0)))))
                  (fmt "~a\tout = appendTag(out, ~a, 0)\n" (arg 1) (ref number))
                  (fmt "~a\tout = appendVarint(out, ~a)\n" (arg 1) (call goPbVarintExpr (arg 0)))
                  (fmt "~a}\n" (arg 1))))))
       ("fixed"
        (if (proto2)
            (then (fmt "~aout = appendTag(out, ~a, ~a)\n" (arg 1) (ref number) (fixed-wire))
                  (fmt "~aout = append(out, ~a...)\n" (arg 1) (call goPbFixedEncode (arg 0))))
            (else (fmt "~aif ~a != 0 {\n" (arg 1) (arg 0))
                  (fmt "~a\tout = appendTag(out, ~a, ~a)\n" (arg 1) (ref number) (fixed-wire))
                  (fmt "~a\tout = append(out, ~a...)\n" (arg 1) (call goPbFixedEncode (arg 0)))
                  (fmt "~a}\n" (arg 1)))))
       ("string"
        (if (proto2)
            (then (fmt "~aout = appendBytesField(out, ~a, []byte(~a))\n" (arg 1) (ref number) (arg 0)))
            (else (fmt "~aout = appendStringField(out, ~a, ~a)\n" (arg 1) (ref number) (arg 0)))))
       ("bytes"
        (if (proto2)
            (then (fmt "~aout = appendBytesField(out, ~a, ~a)\n" (arg 1) (ref number) (arg 0)))
            (else (fmt "~aif len(~a) > 0 {\n~a\tout = appendBytesField(out, ~a, ~a)\n~a}\n"
                       (arg 1) (arg 0) (arg 1) (ref number) (arg 0) (arg 1)))))
       ("message"
        (fmt "~aif ~a != nil {\n~a\tout = appendBytesField(out, ~a, ~a.MarshalDC())\n~a}\n"
             (arg 1) (arg 0) (arg 1) (ref number) (arg 0) (arg 1)))
       (else (fail)))))

(define go-pb-encode-field-program
  '((if (is-map)
        (then (fmt "\t{\n\t\tkeys := make([]~a, 0, len(~a))\n\t\tfor k := range ~a { keys = append(keys, k) }\n\t\tsort.Slice(keys, func(i, j int) bool { return keys[i] < keys[j] })\n\t\tfor _, k := range keys {\n\t\t\tout = appendBytesField(out, ~a, ~a(k, ~a[k]))\n\t\t}\n\t}\n"
                   (field-type-of (with-label (key-field (resolved-entry)) 1))
                   (fmt "m.~a" (pascal (ref name)))
                   (fmt "m.~a" (pascal (ref name)))
                   (ref number)
                   (fmt "encode~a" (entry-type))
                   (fmt "m.~a" (pascal (ref name)))))
        (else
         (if (repeated)
             (then (case-on (category)
                     (("varint"
                       (fmt "\tif len(~a) > 0 {\n\t\tvar payload []byte\n" (fmt "m.~a" (pascal (ref name))))
                       (fmt "\t\tfor _, x := range ~a {\n\t\t\tpayload = appendVarint(payload, ~a)\n\t\t}\n"
                            (fmt "m.~a" (pascal (ref name))) (call goPbVarintExpr "x"))
                       (fmt "\t\tout = appendBytesField(out, ~a, payload)\n\t}\n" (ref number)))
                      ("fixed"
                       (fmt "\tif len(~a) > 0 {\n\t\tvar payload []byte\n" (fmt "m.~a" (pascal (ref name))))
                       (fmt "\t\tfor _, x := range ~a {\n\t\t\tpayload = append(payload, ~a...)\n\t\t}\n"
                            (fmt "m.~a" (pascal (ref name))) (call goPbFixedEncode "x"))
                       (fmt "\t\tout = appendBytesField(out, ~a, payload)\n\t}\n" (ref number)))
                      ("string"
                       (fmt "\tfor _, x := range ~a {\n\t\tout = appendBytesField(out, ~a, []byte(x))\n\t}\n"
                            (fmt "m.~a" (pascal (ref name))) (ref number)))
                      ("bytes"
                       (fmt "\tfor _, x := range ~a {\n\t\tout = appendBytesField(out, ~a, x)\n\t}\n"
                            (fmt "m.~a" (pascal (ref name))) (ref number)))
                      ("message"
                       (fmt "\tfor _, x := range ~a {\n\t\tout = appendBytesField(out, ~a, x.MarshalDC())\n\t}\n"
                            (fmt "m.~a" (pascal (ref name))) (ref number)))
                      (else (fail)))))
             (else (call goPbEncodeSingular (fmt "m.~a" (pascal (ref name))) "\t")))))))

(define go-pb-decode-singular-program
  '((case-on (category)
      (("varint"
        (fmt "~a~a = ~a\n" (arg 2) (arg 0)
             (if (type-is 14)
                 (then (fmt "~a(~a)" (entry-type) (call goPbVarintDecode (arg 1))))
                 (else (call goPbVarintDecode (arg 1))))))
       ("fixed"
        (fmt "~a~a = ~a\n" (arg 2) (arg 0) (call goPbFixedDecode (arg 1))))
       ("string"
        (fmt "~a~a = string(~a)\n" (arg 2) (arg 0) (arg 1)))
       ("bytes"
        (fmt "~a~a = append([]byte(nil), ~a...)\n" (arg 2) (arg 0) (arg 1)))
       ("message"
        (fmt "~atmp~a := new(~a)\n" (arg 2) (ref number) (entry-type))
        (fmt "~aif err := tmp~a.UnmarshalDC(~a); err != nil {\n~a\t~a\n~a}\n"
             (arg 2) (ref number) (arg 1) (arg 2) (err-stmt) (arg 2))
        (fmt "~a~a = tmp~a\n" (arg 2) (arg 0) (ref number)))
       (else (fail))))))

(define go-pb-decode-case-program
  '((fmt "\t\tcase ~a:\n" (ref number))
    (if (is-map)
        (then "\t\t\tif b, ok := value.([]byte); ok {\n"
              (fmt "\t\t\t\tk, val, err := ~a(b)\n" (fmt "decode~a" (entry-type)))
              "\t\t\t\tif err != nil {\n\t\t\t\t\treturn err\n\t\t\t\t}\n"
              (fmt "\t\t\t\tif ~a == nil {\n\t\t\t\t\t~a = make(~a)\n\t\t\t\t}\n"
                   (fmt "m.~a" (pascal (ref name))) (fmt "m.~a" (pascal (ref name))) (field-type))
              (fmt "\t\t\t\t~a[k] = val\n\t\t\t}\n" (fmt "m.~a" (pascal (ref name)))))
        (else
         (if (repeated)
             (then (case-on (category)
                     (("varint"
                       "\t\t\tswitch value := value.(type) {\n"
                       "\t\t\tcase uint64:\n"
                       (fmt "\t\t\t\t~a = append(~a, ~a)\n"
                            (fmt "m.~a" (pascal (ref name))) (fmt "m.~a" (pascal (ref name)))
                            (if (type-is 14)
                                (then (fmt "~a(~a)" (entry-type) (call goPbVarintDecode "value")))
                                (else (call goPbVarintDecode "value"))))
                       "\t\t\tcase []byte:\n"
                       "\t\t\t\tsub := &pbReader{buf: value}\n"
                       "\t\t\t\tfor sub.pos < len(sub.buf) {\n"
                       "\t\t\t\t\tv, err := sub.varint()\n\t\t\t\t\tif err != nil {\n\t\t\t\t\t\treturn err\n\t\t\t\t\t}\n"
                       (fmt "\t\t\t\t\t~a = append(~a, ~a)\n"
                            (fmt "m.~a" (pascal (ref name))) (fmt "m.~a" (pascal (ref name)))
                            (if (type-is 14)
                                (then (fmt "~a(~a)" (entry-type) (call goPbVarintDecode "v")))
                                (else (call goPbVarintDecode "v"))))
                       "\t\t\t\t}\n\t\t\t}\n")
                      ("fixed"
                       "\t\t\tif b, ok := value.([]byte); ok {\n"
                       (fmt "\t\t\t\tif len(b) == ~a {\n" (fixed-size))
                       (fmt "\t\t\t\t\t~a = append(~a, ~a)\n"
                            (fmt "m.~a" (pascal (ref name))) (fmt "m.~a" (pascal (ref name)))
                            (call goPbFixedDecode "b"))
                       "\t\t\t\t} else {\n"
                       (fmt "\t\t\t\t\tfor off := 0; off+~a <= len(b); off += ~a {\n" (fixed-size) (fixed-size))
                       (fmt "\t\t\t\t\t\t~a = append(~a, ~a)\n"
                            (fmt "m.~a" (pascal (ref name))) (fmt "m.~a" (pascal (ref name)))
                            (call goPbFixedDecode (fmt "b[off:off+~a]" (fixed-size))))
                       "\t\t\t\t\t}\n\t\t\t\t}\n\t\t\t}\n")
                      ("string"
                       (fmt "\t\t\tif b, ok := value.([]byte); ok {\n\t\t\t\t~a = append(~a, string(b))\n\t\t\t}\n"
                            (fmt "m.~a" (pascal (ref name))) (fmt "m.~a" (pascal (ref name)))))
                      ("bytes"
                       (fmt "\t\t\tif b, ok := value.([]byte); ok {\n\t\t\t\t~a = append(~a, append([]byte(nil), b...))\n\t\t\t}\n"
                            (fmt "m.~a" (pascal (ref name))) (fmt "m.~a" (pascal (ref name)))))
                      ("message"
                       "\t\t\tif b, ok := value.([]byte); ok {\n"
                       (fmt "\t\t\t\tvar tmpv ~a\n" (field-type-of (with-label (self) 1)))
                       (call goPbDecodeSingular "tmpv" "b" "\t\t\t\t")
                       (fmt "\t\t\t\t~a = append(~a, tmpv)\n\t\t\t}\n"
                            (fmt "m.~a" (pascal (ref name))) (fmt "m.~a" (pascal (ref name)))))
                      (else (fail)))))
             (else (oneof-clearing)
                   (if (is-varint)
                       (then (fmt "\t\t\tif v, ok := value.(uint64); ok {\n~a\t\t\t}\n"
                                  (call goPbDecodeSingular (fmt "m.~a" (pascal (ref name))) "v" "\t\t\t\t")))
                       (else (fmt "\t\t\tif b, ok := value.([]byte); ok {\n~a\t\t\t}\n"
                                  (call goPbDecodeSingular (fmt "m.~a" (pascal (ref name))) "b" "\t\t\t\t"))))))))))

(define go-pb-encode-field-guarded-program
  '((guarded goPbSetExpr "\tif !(~a) {\n" "\t}\n" (call goPbEncodeField))))

(define go-pb-set-expr-program
  '((case-on (type)
      ((11 10) (fmt "m.~a != nil" (pascal (ref name))))
      (9 (fmt "m.~a != \"\"" (pascal (ref name))))
      (12 (fmt "len(m.~a) > 0" (pascal (ref name))))
      (8 (fmt "m.~a" (pascal (ref name))))
      (else (fmt "m.~a != ~a" (pascal (ref name)) (call goPbZero))))))

(define go-pb-map-helpers-program
  '((fmt "func encode~a(key ~a, value ~a) []byte {\n\tvar out []byte\n"
         (entry-type)
         (field-type-of (with-label (key-field) 1))
         (field-type-of (with-label (val-field) 1)))
    (call-on (key-field) goPbEncodeSingular "key" "\t")
    (call-on (val-field) goPbEncodeSingular "value" "\t")
    "\treturn out\n}\n\n"
    (fmt "func decode~a(data []byte) (~a, ~a, error) {\n"
         (entry-type)
         (field-type-of (with-label (key-field) 1))
         (field-type-of (with-label (val-field) 1)))
    (fmt "\tvar key ~a\n\tvar value ~a\n"
         (field-type-of (with-label (key-field) 1))
         (field-type-of (with-label (val-field) 1)))
    "\tr := &pbReader{buf: data}\n\tfor {\n\t\tnum, _, value0, _, done, err := r.field()\n\t\tif err != nil {\n\t\t\treturn key, value, err\n\t\t}\n\t\tif done {\n\t\t\treturn key, value, nil\n\t\t}\n\t\tswitch num {\n"
    (fmt "\t\tcase ~a:\n" (get (key-field) number))
    (case-on (category-of (key-field))
      (("varint" (fmt "\t\t\tif v, ok := value0.(uint64); ok {\n~a\t\t\t}\n"
                      (call-on (key-field) goPbDecodeSingular "key" "v" "\t\t\t\t")))
       (else (fmt "\t\t\tif b, ok := value0.([]byte); ok {\n~a\t\t\t}\n"
                  (call-on (key-field) goPbDecodeSingular "key" "b" "\t\t\t\t")))))
    (fmt "\t\tcase ~a:\n" (get (val-field) number))
    (case-on (category-of (val-field))
      (("varint" (fmt "\t\t\tif v, ok := value0.(uint64); ok {\n~a\t\t\t}\n"
                      (call-on (val-field) goPbDecodeSingular "value" "v" "\t\t\t\t")))
       (else (fmt "\t\t\tif b, ok := value0.([]byte); ok {\n~a\t\t\t}\n"
                  (call-on (val-field) goPbDecodeSingular "value" "b" "\t\t\t\t")))))
    "\t\t}\n\t}\n}\n\n"))

(define go-pb-enum-program
  '((fmt "type ~a int32\n\nconst (\n" (arg 0))
    (each enum values
          (fmt "\t~a_~a ~a = ~a\n" (arg 0) (ref name) (arg 0) (ref number)))
    ")\n\n"))

(define go-pb-default-literal-program
  '((if (has-default)
        (then (case-on (type)
                ((9 (fmt "~s" (default-raw)))
                 (14 (fmt "~a(~a)" (entry-type) (enum-default-num)))
                 (else (default-raw)))))
        (else))))

(define go-pb-constructor-program
  '((if (any-default)
        (then (fmt "// New~a returns a ~a with the descriptor's explicit (proto2)\n// default values applied.\n" (flat) (flat))
              (fmt "func New~a() *~a {\n\treturn &~a{\n" (flat) (flat) (flat))
              (each fields
                    (when (has-default)
                      (fmt "\t~a: ~a,\n" (pascal (ref name)) (call goPbDefaultLiteral))))
              "\t}\n}\n\n")
        (else))))

(define go-pb-message-program
  '((fmt "type ~a struct {\n" (flat))
    (each fields (fmt "\t~a ~a\n" (pascal (ref name)) (field-type)))
    "\tUnknownFields []byte\n}\n\n"
    (call goPbConstructor)
    (fmt "func (m *~a) MarshalDC() []byte {\n\tvar out []byte\n" (flat))
    (each fields (call goPbEncodeFieldGuarded))
    "\tout = append(out, m.UnknownFields...)\n\treturn out\n}\n\n"
    (fmt "func (m *~a) UnmarshalDC(data []byte) error {\n" (flat))
    "\tm.UnknownFields = nil\n\tr := &pbReader{buf: data}\n\tfor {\n"
    (if (no-fields)
        (then "\t\tnum, _, _, raw, done, err := r.field()\n")
        (else "\t\tnum, _, value, raw, done, err := r.field()\n"))
    "\t\tif err != nil {\n\t\t\treturn err\n\t\t}\n\t\tif done {\n\t\t\treturn nil\n\t\t}\n\t\tswitch num {\n"
    (each fields (call goPbDecodeCase))
    "\t\tdefault:\n\t\t\tm.UnknownFields = append(m.UnknownFields, raw...)\n\t\t}\n\t}\n}\n\n"))

;; ---------------------------------------------------------------------------
;; JS stub emitter (mirrors template-js.rkt).
;; ---------------------------------------------------------------------------

(define js-deprecated-program
  '((when (ref deprecated)
      (fmt "~a/** @deprecated deprecated in the proto schema */\n" (arg 0)))))

(define js-client-method-program
  '((call jsDeprecated "  ")
    (kind-case
     (unary (fmt "  async ~a(request, options) {\n    return this.#channel.unary(~s, request, ~a, ~a, options);\n  }\n"
                 (lower-first (ref name)) (ref path) (ref input) (ref output)))
     (server-streaming (fmt "  ~a(request, options) {\n    return this.#channel.serverStream(~s, request, ~a, ~a, options);\n  }\n"
                            (lower-first (ref name)) (ref path) (ref input) (ref output)))
     (client-streaming (fmt "  async ~a(requests, options) {\n    return this.#channel.clientStream(~s, requests, ~a, ~a, options);\n  }\n"
                            (lower-first (ref name)) (ref path) (ref input) (ref output)))
     (bidi (fmt "  ~a(requests, options) {\n    return this.#channel.bidi(~s, requests, ~a, ~a, options);\n  }\n"
                (lower-first (ref name)) (ref path) (ref input) (ref output))))))

(define js-method-table-entry-program
  '((fmt "    ~a: { path: ~s, kind: ~s, requestType: ~a, responseType: ~a, handler: handlers.~a },\n"
         (ref name) (ref path) (ref kind) (ref input) (ref output)
         (lower-first (ref impl-name)))))

(define js-service-program
  '((fmt "export class ~aClient {\n  #channel;\n  constructor(channel) { this.#channel = channel; }\n" (svc))
    (each+ methods client (call jsClientMethod))
    "}\n\n"
    (fmt "export function create~aService(handlers) {\n  return {\n    name: ~s,\n    methods: {\n"
         (svc) (ref full-name))
    (each+ methods server (call jsMethodTableEntry))
    "    },\n  };\n}\n"))

;; ---------------------------------------------------------------------------
;; JS pb emitter (mirrors template-js.rkt's js-pb-* functions).
;; ---------------------------------------------------------------------------

(define js-pb-varint-expr-program
  '((case-on (type)
      (8 (fmt "(~a ? 1n : 0n)" (arg 0)))
      (17 (fmt "BigInt(((~a << 1) ^ (~a >> 31)) >>> 0)" (arg 0) (arg 0)))
      (18 (fmt "zz64(~a)" (arg 0)))
      (else (fmt "BigInt(~a)" (arg 0))))))

(define js-pb-varint-decode-program
  '((case-on (type)
      ((5 14) (fmt "Number(BigInt.asIntN(32, ~a))" (arg 0)))
      (13 (fmt "Number(BigInt.asUintN(32, ~a))" (arg 0)))
      (3 (fmt "BigInt.asIntN(64, ~a)" (arg 0)))
      (4 (fmt "BigInt.asUintN(64, ~a)" (arg 0)))
      (8 (fmt "~a !== 0n" (arg 0)))
      (17 (fmt "Number(unzz64(BigInt.asUintN(32, ~a)))" (arg 0)))
      (18 (fmt "unzz64(~a)" (arg 0))))))

(define js-pb-explicit-literal-program
  '((if (has-default)
        (then (case-on (type)
                (9 (fmt "~s" (default-raw)))
                (14 (fmt "~a" (enum-default-num)))
                (else (default-raw))))
        (else ""))))

(define js-pb-default-program
  '((if (call jsPbExplicitLiteral)
        (then (call jsPbExplicitLiteral))
        (else
         (if (repeated)
             (then (if (is-map) (then "new Map()") (else "[]")))
             (else
              (case-on (type)
                (9 "\"\"")
                (12 "new Uint8Array(0)")
                (8 "false")
                ((11 10) "undefined")
                (else (if (bigint-type) (then "0n") (else "0"))))))))))

(define js-pb-set-expr-program
  '((case-on (type)
      ((11 10) (fmt "msg.~a" (js-name)))
      (9 (fmt "msg.~a !== \"\"" (js-name)))
      (12 (fmt "(msg.~a && msg.~a.length > 0)" (js-name) (js-name)))
      (8 (fmt "msg.~a" (js-name)))
      (else (fmt "msg.~a !== ~a" (js-name)
                 (if (bigint-type) (then "0n") (else "0")))))))

(define js-pb-oneof-clearing-program
  '((each-siblings (fmt "msg.~a = ~a; " (js-name) (call jsPbDefault)))))

(define js-pb-encode-singular-program
  '((case-on (category)
      ("varint"
       (if (proto2)
           (then (fmt "~aputTag(out, ~a, 0); out.push(...varintBytes(~a));\n"
                      (arg 1) (ref number) (call jsPbVarintExpr (arg 0))))
           (else (fmt "~aputVarintField(out, ~a, ~a);\n"
                      (arg 1) (ref number) (call jsPbVarintExpr (arg 0))))))
      ("fixed"
       (if (proto2)
           (then (fmt "~aputFixedField(out, ~a, fixedBytes(~a, ~a, (dv, x) => dv.set~a(0, x, true)));\n"
                      (arg 1) (ref number) (arg 0) (js-fixed-size) (js-fixed-name)))
           (else (fmt "~aif (~a) putFixedField(out, ~a, fixedBytes(~a, ~a, (dv, x) => dv.set~a(0, x, true)));\n"
                      (arg 1) (arg 0) (ref number) (arg 0) (js-fixed-size) (js-fixed-name)))))
      ("string"
       (if (proto2)
           (then (fmt "~aputBytesField(out, ~a, new TextEncoder().encode(~a));\n"
                      (arg 1) (ref number) (arg 0)))
           (else (fmt "~aputStringField(out, ~a, ~a);\n"
                      (arg 1) (ref number) (arg 0)))))
      ("bytes"
       (if (proto2)
           (then (fmt "~aputBytesField(out, ~a, ~a);\n" (arg 1) (ref number) (arg 0)))
           (else (fmt "~aif (~a && ~a.length) putBytesField(out, ~a, ~a);\n"
                      (arg 1) (arg 0) (arg 0) (ref number) (arg 0)))))
      ("message"
       (fmt "~aif (~a) putBytesField(out, ~a, ~a.encode(~a));\n"
            (arg 1) (arg 0) (ref number) (resolved-flat) (arg 0)))
      (else (fail)))))

(define js-pb-encode-field-program
  '((if (is-map)
        (then (fmt "    if (msg.~a) for (const [k, val] of msg.~a) putBytesField(out, ~a, ~aEncode(k, val));\n"
                   (js-name) (js-name) (ref number) (resolved-flat)))
        (else
         (if (repeated)
             (then
              (case-on (category)
                ("varint" (fmt "    if (msg.~a && msg.~a.length) {\n      const payload = [];\n      for (const x of msg.~a) payload.push(...varintBytes(~a));\n      putBytesField(out, ~a, payload);\n    }\n"
                               (js-name) (js-name) (js-name) (call jsPbVarintExpr "x") (ref number)))
                ("fixed" (fmt "    if (msg.~a && msg.~a.length) {\n      const payload = new Uint8Array(msg.~a.length * ~a);\n      const dv = new DataView(payload.buffer);\n      msg.~a.forEach((x, i) => dv.set~a(i * ~a, x, true));\n      putBytesField(out, ~a, payload);\n    }\n"
                              (js-name) (js-name) (js-name) (js-fixed-size) (js-name) (js-fixed-name) (js-fixed-size) (ref number)))
                ("string" (fmt "    if (msg.~a) for (const v of msg.~a) putBytesField(out, ~a, new TextEncoder().encode(v));\n"
                               (js-name) (js-name) (ref number)))
                ("bytes" (fmt "    if (msg.~a) for (const v of msg.~a) putBytesField(out, ~a, v);\n"
                              (js-name) (js-name) (ref number)))
                ("message" (fmt "    if (msg.~a) for (const v of msg.~a) putBytesField(out, ~a, ~a.encode(v));\n"
                                (js-name) (js-name) (ref number) (resolved-flat)))
                (else (fail))))
             (else (call jsPbEncodeSingular (fmt "msg.~a" (js-name)) "    ")))))))

(define js-pb-decode-singular-program
  '((case-on (category)
      ("varint" (fmt "~a = ~a;" (arg 0) (call jsPbVarintDecode (arg 1))))
      ("fixed" (fmt "~a = readFixed(~a, (dv) => dv.get~a(0, true));" (arg 0) (arg 1) (js-fixed-name)))
      ("string" (fmt "~a = new TextDecoder().decode(~a);" (arg 0) (arg 1)))
      ("bytes" (fmt "~a = ~a;" (arg 0) (arg 1)))
      ("message" (fmt "~a = ~a.decode(~a);" (arg 0) (resolved-flat) (arg 1)))
      (else (fail)))))

(define js-pb-decode-case-program
  '((if (is-map)
        (then (fmt "      case ~a: { const [k, val] = ~aDecode(value); msg.~a.set(k, val); break; }\n"
                   (ref number) (resolved-flat) (js-name)))
        (else
         (if (repeated)
             (then
              (case-on (category)
                ("varint" (fmt "      case ~a: ~aif (wire === 2) { const r = new Reader(value); while (!r.done) msg.~a.push(~a); } else msg.~a.push(~a); break;\n"
                               (ref number) (call jsPbOneofClearing) (js-name)
                               (call jsPbVarintDecode "r.varint()") (js-name)
                               (call jsPbVarintDecode "value")))
                ("fixed" (fmt "      case ~a: if (wire === 2) { const r = new Reader(value); while (!r.done) msg.~a.push(readFixed(r.take(~a), (dv) => dv.get~a(0, true))); } else msg.~a.push(readFixed(value, (dv) => dv.get~a(0, true))); break;\n"
                              (ref number) (js-name) (js-fixed-size) (js-fixed-name)
                              (js-name) (js-fixed-name)))
                (else (fmt "      case ~a: msg.~a.push(~a); break;\n"
                           (ref number) (js-name)
                           (case-on (category)
                             ("string" "new TextDecoder().decode(value)")
                             ("bytes" "value")
                             (else (fmt "~a.decode(value)" (resolved-flat))))))))
             (else (fmt "      case ~a: ~a~a break;\n"
                        (ref number) (call jsPbOneofClearing)
                        (call jsPbDecodeSingular (fmt "msg.~a" (js-name)) "value"))))))))

(define js-pb-map-helpers-program
  '((fmt "function ~aEncode(key, value) {\n  const out = [];\n" (entry-flat))
    (call-on (key-field) jsPbEncodeSingular "key" "  ")
    (call-on (val-field) jsPbEncodeSingular "value" "  ")
    "  return new Uint8Array(out);\n}\n\n"
    (fmt "function ~aDecode(bytes) {\n" (entry-flat))
    (fmt "  let key = ~a;\n  let value = ~a;\n"
         (call-on (key-field) jsPbDefault) (call-on (val-field) jsPbDefault))
    "  const reader = new Reader(bytes);\n  let f;\n  while ((f = reader.field()) !== null) {\n    const [num, wire, raw] = f;\n    switch (num) {\n"
    (fmt "      case ~a: ~a break;\n" (get (key-field) number)
         (call-on (key-field) jsPbDecodeSingular "key" "raw"))
    (fmt "      case ~a: ~a break;\n" (get (val-field) number)
         (call-on (val-field) jsPbDecodeSingular "value" "raw"))
    "    }\n  }\n  return [key, value];\n}\n\n"))

(define js-pb-enum-const-program
  '((fmt "export const ~a = { ~a };\n\n" (entry-flat)
         (each-sep ", " enum values (fmt "~a: ~a" (ref name) (ref number))))))

(define js-pb-message-program
  '((fmt "export class ~a {\n" (flat))
    (fmt "  constructor({ ~a } = {}) {\n"
         (each-sep ", " fields (fmt "~a = ~a" (js-name) (call jsPbDefault))))
    (each fields (fmt "    this.~a = ~a;\n" (js-name) (js-name)))
    "    this.unknownFields = new Uint8Array(0);\n  }\n  static encode(msg) {\n    const out = [];\n"
    (each fields (guarded jsPbSetExpr "    if (!(~a)) {\n" "    }\n" (call jsPbEncodeField)))
    "    putRaw(out, msg.unknownFields);\n    return new Uint8Array(out);\n  }\n"
    (fmt "  static decode(bytes) {\n    const msg = new ~a();\n" (flat))
    "    const reader = new Reader(bytes);\n    let f;\n    while ((f = reader.field()) !== null) {\n      const [num, wire, value, raw] = f;\n      switch (num) {\n"
    (each fields (call jsPbDecodeCase))
    "        default: msg.unknownFields = concatBytes(msg.unknownFields, raw); break;\n      }\n    }\n    return msg;\n  }\n}\n\n"))

;; ---------------------------------------------------------------------------
;; Wasm-Swift facade emitter (mirrors template-wasm-swift.rkt).
;; Serve/stream-feed programs take the enum name as (arg 0).
;; ---------------------------------------------------------------------------

(define wasm-swift-client-method-program
  '((kind-case
     (unary (fmt "        func ~a(_ req: ~a, _ callback: @escaping (Result<~a, StatusException>) -> Void) {\n            bridge.unary(~s, req.MarshalDc()) { result in\n                callback(result.map { bytes in\n                    let resp = ~a()\n                    resp.UnmarshalDc(bytes)\n                    return resp\n                })\n            }\n        }\n\n"
                 (ref name) (ref input) (ref output) (ref path) (ref output)))
     (server-streaming (fmt "        func ~a(_ req: ~a, _ onMessage: @escaping (~a) -> Void,\n                _ onDone: @escaping (StatusException?) -> Void) {\n            bridge.serverStream(~s, req.MarshalDc(), { bytes in\n                let resp = ~a()\n                resp.UnmarshalDc(bytes)\n                onMessage(resp)\n            }, onDone)\n        }\n\n"
                            (ref name) (ref input) (ref output) (ref path) (ref output)))
     (client-streaming (fmt "        func ~a(_ reqs: [~a], _ callback: @escaping (Result<~a, StatusException>) -> Void) {\n            bridge.clientStream(~s, reqs.map { $0.MarshalDc() }) { result in\n                callback(result.map { bytes in\n                    let resp = ~a()\n                    resp.UnmarshalDc(bytes)\n                    return resp\n                })\n            }\n        }\n\n"
                            (ref name) (ref input) (ref output) (ref path) (ref output)))
     (bidi (fmt "        func ~a(_ reqs: [~a], _ onMessage: @escaping (~a) -> Void,\n                _ onDone: @escaping (StatusException?) -> Void) {\n            bridge.bidi(~s, reqs.map { $0.MarshalDc() }, { bytes in\n                let resp = ~a()\n                resp.UnmarshalDc(bytes)\n                onMessage(resp)\n            }, onDone)\n        }\n\n"
                (ref name) (ref input) (ref output) (ref path) (ref output))))))

(define wasm-swift-server-iface-method-program
  '((kind-case
     (unary (fmt "        func ~a(_ req: ~a, _ metadata: [(String, String)]) -> Result<~a, StatusException>\n"
                 (ref name) (ref input) (ref output)))
     (server-streaming (fmt "        func ~a(_ req: ~a, _ metadata: [(String, String)], _ sink: ~aServerSink) -> StatusException?\n"
                            (ref name) (ref input) (svc)))
     (client-streaming (fmt "        func ~a(_ reqs: [~a], _ metadata: [(String, String)]) -> Result<~a, StatusException>\n"
                            (ref name) (ref input) (ref output)))
     (bidi (fmt "        func ~a(_ reqs: [~a], _ metadata: [(String, String)], _ sink: ~aServerSink) -> StatusException?\n"
                (ref name) (ref input) (svc))))))

(define wasm-swift-serve-export-program
  '((kind-case
     (unary (fmt "@_cdecl(~s)\npublic func ~a(_ callId: UInt32, _ payload: UnsafePointer<UInt8>, _ payloadLen: Int, _ md: UnsafePointer<UInt8>, _ mdLen: Int) {\n    let metadata = DecodeMetadata(Array(UnsafeBufferPointer(start: md, count: mdLen)))\n    let req = ~a()\n    req.UnmarshalDc(Array(UnsafeBufferPointer(start: payload, count: payloadLen)))\n    switch ~a.serverImpl!.~a(req, metadata) {\n    case .success(let resp): ServerRespond(callId, resp.MarshalDc())\n    case .failure(let st): ServerFail(callId, st)\n    }\n}\n\n"
                 (fmt "serve_~a" (lower-first (ref name))) (fmt "serve_~a" (lower-first (ref name)))
                 (ref input) (arg 0) (ref name)))
     (server-streaming (fmt "@_cdecl(~s)\npublic func ~a(_ callId: UInt32, _ payload: UnsafePointer<UInt8>, _ payloadLen: Int, _ md: UnsafePointer<UInt8>, _ mdLen: Int) {\n    let metadata = DecodeMetadata(Array(UnsafeBufferPointer(start: md, count: mdLen)))\n    let req = ~a()\n    req.UnmarshalDc(Array(UnsafeBufferPointer(start: payload, count: payloadLen)))\n    if let st = ~a.serverImpl!.~a(req, metadata, ~a.~aServerSink(callId: callId)) {\n        ServerFail(callId, st)\n    } else {\n        ServerComplete(callId)\n    }\n}\n\n"
                            (fmt "serve_~a" (lower-first (ref name))) (fmt "serve_~a" (lower-first (ref name)))
                            (ref input) (arg 0) (ref name) (arg 0) (svc)))
     (client-streaming (fmt "@_cdecl(~s)\npublic func ~a(_ callId: UInt32, _ payload: UnsafePointer<UInt8>, _ payloadLen: Int, _ md: UnsafePointer<UInt8>, _ mdLen: Int) {\n    let metadata = DecodeMetadata(Array(UnsafeBufferPointer(start: md, count: mdLen)))\n    let reqs = UnpackPacked(Array(UnsafeBufferPointer(start: payload, count: payloadLen))).map { bytes -> ~a in let req = ~a(); req.UnmarshalDc(bytes); return req }\n    switch ~a.serverImpl!.~a(reqs, metadata) {\n    case .success(let resp): ServerRespond(callId, resp.MarshalDc())\n    case .failure(let st): ServerFail(callId, st)\n    }\n}\n\n"
                            (fmt "serve_~a" (lower-first (ref name))) (fmt "serve_~a" (lower-first (ref name)))
                            (ref input) (ref input) (arg 0) (ref name)))
     (bidi (fmt "@_cdecl(~s)\npublic func ~a(_ callId: UInt32, _ payload: UnsafePointer<UInt8>, _ payloadLen: Int, _ md: UnsafePointer<UInt8>, _ mdLen: Int) {\n    let metadata = DecodeMetadata(Array(UnsafeBufferPointer(start: md, count: mdLen)))\n    let reqs = UnpackPacked(Array(UnsafeBufferPointer(start: payload, count: payloadLen))).map { bytes -> ~a in let req = ~a(); req.UnmarshalDc(bytes); return req }\n    if let st = ~a.serverImpl!.~a(reqs, metadata, ~a.~aServerSink(callId: callId)) {\n        ServerFail(callId, st)\n    } else {\n        ServerComplete(callId)\n    }\n}\n\n"
                (fmt "serve_~a" (lower-first (ref name))) (fmt "serve_~a" (lower-first (ref name)))
                (ref input) (ref input) (arg 0) (ref name) (arg 0) (svc))))))

(define wasm-swift-stream-iface-method-program
  '((kind-case
     (client-streaming (fmt "        func ~aBegin(_ callId: UInt32, _ metadata: [(String, String)])\n        func ~aRequest(_ callId: UInt32, _ req: ~a)\n        func ~aEnd(_ callId: UInt32) -> Result<~a, StatusException>\n"
                            (ref name) (ref name) (ref input) (ref name) (ref output)))
     (bidi (fmt "        func ~aBegin(_ callId: UInt32, _ metadata: [(String, String)])\n        func ~aRequest(_ callId: UInt32, _ req: ~a, _ sink: ~aServerSink) -> StatusException?\n        func ~aEnd(_ callId: UInt32) -> StatusException?\n"
                (ref name) (ref name) (ref input) (svc) (ref name)))
     (else ""))))

(define wasm-swift-stream-feed-export-program
  '((kind-case
     (client-streaming
      (fmt "@_cdecl(~s)\npublic func ~a(_ callId: UInt32, _ md: UnsafePointer<UInt8>, _ mdLen: Int) {\n    let metadata = DecodeMetadata(Array(UnsafeBufferPointer(start: md, count: mdLen)))\n    ~a.streamImpl!.~aBegin(callId, metadata)\n}\n\n"
           (fmt "~aStart" (fmt "serve_~a" (lower-first (ref name)))) (fmt "~aStart" (fmt "serve_~a" (lower-first (ref name)))) (arg 0) (ref name))
      (fmt "@_cdecl(~s)\npublic func ~a(_ callId: UInt32, _ payload: UnsafePointer<UInt8>, _ payloadLen: Int) {\n    let req = ~a()\n    req.UnmarshalDc(Array(UnsafeBufferPointer(start: payload, count: payloadLen)))\n    ~a.streamImpl!.~aRequest(callId, req)\n}\n\n"
           (fmt "~aFeed" (fmt "serve_~a" (lower-first (ref name)))) (fmt "~aFeed" (fmt "serve_~a" (lower-first (ref name)))) (ref input) (arg 0) (ref name))
      (fmt "@_cdecl(~s)\npublic func ~a(_ callId: UInt32) {\n    switch ~a.streamImpl!.~aEnd(callId) {\n    case .success(let resp): ServerRespond(callId, resp.MarshalDc())\n    case .failure(let st): ServerFail(callId, st)\n    }\n}\n\n"
           (fmt "~aEnd" (fmt "serve_~a" (lower-first (ref name)))) (fmt "~aEnd" (fmt "serve_~a" (lower-first (ref name)))) (arg 0) (ref name)))
     (bidi
      (fmt "@_cdecl(~s)\npublic func ~a(_ callId: UInt32, _ md: UnsafePointer<UInt8>, _ mdLen: Int) {\n    let metadata = DecodeMetadata(Array(UnsafeBufferPointer(start: md, count: mdLen)))\n    ~a.streamImpl!.~aBegin(callId, metadata)\n}\n\n"
           (fmt "~aStart" (fmt "serve_~a" (lower-first (ref name)))) (fmt "~aStart" (fmt "serve_~a" (lower-first (ref name)))) (arg 0) (ref name))
      (fmt "@_cdecl(~s)\npublic func ~a(_ callId: UInt32, _ payload: UnsafePointer<UInt8>, _ payloadLen: Int) {\n    let req = ~a()\n    req.UnmarshalDc(Array(UnsafeBufferPointer(start: payload, count: payloadLen)))\n    if let st = ~a.streamImpl!.~aRequest(callId, req, ~a.~aServerSink(callId: callId)) {\n        ServerFail(callId, st)\n    }\n}\n\n"
           (fmt "~aFeed" (fmt "serve_~a" (lower-first (ref name)))) (fmt "~aFeed" (fmt "serve_~a" (lower-first (ref name)))) (ref input) (arg 0) (ref name) (arg 0) (svc))
      (fmt "@_cdecl(~s)\npublic func ~a(_ callId: UInt32) {\n    if let st = ~a.streamImpl!.~aEnd(callId) {\n        ServerFail(callId, st)\n    } else {\n        ServerComplete(callId)\n    }\n}\n\n"
           (fmt "~aEnd" (fmt "serve_~a" (lower-first (ref name)))) (fmt "~aEnd" (fmt "serve_~a" (lower-first (ref name)))) (arg 0) (ref name)))
     (else ""))))

(define wasm-swift-service-program
  '((fmt "    /// Client for ~a (browser/WASM facade; see file doc).\n    final class ~aClient {\n        private let bridge: GrpcDcWasmBridge\n\n        init(_ bridge: GrpcDcWasmBridge = .shared) {\n            self.bridge = bridge\n        }\n\n" (ref full-name) (svc))
    (each+ methods client (call wasmSwiftClientMethod))
    "    }\n\n    /// Streaming response sink for server handlers.\n"
    (fmt "    struct ~aServerSink {\n        let callId: UInt32\n\n" (svc))
    (each-unique methods output
                  (fmt "        func Send(_ resp: ~a) {\n            ServerSend(callId, resp.MarshalDc())\n        }\n" (ref output)))
    "    }\n\n"
    (fmt "    /// Service implementation for ~a (browser/WASM facade).\n    protocol ~aServer {\n" (ref full-name) (svc))
    (each methods (call wasmSwiftServerIfaceMethod))
    "    }\n\n"
    (fmt "    static var serverImpl: ~aServer?\n\n    /// Register the service implementation used by the serve_* exports.\n    static func register~aServer(_ impl: ~aServer) {\n        serverImpl = impl\n    }\n\n" (svc) (svc) (svc))
    (fmt "    /// Incremental service implementation for ~a: requests arrive one at a time.\n    protocol ~aStreamServer {\n" (ref full-name) (svc))
    (each methods (call wasmSwiftStreamIfaceMethod))
    "    }\n\n"
    (fmt "    static var streamImpl: ~aStreamServer?\n\n    /// Register the incremental implementation used by the serve_*Start/Feed/End exports.\n    static func register~aStreamServer(_ impl: ~aStreamServer) {\n        streamImpl = impl\n    }\n" (svc) (svc) (svc))))

;; ---------------------------------------------------------------------------
;; Wasm-Go facade emitter (mirrors template-wasm-go.rkt). Method
;; programs take the sink struct name as (arg 0); inside the
;; service program it is derived from the root node's methods:
;; "<Svc>ServerSink" for a single response type, else
;; "<Svc><Resp>ServerSink".
;; ---------------------------------------------------------------------------

(define wasm-go-client-method-program
  '((kind-case
     (unary (fmt "func (c *~aClient) ~a(req *echo.~a) (*echo.~a, error) {\n\tpayload, err := callUnary(c.bridge, ~s, req.MarshalDC())\n\tif err != nil {\n\t\treturn nil, err\n\t}\n\tresp := new(echo.~a)\n\tif err := resp.UnmarshalDC(payload); err != nil {\n\t\treturn nil, err\n\t}\n\treturn resp, nil\n}\n"
                 (svc) (ref name) (ref input) (ref output) (ref path) (ref output)))
     (server-streaming (fmt "func (c *~aClient) ~a(req *echo.~a, onResp func(*echo.~a) error) error {\n\treturn callStream(c.bridge, \"serverStream\", ~s, req.MarshalDC(), func(payload []byte) error {\n\t\tresp := new(echo.~a)\n\t\tif err := resp.UnmarshalDC(payload); err != nil {\n\t\t\treturn err\n\t\t}\n\t\treturn onResp(resp)\n\t})\n}\n"
                            (svc) (ref name) (ref input) (ref output) (ref path) (ref output)))
     (client-streaming (fmt "func (c *~aClient) ~a(reqs ...*echo.~a) (*echo.~a, error) {\n\tpayloads := make([][]byte, len(reqs))\n\tfor i, r := range reqs {\n\t\tpayloads[i] = r.MarshalDC()\n\t}\n\tpayload, err := callClientStream(c.bridge, ~s, payloads)\n\tif err != nil {\n\t\treturn nil, err\n\t}\n\tresp := new(echo.~a)\n\tif err := resp.UnmarshalDC(payload); err != nil {\n\t\treturn nil, err\n\t}\n\treturn resp, nil\n}\n"
                            (svc) (ref name) (ref input) (ref output) (ref path) (ref output)))
     (bidi (fmt "func (c *~aClient) ~a(reqs []*echo.~a, onResp func(*echo.~a) error) error {\n\tpayloads := make([][]byte, len(reqs))\n\tfor i, r := range reqs {\n\t\tpayloads[i] = r.MarshalDC()\n\t}\n\treturn callStreamPayloads(c.bridge, \"bidi\", ~s, payloads, func(payload []byte) error {\n\t\tresp := new(echo.~a)\n\t\tif err := resp.UnmarshalDC(payload); err != nil {\n\t\t\treturn err\n\t\t}\n\t\treturn onResp(resp)\n\t})\n}\n"
                (svc) (ref name) (ref input) (ref output) (ref path) (ref output))))))

(define wasm-go-server-iface-method-program
  '((kind-case
     (unary (fmt "\t~a(req *echo.~a, metadata [][2]string) (*echo.~a, error)\n"
                 (ref name) (ref input) (ref output)))
     (server-streaming (fmt "\t~a(req *echo.~a, metadata [][2]string, sink *~a) error\n"
                            (ref name) (ref input) (arg 0)))
     (client-streaming (fmt "\t~a(reqs []*echo.~a, metadata [][2]string) (*echo.~a, error)\n"
                            (ref name) (ref input) (ref output)))
     (bidi (fmt "\t~a(reqs []*echo.~a, metadata [][2]string, sink *~a) error\n"
                (ref name) (ref input) (arg 0))))))

(define wasm-go-register-method-program
  '((kind-case
     (unary (fmt "\tregisterUnaryHandler(bridge, ~s, func(payload []byte, metadata [][2]string) ([]byte, error) {\n\t\treq := new(echo.~a)\n\t\tif err := req.UnmarshalDC(payload); err != nil {\n\t\t\treturn nil, err\n\t\t}\n\t\tresp, err := impl.~a(req, metadata)\n\t\tif err != nil {\n\t\t\treturn nil, err\n\t\t}\n\t\treturn resp.MarshalDC(), nil\n\t})\n"
                 (ref path) (ref input) (ref name)))
     (server-streaming (fmt "\tregisterServerStreamHandler(bridge, ~s, func(payload []byte, metadata [][2]string, sink *ServerSink) error {\n\t\treq := new(echo.~a)\n\t\tif err := req.UnmarshalDC(payload); err != nil {\n\t\t\treturn err\n\t\t}\n\t\treturn impl.~a(req, metadata, &~a{sink: sink})\n\t})\n"
                            (ref path) (ref input) (ref name) (arg 0)))
     (client-streaming (fmt "\tregisterClientStreamHandler(bridge, ~s, func(payloads [][]byte, metadata [][2]string) ([]byte, error) {\n\t\treqs := make([]*echo.~a, len(payloads))\n\t\tfor i, payload := range payloads {\n\t\t\treqs[i] = new(echo.~a)\n\t\t\tif err := reqs[i].UnmarshalDC(payload); err != nil {\n\t\t\t\treturn nil, err\n\t\t\t}\n\t\t}\n\t\tresp, err := impl.~a(reqs, metadata)\n\t\tif err != nil {\n\t\t\treturn nil, err\n\t\t}\n\t\treturn resp.MarshalDC(), nil\n\t})\n"
                            (ref path) (ref input) (ref input) (ref name)))
     (bidi (fmt "\tregisterBidiHandler(bridge, ~s, func(payloads [][]byte, metadata [][2]string, sink *ServerSink) error {\n\t\treqs := make([]*echo.~a, len(payloads))\n\t\tfor i, payload := range payloads {\n\t\t\treqs[i] = new(echo.~a)\n\t\t\tif err := reqs[i].UnmarshalDC(payload); err != nil {\n\t\t\t\treturn err\n\t\t\t}\n\t\t}\n\t\treturn impl.~a(reqs, metadata, &~a{sink: sink})\n\t})\n"
                (ref path) (ref input) (ref input) (ref name) (arg 0))))))

(define wasm-go-stream-iface-method-program
  '((kind-case
     (client-streaming (fmt "\t~a(source *~aSource, metadata [][2]string) (*echo.~a, error)\n"
                            (ref name) (ref input) (ref output)))
     (bidi (fmt "\t~a(source *~aSource, metadata [][2]string, sink *~a) error\n"
                (ref name) (ref input) (arg 0)))
     (else ""))))

(define wasm-go-stream-register-method-program
  '((kind-case
     (client-streaming (fmt "\tregisterClientStreamIncHandler(bridge, ~s, func(source *RequestSource, metadata [][2]string) ([]byte, error) {\n\t\tresp, err := impl.~a(&~aSource{raw: source}, metadata)\n\t\tif err != nil {\n\t\t\treturn nil, err\n\t\t}\n\t\treturn resp.MarshalDC(), nil\n\t})\n"
                            (ref path) (ref name) (ref input)))
     (bidi (fmt "\tregisterBidiIncHandler(bridge, ~s, func(source *RequestSource, metadata [][2]string, sink *ServerSink) error {\n\t\treturn impl.~a(&~aSource{raw: source}, metadata, &~a{sink: sink})\n\t})\n"
                (ref path) (ref name) (ref input) (arg 0)))
     (else ""))))

(define wasm-go-service-program
  '((fmt "type ~aClient struct {\n\tbridge js.Value\n}\n\nfunc New~aClient(bridge js.Value) *~aClient {\n\treturn &~aClient{bridge: bridge}\n}\n\n" (svc) (svc) (svc) (svc))
    (each methods (call wasmGoClientMethod))
    (fmt "\n// ~aServer is the service implementation for ~a.\ntype ~aServer interface {\n" (svc) (ref full-name) (svc))
    (each methods (call wasmGoServerIfaceMethod
                        (case-on (distinct-count (get (root) methods) output)
                          (1 (fmt "~aServerSink" (svc)))
                          (else (fmt "~a~aServerSink" (svc) (ref output))))))
    "}\n\n"
    (each-unique methods output
                  (fmt "// ~a sends responses on streaming calls.\ntype ~a struct {\n\tsink *ServerSink\n}\n\n// Send marshals and forwards one response.\nfunc (s *~a) Send(resp *echo.~a) error {\n\ts.sink.Send(resp.MarshalDC())\n\treturn nil\n}\n\n"
                       (case-on (distinct-count (get (root) methods) output)
                         (1 (fmt "~aServerSink" (svc)))
                         (else (fmt "~a~aServerSink" (svc) (ref output))))
                       (case-on (distinct-count (get (root) methods) output)
                         (1 (fmt "~aServerSink" (svc)))
                         (else (fmt "~a~aServerSink" (svc) (ref output))))
                       (case-on (distinct-count (get (root) methods) output)
                         (1 (fmt "~aServerSink" (svc)))
                         (else (fmt "~a~aServerSink" (svc) (ref output))))
                       (ref output)))
    (fmt "// Register~aServer registers impl on the JS server bridge and starts serving.\nfunc Register~aServer(bridge js.Value, impl ~aServer) {\n" (svc) (svc) (svc))
    (each methods (call wasmGoRegisterMethod
                        (case-on (distinct-count (get (root) methods) output)
                          (1 (fmt "~aServerSink" (svc)))
                          (else (fmt "~a~aServerSink" (svc) (ref output))))))
    (fmt "\tbridge.Call(\"start\", ~s)\n}\n" (ref full-name))
    (each-unique methods input (kinds client-streaming bidi)
                  (fmt "\n// ~aSource pulls typed requests one at a time for incremental handlers.\ntype ~aSource struct {\n\traw *RequestSource\n}\n\n// Next returns the next request, or (nil, nil) at end of stream.\nfunc (s *~aSource) Next() (*echo.~a, error) {\n\tpayload, err := s.raw.Next()\n\tif err != nil || payload == nil {\n\t\treturn nil, err\n\t}\n\treq := new(echo.~a)\n\tif err := req.UnmarshalDC(payload); err != nil {\n\t\treturn nil, err\n\t}\n\treturn req, nil\n}\n\n"
                       (ref input) (ref input) (ref input) (ref input) (ref input)))
    (fmt "// ~aStreamServer is the incremental implementation for ~a: requests arrive one at a time.\ntype ~aStreamServer interface {\n" (svc) (ref full-name) (svc))
    (each methods (call wasmGoStreamIfaceMethod
                        (case-on (distinct-count (get (root) methods) output)
                          (1 (fmt "~aServerSink" (svc)))
                          (else (fmt "~a~aServerSink" (svc) (ref output))))))
    "}\n\n"
    (fmt "// Register~aStreamServer registers an incremental impl; call bridge start after all registrations.\nfunc Register~aStreamServer(bridge js.Value, impl ~aStreamServer) {\n" (svc) (svc) (svc))
    (each methods (call wasmGoStreamRegisterMethod
                        (case-on (distinct-count (get (root) methods) output)
                          (1 (fmt "~aServerSink" (svc)))
                          (else (fmt "~a~aServerSink" (svc) (ref output))))))
    "}\n"))

;; ---------------------------------------------------------------------------
;; Wasm-Kotlin facade emitter (mirrors template-wasm-kotlin.rkt).
;; ---------------------------------------------------------------------------

(define wasm-kotlin-client-method-program
  '((kind-case
     (unary (fmt "        fun ~a(req: ~a, callback: (Result<~a>) -> Unit) {\n            bridge.unary(~s, req.marshalDc()) { result ->\n                callback(result.mapCatching { bytes ->\n                    ~a().apply { unmarshalDc(bytes) }\n                })\n            }\n        }\n\n"
                 (ref name) (ref input) (ref output) (ref path) (ref output)))
     (server-streaming (fmt "        fun ~a(\n            req: ~a,\n            onMessage: (~a) -> Unit,\n            onDone: (StatusException?) -> Unit\n        ) {\n            var finished = false\n            bridge.serverStream(~s, req.marshalDc(), { bytes ->\n                if (!finished) {\n                    try {\n                        onMessage(~a().apply { unmarshalDc(bytes) })\n                    } catch (e: Throwable) {\n                        finished = true\n                        onDone(StatusException.toStatus(e))\n                    }\n                }\n            }) { err ->\n                if (!finished) {\n                    finished = true\n                    onDone(err)\n                }\n            }\n        }\n\n"
                            (ref name) (ref input) (ref output) (ref path) (ref output)))
     (client-streaming (fmt "        fun ~a(reqs: List<~a>, callback: (Result<~a>) -> Unit) {\n            bridge.clientStream(~s, reqs.map { it.marshalDc() }) { result ->\n                callback(result.mapCatching { bytes ->\n                    ~a().apply { unmarshalDc(bytes) }\n                })\n            }\n        }\n\n"
                            (ref name) (ref input) (ref output) (ref path) (ref output)))
     (bidi (fmt "        fun ~a(\n            reqs: List<~a>,\n            onMessage: (~a) -> Unit,\n            onDone: (StatusException?) -> Unit\n        ) {\n            var finished = false\n            bridge.bidi(~s, reqs.map { it.marshalDc() }, { bytes ->\n                if (!finished) {\n                    try {\n                        onMessage(~a().apply { unmarshalDc(bytes) })\n                    } catch (e: Throwable) {\n                        finished = true\n                        onDone(StatusException.toStatus(e))\n                    }\n                }\n            }) { err ->\n                if (!finished) {\n                    finished = true\n                    onDone(err)\n                }\n            }\n        }\n\n"
                (ref name) (ref input) (ref output) (ref path) (ref output))))))

(define wasm-kotlin-server-iface-method-program
  '((kind-case
     (unary (fmt "        fun ~a(req: ~a, metadata: Map<String, String>): ~a\n" (ref name) (ref input) (ref output)))
     (server-streaming (fmt "        fun ~a(req: ~a, metadata: Map<String, String>, sink: (~a) -> Unit)\n" (ref name) (ref input) (ref output)))
     (client-streaming (fmt "        fun ~a(reqs: List<~a>, metadata: Map<String, String>): ~a\n" (ref name) (ref input) (ref output)))
     (bidi (fmt "        fun ~a(reqs: List<~a>, metadata: Map<String, String>, sink: (~a) -> Unit)\n" (ref name) (ref input) (ref output))))))

(define wasm-kotlin-register-method-program
  '((kind-case
     (unary (fmt "        bridge.unary(~s) { bytes, metadata ->\n            impl.~a(~a().apply { unmarshalDc(bytes) }, metadata).marshalDc()\n        }\n" (ref path) (ref name) (ref input)))
     (server-streaming (fmt "        bridge.serverStream(~s) { bytes, metadata, sink ->\n            impl.~a(~a().apply { unmarshalDc(bytes) }, metadata) { resp -> sink(resp.marshalDc()) }\n        }\n" (ref path) (ref name) (ref input)))
     (client-streaming (fmt "        bridge.clientStream(~s) { payloads, metadata ->\n            impl.~a(payloads.map { bytes -> ~a().apply { unmarshalDc(bytes) } }, metadata).marshalDc()\n        }\n" (ref path) (ref name) (ref input)))
     (bidi (fmt "        bridge.bidi(~s) { payloads, metadata, sink ->\n            impl.~a(payloads.map { bytes -> ~a().apply { unmarshalDc(bytes) } }, metadata) { resp -> sink(resp.marshalDc()) }\n        }\n" (ref path) (ref name) (ref input))))))

(define wasm-kotlin-stream-iface-method-program
  '((kind-case
     (client-streaming (fmt "        fun ~a(source: ~aSource, metadata: Map<String, String>, respond: (~a) -> Unit, fail: (StatusException) -> Unit)\n" (ref name) (ref input) (ref output)))
     (bidi (fmt "        fun ~a(source: ~aSource, metadata: Map<String, String>, sink: (~a) -> Unit, done: () -> Unit, fail: (StatusException) -> Unit)\n" (ref name) (ref input) (ref output)))
     (else ""))))

(define wasm-kotlin-stream-register-method-program
  '((kind-case
     (client-streaming (fmt "        bridge.clientStreamInc(~s) { source, metadata, respond, fail ->\n            impl.~a(~aSource(source), metadata, { resp -> respond(resp.marshalDc()) }, fail)\n        }\n" (ref path) (ref name) (ref input)))
     (bidi (fmt "        bridge.bidiInc(~s) { source, metadata, sink, done, fail ->\n            impl.~a(~aSource(source), metadata, { resp -> sink(resp.marshalDc()) }, done, fail)\n        }\n" (ref path) (ref name) (ref input)))
     (else ""))))

(define wasm-kotlin-service-program
  '((fmt "    /** Client for ~a (browser/WASM facade; see file doc). */\n    class ~aClient(private val bridge: GrpcdcWasmBridge) {\n" (ref full-name) (svc))
    (each+ methods client (call wasmKotlinClientMethod))
    "    }\n\n"
    (fmt "    /** Service implementation interface for ~a (browser/WASM facade). */\n    interface ~aServer {\n" (ref full-name) (svc))
    (each methods (call wasmKotlinServerIfaceMethod))
    "    }\n\n"
    (fmt "    /** Register an implementation of ~a on a server bridge. */\n    fun register~aServer(bridge: GrpcdcWasmServerBridge, impl: ~aServer) {\n" (ref full-name) (svc) (svc))
    (each+ methods server (call wasmKotlinRegisterMethod))
    (fmt "        bridge.start(~s)\n    }\n\n" (ref full-name))
    (each-unique methods input (kinds client-streaming bidi)
                  (fmt "    /** Typed pull source for incremental server handlers. */\n    class ~aSource internal constructor(private val raw: GrpcdcRequestSource) {\n        fun next(onRequest: ((~a?) -> Unit), onError: (StatusException) -> Unit) {\n            raw.next({ bytes -> onRequest(bytes?.let { ~a().apply { unmarshalDc(it) } }) }, onError)\n        }\n    }\n\n" (ref input) (ref input) (ref input)))
    (fmt "    /** Incremental service implementation for ~a: requests arrive one at a time. */\n    interface ~aStreamServer {\n" (ref full-name) (svc))
    (each methods (call wasmKotlinStreamIfaceMethod))
    "    }\n\n"
    (fmt "    /** Register an incremental implementation; call bridge.start after all registrations. */\n    fun register~aStreamServer(bridge: GrpcdcWasmServerBridge, impl: ~aStreamServer) {\n" (svc) (svc))
    (each+ methods server (call wasmKotlinStreamRegisterMethod))
    "    }\n"))

(define segment-programs
  (hasheq 'goRegisterMethod go-register-method-program
          'goDeprecated go-deprecated-program
          'goClientMethod go-client-method-program
          'goServerIfaceMethod go-server-iface-method-program
          'goServerIfaceMethodDeprecated go-server-iface-method-deprecated-program
          'goStreamIfaces go-stream-ifaces-program
          'goStreamImpls go-stream-impls-program
          'goService go-service-program
          'goPbVarintExpr go-pb-varint-expr-program
          'goPbVarintDecode go-pb-varint-decode-program
          'goPbFixedEncode go-pb-fixed-encode-program
          'goPbFixedDecode go-pb-fixed-decode-program
          'goPbZero go-pb-zero-program
          'goPbEncodeSingular go-pb-encode-singular-program
          'goPbEncodeField go-pb-encode-field-program
          'goPbDecodeSingular go-pb-decode-singular-program
          'goPbDecodeCase go-pb-decode-case-program
          'goPbEncodeFieldGuarded go-pb-encode-field-guarded-program
          'goPbMapHelpers go-pb-map-helpers-program
          'goPbEnum go-pb-enum-program
          'goPbDefaultLiteral go-pb-default-literal-program
          'goPbConstructor go-pb-constructor-program
          'goPbSetExpr go-pb-set-expr-program
          'goPbMessage go-pb-message-program
          'jsDeprecated js-deprecated-program
          'jsClientMethod js-client-method-program
          'jsMethodTableEntry js-method-table-entry-program
          'jsService js-service-program
          'jsPbVarintExpr js-pb-varint-expr-program
          'jsPbVarintDecode js-pb-varint-decode-program
          'jsPbExplicitLiteral js-pb-explicit-literal-program
          'jsPbDefault js-pb-default-program
          'jsPbSetExpr js-pb-set-expr-program
          'jsPbOneofClearing js-pb-oneof-clearing-program
          'jsPbEncodeSingular js-pb-encode-singular-program
          'jsPbEncodeField js-pb-encode-field-program
          'jsPbDecodeSingular js-pb-decode-singular-program
          'jsPbDecodeCase js-pb-decode-case-program
          'jsPbMapHelpers js-pb-map-helpers-program
          'jsPbEnumConst js-pb-enum-const-program
          'jsPbMessage js-pb-message-program
          'wasmSwiftClientMethod wasm-swift-client-method-program
          'wasmSwiftServerIfaceMethod wasm-swift-server-iface-method-program
          'wasmSwiftServeExport wasm-swift-serve-export-program
          'wasmSwiftStreamIfaceMethod wasm-swift-stream-iface-method-program
          'wasmSwiftStreamFeedExport wasm-swift-stream-feed-export-program
          'wasmSwiftService wasm-swift-service-program
          'wasmGoClientMethod wasm-go-client-method-program
          'wasmGoServerIfaceMethod wasm-go-server-iface-method-program
          'wasmGoRegisterMethod wasm-go-register-method-program
          'wasmGoStreamIfaceMethod wasm-go-stream-iface-method-program
          'wasmGoStreamRegisterMethod wasm-go-stream-register-method-program
          'wasmGoService wasm-go-service-program
          'wasmKotlinClientMethod wasm-kotlin-client-method-program
          'wasmKotlinServerIfaceMethod wasm-kotlin-server-iface-method-program
          'wasmKotlinRegisterMethod wasm-kotlin-register-method-program
          'wasmKotlinStreamIfaceMethod wasm-kotlin-stream-iface-method-program
          'wasmKotlinStreamRegisterMethod wasm-kotlin-stream-register-method-program
          'wasmKotlinService wasm-kotlin-service-program))

;; ---------------------------------------------------------------------------
;; Racket interpreter. An env is (model node svc args err):
;; the file model (or #f), the current model node, the
;; enclosing service name, positional string args for (arg i),
;; and the decode error statement for (err-stmt).
;; ---------------------------------------------------------------------------

(define (seg-ref node key)
  (if (eq? key 'impl-name)
      (hash-ref node 'impl-name (hash-ref node 'name))
      (hash-ref node key #f)))

(define (run-segments program node svc [model #f] [args '()] [err "return err"])
  (run-env program (list model node svc args err node)))

(define (run-env program env)
  (apply string-append
         (for/list ([seg (in-list program)])
           (run-segment seg env))))

(define (env-model env) (first env))
(define (env-node env) (second env))
(define (env-svc env) (third env))
(define (env-args env) (fourth env))
(define (env-err env) (fifth env))
(define (env-root env) (sixth env))
(define (env-with env #:model [model (env-model env)] #:node [node (env-node env)]
                  #:args [args (env-args env)] #:err [err (env-err env)]
                  #:root [root (env-root env)])
  (list model node (env-svc env) args err root))

(define (seg-truthy? v)
  (not (or (not v) (equal? v "") (equal? v 0))))

;; --- builtin library (mirrors the small pure helpers of the
;; --- Go pb emitter; the JS interpreter delegates to its own
;; --- gp* counterparts) ---

(define (seg-pascal s)
  (string-join
   (map (lambda (part)
          (if (string=? part "") "" (string-append (string (char-upcase (string-ref part 0))) (substring part 1))))
        (string-split s "_")) ""))

(define (seg-flat pkg full)
  (define rel (if (and pkg (not (string=? pkg ""))
                       (string-prefix? full (string-append pkg ".")))
                  (substring full (add1 (string-length pkg)))
                  full))
  (string-join (string-split rel ".") "_"))

(define (seg-resolve model type-name)
  (hash-ref (hash-ref model 'types) type-name
            (lambda () (error 'run-segments "unresolved type ~a" type-name))))

(define (seg-entry-type entry)
  (seg-flat (hash-ref entry 'pkg)
            (if (eq? (hash-ref entry 'kind) 'enum)
                (hash-ref entry 'full)
                (hash-ref (hash-ref entry 'msg) 'full-name))))

(define (seg-entry-type-of model node)
  (if (hash-has-key? node 'type-name)
      (seg-entry-type (seg-resolve model (hash-ref node 'type-name)))
      (seg-entry-type node)))

(define (seg-field-type model f)
  (define type (hash-ref f 'type))
  (define base
    (cond [(= type 11)
           (define entry (seg-resolve model (hash-ref f 'type-name)))
           (if (eq? (hash-ref entry 'kind) 'map)
               (let* ([entry-msg (hash-ref entry 'msg)]
                      [kf (findf (lambda (x) (= (hash-ref x 'number) 1)) (hash-ref entry-msg 'fields))]
                      [vf (findf (lambda (x) (= (hash-ref x 'number) 2)) (hash-ref entry-msg 'fields))])
                 (format "map[~a]~a" (seg-field-type model (hash-set kf 'label 1))
                         (seg-field-type model (hash-set vf 'label 1))))
               (string-append "*" (seg-entry-type entry)))]
          [(= type 14) (seg-entry-type (seg-resolve model (hash-ref f 'type-name)))]
          [else (scalar-type-entry 'go type)]))
  (if (= (hash-ref f 'label) 3)
      (if (and (= type 11)
               (eq? (hash-ref (seg-resolve model (hash-ref f 'type-name)) 'kind) 'map))
          base
          (string-append "[]" base))
      base))

(define (seg-category model node)
  (define type (hash-ref node 'type))
  (cond [(and (= type 11)
              (eq? (hash-ref (seg-resolve model (hash-ref node 'type-name)) 'kind) 'map)) "map"]
        [(= type 11) "message"]
        [(memv type varint-scalar-types) "varint"]
        [(assv type (fixed-scalar-table 'go)) "fixed"]
        [(= type 9) "string"]
        [(= type 12) "bytes"]
        [else "other"]))

(define (seg-fixed-info node)
  (assv (hash-ref node 'type) (fixed-scalar-table 'go)))

(define (seg-zero node)
  (case (hash-ref node 'type)
    [(11 12) "nil"]
    [(9) "\"\""]
    [(8) "false"]
    [else "0"]))

(define (seg-set-expr sib)
  (define v (format "m.~a" (seg-pascal (hash-ref sib 'name))))
  (case (hash-ref sib 'type)
    [(11 10) (format "~a != nil" v)]
    [(9) (format "~a != \"\"" v)]
    [(12) (format "len(~a) > 0" v)]
    [(8) v]
    [else (format "~a != 0" v)]))

(define (seg-oneof-clearing model node)
  (apply string-append
         (map (lambda (sib)
                (format "\t\t\tm.~a = ~a\n" (seg-pascal (hash-ref sib 'name)) (seg-zero sib)))
              (oneof-siblings model node))))

(define (seg-lower-first s0)
  (define s (if (symbol? s0) (symbol->string s0) s0))
  (if (string=? s "")
      s
      (string-append (string (char-downcase (string-ref s 0))) (substring s 1))))

(define (seg-js-name f)
  (define jn (hash-ref f 'json-name ""))
  (if (and jn (not (string=? jn "")))
      jn
      (regexp-replace* #rx"_([a-zA-Z0-9])" (hash-ref f 'name)
                       (lambda (all c) (string-upcase c)))))

(define (seg-later-oneof-cond model node)
  (define later (oneof-later-siblings model node))
  (if (null? later)
      ""
      (string-join (map seg-set-expr later) " || ")))

(define (seg-eval seg env)
  ;; Evaluate an expression segment to a value (string, number,
  ;; boolean, or a model node for call-on/get).
  (define node (env-node env))
  (define model (env-model env))
  (cond
    [(string? seg) seg]
    [(number? seg) seg]
    [(eq? (car seg) 'fmt)
     (apply format (second seg)
            (map (lambda (e)
                   (define v (seg-eval e env))
                   (if (symbol? v) (symbol->string v) v))
                 (cddr seg)))]
    [(eq? (car seg) 'ref)
     (if (null? (cddr seg))
         (seg-ref node (second seg))
         (foldl (lambda (k acc) (hash-ref acc k)) node (cdr seg)))]
    [(eq? (car seg) 'svc) (env-svc env)]
    [(eq? (car seg) 'arg) (list-ref (env-args env) (second seg))]
    [(eq? (car seg) 'err-stmt) (env-err env)]
    [(eq? (car seg) 'self) node]
    [(eq? (car seg) 'root) (env-root env)]
    [(eq? (car seg) 'distinct-count)
     (length (remove-duplicates
              (map (lambda (el) (hash-ref el (third seg)))
                   (seg-eval (second seg) env))))]
    [(memq (car seg) '(if case-on when guarded kind-case each each+ each-siblings each-sep each-unique))
     (run-segment seg env)]
    [(eq? (car seg) 'pascal) (seg-pascal (seg-eval (second seg) env))]
    [(eq? (car seg) 'lower-first) (seg-lower-first (seg-eval (second seg) env))]
    [(eq? (car seg) 'js-name) (seg-js-name node)]
    [(eq? (car seg) 'js-fixed-size)
     (second (assv (hash-ref node 'type) (fixed-scalar-table 'js)))]
    [(eq? (car seg) 'js-fixed-name)
     (third (assv (hash-ref node 'type) (fixed-scalar-table 'js)))]
    [(eq? (car seg) 'bigint-type)
     (and (memv (hash-ref node 'type) '(3 4 18 6 16)) #t)]
    [(eq? (car seg) 'entry-flat) (seg-entry-type node)]
    [(eq? (car seg) 'resolved-flat)
     (seg-entry-type (seg-resolve model (hash-ref node 'type-name)))]
    [(eq? (car seg) 'flat)
     (seg-flat (hash-ref model 'package) (hash-ref node 'full-name))]
    [(eq? (car seg) 'entry-type) (seg-entry-type-of model node)]
    [(eq? (car seg) 'field-type) (seg-field-type model node)]
    [(eq? (car seg) 'field-type-of)
     (seg-field-type model (seg-eval (second seg) env))]
    [(eq? (car seg) 'resolved-entry) (seg-resolve model (hash-ref node 'type-name))]
    [(eq? (car seg) 'key-field)
     (define entry (if (null? (cdr seg)) node (seg-eval (second seg) env)))
     (findf (lambda (x) (= (hash-ref x 'number) 1)) (hash-ref (hash-ref entry 'msg) 'fields))]
    [(eq? (car seg) 'val-field)
     (define entry (if (null? (cdr seg)) node (seg-eval (second seg) env)))
     (findf (lambda (x) (= (hash-ref x 'number) 2)) (hash-ref (hash-ref entry 'msg) 'fields))]
    [(eq? (car seg) 'with-label)
     (hash-set (seg-eval (second seg) env) 'label (third seg))]
    [(eq? (car seg) 'get)
     (hash-ref (seg-eval (second seg) env) (third seg))]
    [(eq? (car seg) 'fixed-name) (third (seg-fixed-info node))]
    [(eq? (car seg) 'fixed-size) (second (seg-fixed-info node))]
    [(eq? (car seg) 'fixed-wire) (if (= (second (seg-fixed-info node)) 8) 1 5)]
    [(eq? (car seg) 'type) (hash-ref node 'type)]
    [(eq? (car seg) 'category) (seg-category model node)]
    [(eq? (car seg) 'category-of) (seg-category model (seg-eval (second seg) env))]
    [(eq? (car seg) 'proto2) (equal? (hash-ref model 'syntax "") "proto2")]
    [(eq? (car seg) 'type-is) (= (hash-ref node 'type) (second seg))]
    [(eq? (car seg) 'is-varint) (and (memv (hash-ref node 'type) varint-scalar-types) #t)]
    [(eq? (car seg) 'is-fixed) (and (seg-fixed-info node) #t)]
    [(eq? (car seg) 'is-map)
     (and (= (hash-ref node 'type) 11)
          (eq? (hash-ref (seg-resolve model (hash-ref node 'type-name)) 'kind) 'map))]
    [(eq? (car seg) 'repeated) (= (hash-ref node 'label) 3)]
    [(eq? (car seg) 'has-default) (and (field-explicit-default node) #t)]
    [(eq? (car seg) 'any-default)
     (for/or ([f (in-list (hash-ref node 'fields))]) (field-explicit-default f))]
    [(eq? (car seg) 'no-fields) (null? (hash-ref node 'fields))]
    [(eq? (car seg) 'default-raw) (field-explicit-default node)]
    [(eq? (car seg) 'enum-default-num) (enum-default-number model node)]
    [(eq? (car seg) 'oneof-clearing) (seg-oneof-clearing model node)]
    [(eq? (car seg) 'later-oneof-cond) (seg-later-oneof-cond model node)]
    [(eq? (car seg) 'call)
     (run-env (hash-ref segment-programs (second seg))
              (env-with env #:args (map (lambda (e) (seg-eval e env)) (cddr seg))))]
    [(eq? (car seg) 'call-on)
     (run-env (hash-ref segment-programs (third seg))
              (env-with env #:node (seg-eval (second seg) env)
                        #:args (map (lambda (e) (seg-eval e env)) (cdddr seg))))]
    [else (error 'run-segments "bad expression: ~e" seg)]))

(define (run-segment seg env)
  (define node (env-node env))
  (cond
    [(string? seg) seg]
    [(eq? (car seg) 'if)
     (define then-segs (cdr (assq 'then (cddr seg))))
     (define else-part (assq 'else (cddr seg)))
     (if (seg-truthy? (seg-eval (second seg) env))
         (run-env then-segs env)
         (if else-part (run-env (cdr else-part) env) ""))]
    [(eq? (car seg) 'kind-case)
     (define kind (hash-ref node 'kind))
     (define branch (or (assq kind (cdr seg)) (assq 'else (cdr seg))))
     (unless branch (error 'run-segments "no kind branch for ~e" kind))
     (run-env (cdr branch) env)]
    [(eq? (car seg) 'case-on)
     (define val (seg-eval (second seg) env))
     ;; Branches may be written wrapped: as one list
     ;; (case-on e ((k seg ...) ...)), bare (case-on e (k seg ...) ...),
     ;; or with individual branches wrapped. Normalize all three.
     (define raw (cddr seg))
     (define (branch-key? b)
       (and (list? b) (pair? b)
            (or (number? (car b)) (string? (car b)) (eq? (car b) 'else)
                (and (list? (car b)) (andmap number? (car b))))))
     (define branches
       (cond [(and (= (length raw) 1) (list? (car raw))
                   (andmap branch-key? (car raw)))
              (car raw)]
             [else (map (lambda (b)
                          (if (and (list? b) (= (length b) 1) (list? (car b)))
                              (car b)
                              b))
                        raw)]))
     (define branch
       (for/first ([b (in-list branches)]
                   #:when (or (eq? (car b) 'else)
                              (member val (if (list? (car b))
                                              (car b)
                                              (list (car b)))
                                      equal?)))
         b))
     (if branch (run-env (cdr branch) env) "")]
    [(eq? (car seg) 'when)
     (if (seg-truthy? (seg-eval (second seg) env))
         (run-env (cddr seg) env)
         "")]
    [(eq? (car seg) 'guarded)
     ;; (guarded SetExprProgram "open ~a template" "close" body...)
     (define text (run-env (cddddr seg) env))
     (define cond-str
       (string-join
        (map (lambda (sib)
               (run-env (hash-ref segment-programs (second seg))
                        (env-with env #:node sib)))
             (oneof-later-siblings (env-model env) node))
        " || "))
     (if (equal? cond-str "")
         text
         (string-append (format (third seg) cond-str)
                        (if (string-suffix? text "\n") text (string-append text "\n"))
                        (fourth seg)))]
    [(eq? (car seg) 'fail)
     (error 'run-segments "unsupported field type ~a" (hash-ref node 'type))]
    [(eq? (car seg) 'each)
     (define-values (keys segs) (splitf-at (cdr seg) symbol?))
     (define items
       (foldl (lambda (k acc) (hash-ref acc k)) node keys))
     (apply string-append
            (for/list ([el (in-list items)])
              (run-env segs (env-with env #:node el))))]
    [(eq? (car seg) 'each+)
     (define aliases (if (eq? (third seg) 'client)
                         (alias-client-methods node)
                         (alias-server-methods node)))
     (apply string-append
            (for/list ([el (in-list (append (hash-ref node (second seg)) aliases))])
              (run-env (cdddr seg) (env-with env #:node el))))]
    [(eq? (car seg) 'each-siblings)
     (apply string-append
            (for/list ([sib (in-list (oneof-siblings (env-model env) node))])
              (run-env (cdr seg) (env-with env #:node sib))))]
    [(eq? (car seg) 'each-unique)
     (define kinds-part (and (pair? (cdddr seg)) (list? (fourth seg))
                             (eq? (car (fourth seg)) 'kinds)
                             (cdr (fourth seg))))
     (define body (if kinds-part (cddddr seg) (cdddr seg)))
     (define seen (mutable-set))
     (apply string-append
            (for/list ([el (in-list (hash-ref node (second seg)))]
                       #:when (and (or (not kinds-part)
                                       (memq (hash-ref el 'kind) kinds-part))
                                   (let ([v (hash-ref el (third seg))])
                                     (and (not (set-member? seen v))
                                          (set-add! seen v)))))
              (run-env body (env-with env #:node el))))]
    [(eq? (car seg) 'each-sep)
     (define-values (keys segs) (splitf-at (cddr seg) symbol?))
     (define items
       (foldl (lambda (k acc) (hash-ref acc k)) node keys))
     (string-join
      (for/list ([el (in-list items)])
        (run-env segs (env-with env #:node el)))
      (second seg))]
    [else (seg-eval seg env)]))
