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
         go-service-program segment-programs run-segments)

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
  '((guarded (call goPbEncodeField))))

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
          'goPbMessage go-pb-message-program))

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
  (run-env program (list model node svc args err)))

(define (run-env program env)
  (apply string-append
         (for/list ([seg (in-list program)])
           (run-segment seg env))))

(define (env-model env) (first env))
(define (env-node env) (second env))
(define (env-svc env) (third env))
(define (env-args env) (fourth env))
(define (env-err env) (fifth env))
(define (env-with env #:model [model (env-model env)] #:node [node (env-node env)]
                  #:args [args (env-args env)] #:err [err (env-err env)])
  (list model node (env-svc env) args err))

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
            (map (lambda (e) (seg-eval e env)) (cddr seg)))]
    [(eq? (car seg) 'ref)
     (if (null? (cddr seg))
         (seg-ref node (second seg))
         (foldl (lambda (k acc) (hash-ref acc k)) node (cdr seg)))]
    [(eq? (car seg) 'svc) (env-svc env)]
    [(eq? (car seg) 'arg) (list-ref (env-args env) (second seg))]
    [(eq? (car seg) 'err-stmt) (env-err env)]
    [(eq? (car seg) 'self) node]
    [(memq (car seg) '(if case-on when guarded kind-case))
     (run-segment seg env)]
    [(eq? (car seg) 'pascal) (seg-pascal (seg-eval (second seg) env))]
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
     (define branch (assq kind (cdr seg)))
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
            (or (number? (car b)) (string? (car b)) (eq? (car b) 'else))))
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
                   #:when (or (eq? (car b) 'else) (equal? (car b) val)))
         b))
     (if branch (run-env (cdr branch) env) "")]
    [(eq? (car seg) 'when)
     (if (seg-truthy? (seg-eval (second seg) env))
         (run-env (cddr seg) env)
         "")]
    [(eq? (car seg) 'guarded)
     (define text (run-env (cdr seg) env))
     (define cond-str (seg-later-oneof-cond (env-model env) node))
     (if (equal? cond-str "")
         text
         (string-append "\tif !(" cond-str ") {\n"
                        (if (string-suffix? text "\n") text (string-append text "\n"))
                        "\t}\n"))]
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
    [else (seg-eval seg env)]))
