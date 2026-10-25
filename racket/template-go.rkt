#lang racket

;;; template-go.rkt — emitter body spliced into protoc-gen-grpc-dc-go.
;;;
;;; Generated code lives in the proto's Go package (plugin parameter
;;; `go_package` overrides) alongside hand-written message types that
;;; implement grpcdc.Marshaler / grpcdc.Unmarshaler (MarshalDC /
;;; UnmarshalDC), and imports the runtime as grpcdc.

(require "spec.rkt" "desc.rkt")
(provide emit-go-file)

(define (go-package file-model params)
  (define override (hash-ref params 'go_package #f))
  (cond [override override]
        [else
         (define pkg (hash-ref file-model 'package))
         (define parts (string-split pkg "."))
         (if (null? parts) "proto" (last parts))]))

;; The client-method emitter needs the service name; bind it dynamically
;; per service instead of threading it through every format call.
(define current-service (make-parameter ""))

(define (go-deprecated m)
  (if (hash-ref m 'deprecated #f)
      "// Deprecated: marked deprecated in the proto schema.
"
      ""))

(define (go-client-method* m)
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define path (hash-ref m 'path))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(unary)
     (format (string-append
              "func (c *~aClient) ~a(ctx context.Context, req *~a) (*~a, error) {\n"
              "\tresp := new(~a)\n"
              "\tif err := c.Channel.Unary(ctx, ~s, req, resp); err != nil {\n"
              "\t\treturn nil, err\n"
              "\t}\n"
              "\treturn resp, nil\n"
              "}\n")
             svc name req resp resp path)]
    [(server-streaming)
     (format (string-append
              "func (c *~aClient) ~a(ctx context.Context, req *~a) (*~a~aStream, error) {\n"
              "\tstream, err := c.Channel.ServerStream(ctx, ~s, req)\n"
              "\tif err != nil {\n"
              "\t\treturn nil, err\n"
              "\t}\n"
              "\treturn &~a~aStream{stream: stream}, nil\n"
              "}\n\n"
              "type ~a~aStream struct{ stream *grpcdc.ClientStream }\n\n"
              "func (s *~a~aStream) Recv() (*~a, error) {\n"
              "\tresp := new(~a)\n"
              "\tif err := s.stream.Recv(resp); err != nil {\n"
              "\t\treturn nil, err\n"
              "\t}\n"
              "\treturn resp, nil\n"
              "}\n")
             svc name req svc name path svc name svc name svc name resp resp)]
    [(client-streaming)
     (format (string-append
              "func (c *~aClient) ~a(ctx context.Context, reqs ...*~a) (*~a, error) {\n"
              "\tgrpcdcReqs := make([]grpcdc.Marshaler, len(reqs))\n"
              "\tfor i, r := range reqs {\n"
              "\t\tgrpcdcReqs[i] = r\n"
              "\t}\n"
              "\tresp := new(~a)\n"
              "\tif err := c.Channel.ClientStreamCall(ctx, ~s, grpcdcReqs, resp); err != nil {\n"
              "\t\treturn nil, err\n"
              "\t}\n"
              "\treturn resp, nil\n"
              "}\n")
             svc name req resp resp path)]
    [(bidi)
     (format (string-append
              "func (c *~aClient) ~a(ctx context.Context, reqs ...*~a) (*~a~aStream, error) {\n"
              "\tgrpcdcReqs := make([]grpcdc.Marshaler, len(reqs))\n"
              "\tfor i, r := range reqs {\n"
              "\t\tgrpcdcReqs[i] = r\n"
              "\t}\n"
              "\tstream, err := c.Channel.Bidi(ctx, ~s, grpcdcReqs)\n"
              "\tif err != nil {\n"
              "\t\treturn nil, err\n"
              "\t}\n"
              "\treturn &~a~aStream{stream: stream}, nil\n"
              "}\n\n"
              "type ~a~aStream struct{ stream *grpcdc.ClientStream }\n\n"
              "func (s *~a~aStream) Recv() (*~a, error) {\n"
              "\tresp := new(~a)\n"
              "\tif err := s.stream.Recv(resp); err != nil {\n"
              "\t\treturn nil, err\n"
              "\t}\n"
              "\treturn resp, nil\n"
              "}\n")
             svc name req svc name path svc name svc name svc name resp resp)]))

(define (go-server-iface-method/deprecated m)
  (string-append
   (if (hash-ref m 'deprecated #f)
       "\t// Deprecated: marked deprecated in the proto schema.
"
       "")
   (go-server-iface-method m)))

(define (go-server-iface-method m)
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(unary)
     (format "\t~a(context.Context, *~a) (*~a, error)\n" name req resp)]
    [(server-streaming)
     (format "\t~a(*~a, ~a~aServer) error\n" name req svc name)]
    [(client-streaming)
     (format "\t~a(~a~aServer) error\n" name svc name)]
    [(bidi)
     (format "\t~a(~a~aServer) error\n" name svc name)]))

(define (go-stream-ifaces m)
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(unary) ""]
    [(server-streaming)
     (format (string-append
              "type ~a~aServer interface {\n"
              "\tSend(*~a) error\n"
              "\tContext() context.Context\n"
              "}\n\n")
             svc name resp)]
    [(client-streaming)
     (format (string-append
              "type ~a~aServer interface {\n"
              "\tRecv() (*~a, error)\n"
              "\tSendAndClose(*~a) error\n"
              "\tContext() context.Context\n"
              "}\n\n")
             svc name req resp)]
    [(bidi)
     (format (string-append
              "type ~a~aServer interface {\n"
              "\tSend(*~a) error\n"
              "\tRecv() (*~a, error)\n"
              "\tContext() context.Context\n"
              "}\n\n")
             svc name resp req)]))

(define (go-register-method m)
  (define name (hash-ref m 'name))
  (define impl-name (method-impl-name m))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(unary)
     (format (string-append
              "\t\t{Name: ~s, Path: ~s, Kind: grpcdc.KindUnary, Handler: func(ctx context.Context, reqs *grpcdc.RequestStream, sink grpcdc.ServerSink) error {\n"
              "\t\t\treq := new(~a)\n"
              "\t\t\tif err := reqs.RecvInto(req); err != nil {\n"
              "\t\t\t\treturn err\n"
              "\t\t\t}\n"
              "\t\t\tresp, err := srv.~a(ctx, req)\n"
              "\t\t\tif err != nil {\n"
              "\t\t\t\treturn err\n"
              "\t\t\t}\n"
              "\t\t\treturn sink.Send(resp.MarshalDC())\n"
              "\t\t}},\n")
             name (hash-ref m 'path) req impl-name)]
    [(server-streaming)
     (format (string-append
              "\t\t{Name: ~s, Path: ~s, Kind: grpcdc.KindServerStreaming, Handler: func(ctx context.Context, reqs *grpcdc.RequestStream, sink grpcdc.ServerSink) error {\n"
              "\t\t\treq := new(~a)\n"
              "\t\t\tif err := reqs.RecvInto(req); err != nil {\n"
              "\t\t\t\treturn err\n"
              "\t\t\t}\n"
              "\t\t\treturn srv.~a(req, &~a~aServerImpl{ctx: ctx, sink: sink})\n"
              "\t\t}},\n")
             name (hash-ref m 'path) req impl-name svc impl-name)]
    [(client-streaming)
     (format (string-append
              "\t\t{Name: ~s, Path: ~s, Kind: grpcdc.KindClientStreaming, Handler: func(ctx context.Context, reqs *grpcdc.RequestStream, sink grpcdc.ServerSink) error {\n"
              "\t\t\tstream := &~a~aServerImpl{ctx: ctx, reqs: reqs}\n"
              "\t\t\tif err := srv.~a(stream); err != nil {\n"
              "\t\t\t\treturn err\n"
              "\t\t\t}\n"
              "\t\t\tif stream.resp == nil {\n"
              "\t\t\t\treturn grpcdc.NewStatus(grpcdc.CodeInternal, \"client-streaming handler never called SendAndClose\")\n"
              "\t\t\t}\n"
              "\t\t\treturn sink.Send(stream.resp.MarshalDC())\n"
              "\t\t}},\n")
             name (hash-ref m 'path) svc impl-name impl-name)]
    [(bidi)
     (format (string-append
              "\t\t{Name: ~s, Path: ~s, Kind: grpcdc.KindBidi, Handler: func(ctx context.Context, reqs *grpcdc.RequestStream, sink grpcdc.ServerSink) error {\n"
              "\t\t\treturn srv.~a(&~a~aServerImpl{ctx: ctx, reqs: reqs, sink: sink})\n"
              "\t\t}},\n")
             name (hash-ref m 'path) impl-name svc impl-name)]))

(define (go-stream-impls m)
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define svc (current-service))
  (case (hash-ref m 'kind)
    [(unary) ""]
    [(server-streaming)
     (format (string-append
              "type ~a~aServerImpl struct {\n"
              "\tctx  context.Context\n"
              "\tsink grpcdc.ServerSink\n"
              "}\n\n"
              "func (s *~a~aServerImpl) Send(resp *~a) error {\n\treturn s.sink.Send(resp.MarshalDC())\n}\n"
              "func (s *~a~aServerImpl) Context() context.Context { return s.ctx }\n\n")
             svc name svc name resp svc name)]
    [(client-streaming)
     (format (string-append
              "type ~a~aServerImpl struct {\n"
              "\tctx  context.Context\n"
              "\treqs *grpcdc.RequestStream\n"
              "\tresp *~a\n"
              "}\n\n"
              "func (s *~a~aServerImpl) Recv() (*~a, error) {\n"
              "\treq := new(~a)\n"
              "\tif err := s.reqs.RecvInto(req); err != nil {\n"
              "\t\treturn nil, err\n"
              "\t}\n"
              "\treturn req, nil\n"
              "}\n"
              "func (s *~a~aServerImpl) SendAndClose(resp *~a) error {\n"
              "\ts.resp = resp\n"
              "\treturn nil\n"
              "}\n"
              "func (s *~a~aServerImpl) Context() context.Context { return s.ctx }\n\n")
             svc name resp svc name req req svc name resp svc name)]
    [(bidi)
     (format (string-append
              "type ~a~aServerImpl struct {\n"
              "\tctx  context.Context\n"
              "\treqs *grpcdc.RequestStream\n"
              "\tsink grpcdc.ServerSink\n"
              "}\n\n"
              "func (s *~a~aServerImpl) Send(resp *~a) error {\n\treturn s.sink.Send(resp.MarshalDC())\n}\n"
              "func (s *~a~aServerImpl) Recv() (*~a, error) {\n"
              "\treq := new(~a)\n"
              "\tif err := s.reqs.RecvInto(req); err != nil {\n"
              "\t\treturn nil, err\n"
              "\t}\n"
              "\treturn req, nil\n"
              "}\n"
              "func (s *~a~aServerImpl) Context() context.Context { return s.ctx }\n\n")
             svc name svc name resp svc name req req svc name)]))

(define (go-service svc)
  (define sname (hash-ref svc 'name))
  (define methods (hash-ref svc 'methods))
  (parameterize ([current-service sname])
    (string-append
     (format "type ~aClient struct {\n\tChannel *grpcdc.Channel\n}\n\n" sname)
     (format "func New~aClient(ch *grpcdc.Channel) *~aClient {\n\treturn &~aClient{Channel: ch}\n}\n\n" sname sname sname)
     (apply string-append (map (lambda (m) (string-append (go-deprecated m) (go-client-method* m))) (append methods (alias-client-methods svc))))
     "\n"
     (format "type ~aServer interface {\n" sname)
     (apply string-append (map go-server-iface-method/deprecated methods))
     "}\n\n"
     (apply string-append (map go-stream-ifaces methods))
     (apply string-append (map go-stream-impls methods))
     (format "func Register~aServer(s *grpcdc.Server, srv ~aServer) {\n" sname sname)
     (format "\ts.RegisterService(grpcdc.ServiceDesc{\n\t\tName: ~s,\n\t\tMethods: []grpcdc.Method{\n"
             (hash-ref svc 'full-name))
     (apply string-append (map go-register-method (append methods (alias-server-methods svc))))
     "\t\t},\n\t})\n}\n")))

;; ---------------------------------------------------------------------------
;; Go message types (<base>_pb.go): structs implementing
;; MarshalDC/UnmarshalDC, dependency-free (stdlib only). Mirrors
;; the Python/JS emitters on the shared desc.rkt model. Cross-file
;; types resolve to the same generated naming, so files generated
;; into one Go package link together.
;; ---------------------------------------------------------------------------

(define go-pb-varint-types '(5 3 13 4 17 18 8 14))
(define go-pb-fixed '((2 4 "Float32") (1 8 "Float64") (7 4 "Uint32") (15 4 "Int32") (6 8 "BigUint64") (16 8 "BigInt64")))

(define go-pb-preamble
  (string-append
   "func appendVarint(out []byte, v uint64) []byte {\n\tfor v > 0x7f {\n\t\tout = append(out, byte(v&0x7f)|0x80)\n\t\tv >>= 7\n\t}\n\treturn append(out, byte(v))\n}\n\n"
   "func appendTag(out []byte, field int, wire int) []byte {\n\treturn appendVarint(out, uint64(field<<3|wire))\n}\n\n"
   "func appendBytesField(out []byte, field int, payload []byte) []byte {\n\tout = appendTag(out, field, 2)\n\tout = appendVarint(out, uint64(len(payload)))\n\treturn append(out, payload...)\n}\n\n"
   "func appendStringField(out []byte, field int, value string) []byte {\n\tif value == \"\" {\n\t\treturn out\n\t}\n\treturn appendBytesField(out, field, []byte(value))\n}\n\n"
   "func zz32(v int32) uint64 { return uint64(uint32((v << 1) ^ (v >> 31))) }\n\nfunc zz64(v int64) uint64 { return uint64((v << 1) ^ (v >> 63)) }\n\n"
   "func unzz32(v uint64) int32 { return int32(uint32(v>>1) ^ uint32(-int32(v&1))) }\n\nfunc unzz64(v uint64) int64 { return int64(v>>1) ^ -int64(v&1) }\n\n"
   "type pbReader struct {\n\tbuf []byte\n\tpos int\n}\n\n"
   "func (r *pbReader) varint() (uint64, error) {\n\tvar result uint64\n\tvar shift uint\n\tfor {\n\t\tif r.pos >= len(r.buf) {\n\t\t\treturn 0, errors.New(\"truncated varint\")\n\t\t}\n\t\tb := r.buf[r.pos]\n\t\tr.pos++\n\t\tresult |= uint64(b&0x7f) << shift\n\t\tif b&0x80 == 0 {\n\t\t\treturn result, nil\n\t\t}\n\t\tshift += 7\n\t\tif shift >= 64 {\n\t\t\treturn 0, errors.New(\"varint too long\")\n\t\t}\n\t}\n}\n\n"
   "func (r *pbReader) take(n int) ([]byte, error) {\n\tif r.pos+n > len(r.buf) {\n\t\treturn nil, errors.New(\"truncated field\")\n\t}\n\tv := r.buf[r.pos : r.pos+n]\n\tr.pos += n\n\treturn v, nil\n}\n\n"
   "// field returns (number, value, done, error); value is uint64 for\n// varints and []byte for length-delimited/fixed fields.\n"
   "func (r *pbReader) field() (int, int, any, []byte, bool, error) {\n\tif r.pos >= len(r.buf) {\n\t\treturn 0, 0, nil, nil, true, nil\n\t}\n\tstart := r.pos\n\ttag, err := r.varint()\n\tif err != nil {\n\t\treturn 0, 0, nil, nil, false, err\n\t}\n\tnum := int(tag >> 3)\n\twire := int(tag & 7)\n\tswitch wire {\n\tcase 0:\n\t\tv, err := r.varint()\n\t\treturn num, wire, v, r.buf[start:r.pos], false, err\n\tcase 2:\n\t\tn, err := r.varint()\n\t\tif err != nil {\n\t\t\treturn 0, 0, nil, nil, false, err\n\t\t}\n\t\tv, err := r.take(int(n))\n\t\treturn num, wire, v, r.buf[start:r.pos], false, err\n\tcase 1:\n\t\tv, err := r.take(8)\n\t\treturn num, wire, v, r.buf[start:r.pos], false, err\n\tcase 5:\n\t\tv, err := r.take(4)\n\t\treturn num, wire, v, r.buf[start:r.pos], false, err\n\tdefault:\n\t\treturn 0, 0, nil, nil, false, errors.New(\"bad wire type\")\n\t}\n}\n\n"))

(define (go-pb-pascal s)
  (string-join
   (map (lambda (part)
          (if (string=? part "") "" (string-append (string (char-upcase (string-ref part 0))) (substring part 1))))
        (string-split s "_")) ""))

(define (go-pb-flat pkg full)
  (define rel (if (and pkg (not (string=? pkg ""))
                       (string-prefix? full (string-append pkg ".")))
                  (substring full (add1 (string-length pkg)))
                  full))
  (string-join (string-split rel ".") "_"))

(define (go-pb-resolve model type-name)
  (hash-ref (hash-ref model 'types) type-name
            (lambda () (error 'emit-go-pb-file "unresolved type ~a" type-name))))

(define (go-pb-entry-type entry)
  (go-pb-flat (hash-ref entry 'pkg)
              (if (eq? (hash-ref entry 'kind) 'enum)
                  ;; 'full is the fully-qualified name, parent
                  ;; message included: nested enums must not
                  ;; collide on their simple name (registry enum
                  ;; entries carry no parent in 'msg).
                  (hash-ref entry 'full)
                  (hash-ref (hash-ref entry 'msg) 'full-name))))

(define (go-pb-scalar-type f)
  (case (hash-ref f 'type)
    [(1) "float64"] [(2) "float32"] [(3) "int64"] [(4) "uint64"] [(5) "int32"]
    [(6) "uint64"] [(7) "uint32"] [(8) "bool"] [(9) "string"] [(12) "[]byte"]
    [(13) "uint32"] [(15) "int32"] [(16) "int64"] [(17) "int32"] [(18) "int64"]
    [else #f]))

(define (go-pb-field-type model f)
  (define type (hash-ref f 'type))
  (define base
    (cond [(= type 11)
           (define entry (go-pb-resolve model (hash-ref f 'type-name)))
           (if (eq? (hash-ref entry 'kind) 'map)
               (let* ([entry-msg (hash-ref entry 'msg)]
                      [kf (findf (lambda (x) (= (hash-ref x 'number) 1)) (hash-ref entry-msg 'fields))]
                      [vf (findf (lambda (x) (= (hash-ref x 'number) 2)) (hash-ref entry-msg 'fields))])
                 (format "map[~a]~a" (go-pb-field-type model (hash-set kf 'label 1))
                         (go-pb-field-type model (hash-set vf 'label 1))))
               (string-append "*" (go-pb-entry-type entry)))]
          [(= type 14) (go-pb-entry-type (go-pb-resolve model (hash-ref f 'type-name)))]
          [else (go-pb-scalar-type f)]))
  (if (= (hash-ref f 'label) 3)
      (if (and (= type 11)
               (eq? (hash-ref (go-pb-resolve model (hash-ref f 'type-name)) 'kind) 'map))
          base
          (string-append "[]" base))
      base))

(define (go-pb-varint-expr f v)
  (case (hash-ref f 'type)
    [(8) (format "boolToUint64(~a)" v)]
    [(17) (format "zz32(~a)" v)]
    [(18) (format "zz64(~a)" v)]
    [(5 14) (format "uint64(int64(~a))" v)]
    [(3) (format "uint64(~a)" v)]
    [else (format "uint64(~a)" v)]))

(define (go-pb-varint-decode f v)
  (case (hash-ref f 'type)
    [(5) (format "int32(~a)" v)]
    [(14) (format "int32(~a)" v)]
    [(13) (format "uint32(~a)" v)]
    [(3) (format "int64(~a)" v)]
    [(4) v]
    [(8) (format "~a != 0" v)]
    [(17) (format "unzz32(~a)" v)]
    [(18) (format "unzz64(~a)" v)]))

(define (go-pb-fixed-decode info v)
  (case (third info)
    [("Float32") (format "pbFloat32FromBits(binary.LittleEndian.Uint32(~a))" v)]
    [("Float64") (format "pbFloat64FromBits(binary.LittleEndian.Uint64(~a))" v)]
    [("Uint32") (format "binary.LittleEndian.Uint32(~a)" v)]
    [("Int32") (format "int32(binary.LittleEndian.Uint32(~a))" v)]
    [("BigUint64") (format "binary.LittleEndian.Uint64(~a)" v)]
    [("BigInt64") (format "int64(binary.LittleEndian.Uint64(~a))" v)]))

(define (go-pb-fixed-encode info v)
  (case (third info)
    [("Float32") (format "fixed32Bytes(pbFloat32Bits(~a))" v)]
    [("Float64") (format "fixed64Bytes(pbFloat64Bits(~a))" v)]
    [("Uint32") (format "fixed32Bytes(~a)" v)]
    [("Int32") (format "fixed32Bytes(uint32(~a))" v)]
    [("BigUint64") (format "fixed64Bytes(~a)" v)]
    [("BigInt64") (format "fixed64Bytes(uint64(~a))" v)]))

(define (go-pb-zero f)
  (case (hash-ref f 'type)
    [(11 12) "nil"]
    [(9) "\"\""]
    [(8) "false"]
    [else "0"]))

(define (go-pb-oneof-clearing model f)
  (apply string-append
         (map (lambda (sib)
                (format "\t\t\tm.~a = ~a\n" (go-pb-pascal (hash-ref sib 'name)) (go-pb-zero sib)))
              (oneof-siblings model f))))

(define (go-pb-encode-singular model f v indent)
  (define n (hash-ref f 'number))
  (define type (hash-ref f 'type))
  ;; Proto2 optional/required fields have explicit presence.
  (define proto2? (equal? (hash-ref model 'syntax "") "proto2"))
  (cond [(memv type go-pb-varint-types)
         (if proto2?
             (string-append
              (format "~aout = appendTag(out, ~a, 0)\n" indent n)
              (format "~aout = appendVarint(out, ~a)\n" indent (go-pb-varint-expr f v)))
             (string-append
              (format "~aif ~a {\n" indent (if (= type 8) v (format "~a != 0" v)))
              (format "~a\tout = appendTag(out, ~a, 0)\n" indent n)
              (format "~a\tout = appendVarint(out, ~a)\n" indent (go-pb-varint-expr f v))
              (format "~a}\n" indent)))]
        [(assv type go-pb-fixed)
         => (lambda (info)
              (if proto2?
                  (string-append
                   (format "~aout = appendTag(out, ~a, ~a)\n" indent n (if (= (second info) 8) 1 5))
                   (format "~aout = append(out, ~a...)\n" indent (go-pb-fixed-encode info v)))
                  (string-append
                   (format "~aif ~a != 0 {\n" indent v)
                   (format "~a\tout = appendTag(out, ~a, ~a)\n" indent n (if (= (second info) 8) 1 5))
                   (format "~a\tout = append(out, ~a...)\n" indent (go-pb-fixed-encode info v))
                   (format "~a}\n" indent))))]
        [(= type 9)
         (if proto2?
             (format "~aout = appendBytesField(out, ~a, []byte(~a))\n" indent n v)
             (format "~aout = appendStringField(out, ~a, ~a)\n" indent n v))]
        [(= type 12)
         (if proto2?
             (format "~aout = appendBytesField(out, ~a, ~a)\n" indent n v)
             (format "~aif len(~a) > 0 {\n~a\tout = appendBytesField(out, ~a, ~a)\n~a}\n" indent v indent n v indent))]
        [(= type 11)
         (format "~aif ~a != nil {\n~a\tout = appendBytesField(out, ~a, ~a.MarshalDC())\n~a}\n" indent v indent n v indent)]
        [else (error 'emit-go-pb-file "unsupported field type ~a (groups)" type)]))

(define (go-pb-set-expr sib)
  (define v (format "m.~a" (go-pb-pascal (hash-ref sib 'name))))
  (case (hash-ref sib 'type)
    [(11 10) (format "~a != nil" v)]
    [(9) (format "~a != \"\"" v)]
    [(12) (format "len(~a) > 0" v)]
    [(8) v]
    [else (format "~a != 0" v)]))

;; Encode-side oneof clearing: suppress f when a later sibling is
;; set, so only the winning member is written.
(define (go-pb-encode-guard model f code)
  (define later (oneof-later-siblings model f))
  (if (null? later)
      code
      (format "\tif !(~a) {\n~a\t}\n"
              (string-join (map go-pb-set-expr later) " || ")
              (if (string-suffix? code "\n") code (string-append code "\n")))))

(define (go-pb-encode-field model f)
  (define fname (go-pb-pascal (hash-ref f 'name)))
  (define v (format "m.~a" fname))
  (define n (hash-ref f 'number))
  (define type (hash-ref f 'type))
  (cond [(and (= type 11)
              (eq? (hash-ref (go-pb-resolve model (hash-ref f 'type-name)) 'kind) 'map))
         (define entry (go-pb-resolve model (hash-ref f 'type-name)))
         (define helper (format "encode~a" (go-pb-entry-type entry)))
         (define key-f (findf (lambda (x) (= (hash-ref x 'number) 1)) (hash-ref (hash-ref entry 'msg) 'fields)))
         (define kt (go-pb-field-type model (hash-set key-f 'label 1)))
         (format "\t{\n\t\tkeys := make([]~a, 0, len(~a))\n\t\tfor k := range ~a { keys = append(keys, k) }\n\t\tsort.Slice(keys, func(i, j int) bool { return keys[i] < keys[j] })\n\t\tfor _, k := range keys {\n\t\t\tout = appendBytesField(out, ~a, ~a(k, ~a[k]))\n\t\t}\n\t}\n" kt v v n helper v)]
        [(not (= (hash-ref f 'label) 3)) (go-pb-encode-singular model f v "\t")]
        [(memv type go-pb-varint-types)
         (string-append
          (format "\tif len(~a) > 0 {\n\t\tvar payload []byte\n" v)
          (format "\t\tfor _, x := range ~a {\n\t\t\tpayload = appendVarint(payload, ~a)\n\t\t}\n" v (go-pb-varint-expr f "x"))
          (format "\t\tout = appendBytesField(out, ~a, payload)\n\t}\n" n))]
        [(assv type go-pb-fixed)
         => (lambda (info)
              (string-append
               (format "\tif len(~a) > 0 {\n\t\tvar payload []byte\n" v)
               (format "\t\tfor _, x := range ~a {\n\t\t\tpayload = append(payload, ~a...)\n\t\t}\n" v (go-pb-fixed-encode info "x"))
               (format "\t\tout = appendBytesField(out, ~a, payload)\n\t}\n" n)))]
        [(= type 9)
         (format "\tfor _, x := range ~a {\n\t\tout = appendBytesField(out, ~a, []byte(x))\n\t}\n" v n)]
        [(= type 12)
         (format "\tfor _, x := range ~a {\n\t\tout = appendBytesField(out, ~a, x)\n\t}\n" v n)]
        [(= type 11)
         (format "\tfor _, x := range ~a {\n\t\tout = appendBytesField(out, ~a, x.MarshalDC())\n\t}\n" v n)]
        [else (error 'emit-go-pb-file "unsupported repeated field type ~a" type)]))

(define go-pb-error-stmt (make-parameter "return err"))

(define (go-pb-decode-singular model f target src indent)
  (define type (hash-ref f 'type))
  (cond [(memv type go-pb-varint-types)
         (define conv (go-pb-varint-decode f src))
         (format "~a~a = ~a\n" indent target
                 (if (= type 14)
                     (format "~a(~a)" (go-pb-entry-type (go-pb-resolve model (hash-ref f 'type-name))) (go-pb-varint-decode (hash-set f 'type 5) src))
                     conv))]
        [(assv type go-pb-fixed)
         => (lambda (info) (format "~a~a = ~a\n" indent target (go-pb-fixed-decode info src)))]
        [(= type 9) (format "~a~a = string(~a)\n" indent target src)]
        [(= type 12) (format "~a~a = append([]byte(nil), ~a...)\n" indent target src)]
        [(= type 11)
         (define entry (go-pb-resolve model (hash-ref f 'type-name)))
         (define tname (go-pb-entry-type entry))
         (string-append
          (format "~atmp~a := new(~a)\n" indent (hash-ref f 'number) tname)
          (format "~aif err := tmp~a.UnmarshalDC(~a); err != nil {\n~a\t~a\n~a}\n" indent (hash-ref f 'number) src indent (go-pb-error-stmt) indent)
          (format "~a~a = tmp~a\n" indent target (hash-ref f 'number)))]
        [else (error 'emit-go-pb-file "unsupported field type ~a" type)]))

(define (go-pb-decode-case model f)
  (define fname (go-pb-pascal (hash-ref f 'name)))
  (define target (format "m.~a" fname))
  (define type (hash-ref f 'type))
  (define head (format "\t\tcase ~a:\n" (hash-ref f 'number)))
  (cond [(and (= type 11)
              (eq? (hash-ref (go-pb-resolve model (hash-ref f 'type-name)) 'kind) 'map))
         (define entry (go-pb-resolve model (hash-ref f 'type-name)))
         (define helper (format "decode~a" (go-pb-entry-type entry)))
         (string-append
          head
          "\t\t\tif b, ok := value.([]byte); ok {\n"
          (format "\t\t\t\tk, val, err := ~a(b)\n" helper)
          "\t\t\t\tif err != nil {\n\t\t\t\t\treturn err\n\t\t\t\t}\n"
          (format "\t\t\t\tif ~a == nil {\n\t\t\t\t\t~a = make(~a)\n\t\t\t\t}\n" target target (go-pb-field-type model f))
          (format "\t\t\t\t~a[k] = val\n\t\t\t}\n" target))]
        [(not (= (hash-ref f 'label) 3))
         (string-append head
                        (go-pb-oneof-clearing model f)
                        (if (memv type go-pb-varint-types)
                            (format "\t\t\tif v, ok := value.(uint64); ok {\n~a\t\t\t}\n"
                                    (go-pb-decode-singular model f target "v" "\t\t\t\t"))
                            (format "\t\t\tif b, ok := value.([]byte); ok {\n~a\t\t\t}\n"
                                    (go-pb-decode-singular model f target "b" "\t\t\t\t"))))]
        [(memv type go-pb-varint-types)
         (string-append
          head
          "\t\t\tswitch value := value.(type) {\n"
          "\t\t\tcase uint64:\n"
          (format "\t\t\t\t~a = append(~a, ~a)\n" target target
                  (let ([conv (go-pb-varint-decode f "value")])
                    (if (= type 14) (format "~a(~a)" (go-pb-entry-type (go-pb-resolve model (hash-ref f 'type-name))) (go-pb-varint-decode (hash-set f 'type 5) "value")) conv)))
          "\t\t\tcase []byte:\n"
          "\t\t\t\tsub := &pbReader{buf: value}\n"
          "\t\t\t\tfor sub.pos < len(sub.buf) {\n"
          "\t\t\t\t\tv, err := sub.varint()\n\t\t\t\t\tif err != nil {\n\t\t\t\t\t\treturn err\n\t\t\t\t\t}\n"
          (format "\t\t\t\t\t~a = append(~a, ~a)\n" target target
                  (let ([conv (go-pb-varint-decode f "v")])
                    (if (= type 14) (format "~a(~a)" (go-pb-entry-type (go-pb-resolve model (hash-ref f 'type-name))) (go-pb-varint-decode (hash-set f 'type 5) "v")) conv)))
          "\t\t\t\t}\n\t\t\t}\n")]
        [(assv type go-pb-fixed)
         => (lambda (info)
              (define size (second info))
              (string-append
               head
               "\t\t\tif b, ok := value.([]byte); ok {\n"
               (format "\t\t\t\tif len(b) == ~a {\n" size)
               (format "\t\t\t\t\t~a = append(~a, ~a)\n" target target (go-pb-fixed-decode info "b"))
               "\t\t\t\t} else {\n"
               (format "\t\t\t\t\tfor off := 0; off+~a <= len(b); off += ~a {\n" size size)
               (format "\t\t\t\t\t\t~a = append(~a, ~a)\n" target target (go-pb-fixed-decode info (format "b[off:off+~a]" size)))
               "\t\t\t\t\t}\n\t\t\t\t}\n\t\t\t}\n"))]
        [(= type 9) (format "~a\t\t\tif b, ok := value.([]byte); ok {\n\t\t\t\t~a = append(~a, string(b))\n\t\t\t}\n" head target target)]
        [(= type 12) (format "~a\t\t\tif b, ok := value.([]byte); ok {\n\t\t\t\t~a = append(~a, append([]byte(nil), b...))\n\t\t\t}\n" head target target)]
        [(= type 11)
         (string-append head
                        "\t\t\tif b, ok := value.([]byte); ok {\n"
                        (format "\t\t\t\tvar tmpv ~a\n" (go-pb-field-type model (hash-set f 'label 1)))
                        (go-pb-decode-singular model f "tmpv" "b" "\t\t\t\t")
                        (format "\t\t\t\t~a = append(~a, tmpv)\n\t\t\t}\n" target target))]
        [else (error 'emit-go-pb-file "unsupported repeated field type ~a" type)]))

(define (go-pb-map-helpers model entry)
  (define msg (hash-ref entry 'msg))
  (define base (go-pb-entry-type entry))
  (define key-f (findf (lambda (x) (= (hash-ref x 'number) 1)) (hash-ref msg 'fields)))
  (define val-f (findf (lambda (x) (= (hash-ref x 'number) 2)) (hash-ref msg 'fields)))
  (unless (and key-f val-f) (error 'emit-go-pb-file "map entry ~a lacks key/value" (hash-ref msg 'full-name)))
  (define kt (go-pb-field-type model (hash-set key-f 'label 1)))
  (define vt (go-pb-field-type model (hash-set val-f 'label 1)))
  (parameterize ([go-pb-error-stmt "return key, value, err"])
  (string-append
   (format "func encode~a(key ~a, value ~a) []byte {\n\tvar out []byte\n" base kt vt)
   (go-pb-encode-singular model key-f "key" "\t")
   (go-pb-encode-singular model val-f "value" "\t")
   "\treturn out\n}\n\n"
   (format "func decode~a(data []byte) (~a, ~a, error) {\n" base kt vt)
   (format "\tvar key ~a\n\tvar value ~a\n" kt vt)
   "\tr := &pbReader{buf: data}\n\tfor {\n\t\tnum, _, value0, _, done, err := r.field()\n\t\tif err != nil {\n\t\t\treturn key, value, err\n\t\t}\n\t\tif done {\n\t\t\treturn key, value, nil\n\t\t}\n\t\tswitch num {\n"
   (format "\t\tcase ~a:\n" (hash-ref key-f 'number))
   (if (memv (hash-ref key-f 'type) go-pb-varint-types)
       (format "\t\t\tif v, ok := value0.(uint64); ok {\n~a\t\t\t}\n" (go-pb-decode-singular model key-f "key" "v" "\t\t\t\t"))
       (format "\t\t\tif b, ok := value0.([]byte); ok {\n~a\t\t\t}\n" (go-pb-decode-singular model key-f "key" "b" "\t\t\t\t")))
   (format "\t\tcase ~a:\n" (hash-ref val-f 'number))
   (if (memv (hash-ref val-f 'type) go-pb-varint-types)
       (format "\t\t\tif v, ok := value0.(uint64); ok {\n~a\t\t\t}\n" (go-pb-decode-singular model val-f "value" "v" "\t\t\t\t"))
       (format "\t\t\tif b, ok := value0.([]byte); ok {\n~a\t\t\t}\n" (go-pb-decode-singular model val-f "value" "b" "\t\t\t\t")))
   "\t\t}\n\t}\n}\n\n")))

(define (go-pb-enum entry)
  (define e (hash-ref entry 'enum))
  (define tname (go-pb-entry-type entry))
  (string-append
   (format "type ~a int32\n\nconst (\n" tname)
   (apply string-append
          (map (lambda (v) (format "\t~a_~a ~a = ~a\n" tname (hash-ref v 'name) tname (hash-ref v 'number)))
               (hash-ref e 'values)))
   ")\n\n"))

(define (go-pb-default-literal model f)
  (define d (field-explicit-default f))
  (and d
       (case (hash-ref f 'type)
         [(9) (format "~s" d)]
         [(14) (format "~a(~a)" (go-pb-entry-type (go-pb-resolve model (hash-ref f 'type-name))) (enum-default-number model f))]
         [else d])))

(define (go-pb-constructor model msg)
  (define name (go-pb-flat (hash-ref model 'package) (hash-ref msg 'full-name)))
  (define inits
    (filter values
            (map (lambda (f)
                   (define lit (go-pb-default-literal model f))
                   (and lit (format "\t~a: ~a,\n" (go-pb-pascal (hash-ref f 'name)) lit)))
                 (hash-ref msg 'fields))))
  (if (null? inits)
      ""
      (string-append
       (format "// New~a returns a ~a with the descriptor's explicit (proto2)\n// default values applied.\n" name name)
       (format "func New~a() *~a {\n\treturn &~a{\n" name name name)
       (apply string-append inits)
       "\t}\n}\n\n")))

(define (go-pb-message model msg)
  (define name (go-pb-flat (hash-ref model 'package) (hash-ref msg 'full-name)))
  (string-append
   (format "type ~a struct {\n" name)
   (apply string-append
          (map (lambda (f) (format "\t~a ~a\n" (go-pb-pascal (hash-ref f 'name)) (go-pb-field-type model f)))
               (hash-ref msg 'fields)))
   "\tUnknownFields []byte\n"
   "}\n\n"
   (go-pb-constructor model msg)
   (format "func (m *~a) MarshalDC() []byte {\n\tvar out []byte\n" name)
   (apply string-append (map (lambda (f) (go-pb-encode-guard model f (go-pb-encode-field model f))) (hash-ref msg 'fields)))
   "\tout = append(out, m.UnknownFields...)\n"
   "\treturn out\n}\n\n"
   (format "func (m *~a) UnmarshalDC(data []byte) error {\n" name)
   "\tm.UnknownFields = nil\n"
   "\tr := &pbReader{buf: data}\n\tfor {\n"
   (if (null? (hash-ref msg 'fields))
       "\t\tnum, _, _, raw, done, err := r.field()\n"
       "\t\tnum, _, value, raw, done, err := r.field()\n")
   "\t\tif err != nil {\n\t\t\treturn err\n\t\t}\n\t\tif done {\n\t\t\treturn nil\n\t\t}\n\t\tswitch num {\n"
   (apply string-append (map (lambda (f) (go-pb-decode-case model f)) (hash-ref msg 'fields)))
   "\t\tdefault:\n\t\t\tm.UnknownFields = append(m.UnknownFields, raw...)\n"
   "\t\t}\n\t}\n}\n\n"))

(define (go-pb-apply-prefix content prefix)
  ;; Helper identifiers are file-scoped so several generated
  ;; <base>_pb.go files can share one Go package.
  (for/fold ([s content])
            ([pair (in-list '(("appendVarint" "AppendVarint")
                              ("appendTag" "AppendTag")
                              ("appendBytesField" "AppendBytesField")
                              ("appendStringField" "AppendStringField")
                              ("boolToUint64" "BoolToUint64")
                              ("fixed32Bytes" "Fixed32Bytes")
                              ("fixed64Bytes" "Fixed64Bytes")
                              ("pbFloat32Bits" "Float32Bits")
                              ("pbFloat32FromBits" "Float32FromBits")
                              ("pbFloat64Bits" "Float64Bits")
                              ("pbFloat64FromBits" "Float64FromBits")
                              ("pbReader" "Reader")
                              ("unzz32" "Unzz32")
                              ("unzz64" "Unzz64")
                              ("zz32" "Zz32")
                              ("zz64" "Zz64")))])
    (regexp-replace* (pregexp (string-append "\\b" (car pair) "\\b")) s
                     (string-append prefix (cadr pair)))))

(define (emit-go-pb-file file-model params)
  (and (hash-has-key? file-model 'messages)
       (hash-has-key? file-model 'types)
       (emit-go-pb-file/inner file-model params)))

(define (emit-go-pb-file/inner file-model params)
  (define messages (hash-ref file-model 'messages))
  (and (pair? messages)
       (let ()
         (define base (path->string (path-replace-extension
                                     (file-name-from-path (hash-ref file-model 'name)) "")))
         (define out (open-output-string))
         (fprintf out "// @generated by protoc-gen-grpc-dc-go. DO NOT EDIT.\n")
         (fprintf out "// source: ~a\n\n" (hash-ref file-model 'name))
         (fprintf out "package ~a\n\n" (go-package file-model params))
         (fprintf out "import (\n\t\"encoding/binary\"\n\t\"errors\"\n\t\"math\"~a\n)\n\n"
                  (if (for*/or ([msg (in-list messages)] [f (in-list (hash-ref msg 'fields))])
                        (and (= (hash-ref f 'type) 11)
                             (eq? (hash-ref (go-pb-resolve file-model (hash-ref f 'type-name)) 'kind) 'map)))
                      "\n\t\"sort\"" ""))
         (fprintf out "func boolToUint64(b bool) uint64 {\n\tif b {\n\t\treturn 1\n\t}\n\treturn 0\n}\n\n")
         (fprintf out "func fixed32Bytes(v uint32) []byte {\n\tvar b [4]byte\n\tbinary.LittleEndian.PutUint32(b[:], v)\n\treturn b[:]\n}\n\n")
         (fprintf out "func fixed64Bytes(v uint64) []byte {\n\tvar b [8]byte\n\tbinary.LittleEndian.PutUint64(b[:], v)\n\treturn b[:]\n}\n\n")
         (fprintf out "func pbFloat32Bits(f float32) uint32 { return math.Float32bits(f) }\n\nfunc pbFloat32FromBits(u uint32) float32 { return math.Float32frombits(u) }\n\nfunc pbFloat64Bits(f float64) uint64 { return math.Float64bits(f) }\n\nfunc pbFloat64FromBits(u uint64) float64 { return math.Float64frombits(u) }\n\n")
         (display go-pb-preamble out)
         (define (all-enum-entries)
           (define acc '())
           (define (walk msg)
             (for ([e (in-list (hash-ref msg 'enums))])
               (set! acc (cons (hash-ref (hash-ref file-model 'types)
                                         (format "~a.~a" (hash-ref msg 'full-name) (hash-ref e 'name)) #f) acc)))
             (for ([n (in-list (hash-ref msg 'nested))]) (walk n)))
           (for ([m (in-list messages)]) (walk m))
           (for ([e (in-list (hash-ref file-model 'enums))])
             (set! acc (cons (hash-ref (hash-ref file-model 'types)
                                       (if (string=? (hash-ref file-model 'package) "")
                                           (hash-ref e 'name)
                                           (format "~a.~a" (hash-ref file-model 'package) (hash-ref e 'name))) #f) acc)))
           (reverse acc))
         (for ([e (in-list (all-enum-entries))]) (when e (display (go-pb-enum e) out)))
         (define seen-maps (mutable-set))
         (define (emit-map-helpers msg)
           (for ([f (in-list (hash-ref msg 'fields))])
             (when (= (hash-ref f 'type) 11)
               (define e (go-pb-resolve file-model (hash-ref f 'type-name)))
               (when (and (eq? (hash-ref e 'kind) 'map)
                          ;; Skip when the entry's own file is
                          ;; generated too and emits the helpers
                          ;; itself: Go helpers are package-level
                          ;; and would collide.
                          (not (map-entry-emitted-in-own-file? file-model e))
                          (not (set-member? seen-maps (hash-ref (hash-ref e 'msg) 'full-name))))
                 (set-add! seen-maps (hash-ref (hash-ref e 'msg) 'full-name))
                 (display (go-pb-map-helpers file-model e) out))))
           (for ([n (in-list (hash-ref msg 'nested))]) (emit-map-helpers n)))
         (for ([m (in-list messages)]) (emit-map-helpers m))
         (define (emit-msg msg)
           (unless (hash-ref msg 'map-entry)
             (display (go-pb-message file-model msg) out)
             (for ([n (in-list (hash-ref msg 'nested))]) (emit-msg n))))
         (for ([m (in-list messages)]) (emit-msg m))
         (cons (string-append base "_pb.go")
               (go-pb-apply-prefix (get-output-string out)
                                   (string-append (go-pb-pascal base) "Pb"))))))

(define (emit-go-file file-model params)
  (define base (path->string (path-replace-extension
                              (file-name-from-path (hash-ref file-model 'name)) "")))
  (define stub
    (cons (string-append base "_grpc_dc.go")
          (string-append
           "// @generated by protoc-gen-grpc-dc-go. DO NOT EDIT.\n"
           (format "// source: ~a\n\n" (hash-ref file-model 'name))
           (format "package ~a\n\n" (go-package file-model params))
           (if (null? (hash-ref file-model 'services))
               ""
               "import (\n\t\"context\"\n\n\tgrpcdc \"grpcdc\"\n)\n\n")
           ;; trace=hooks: re-export the runtime tracer registrar;
           ;; trace_methods bakes the filter in at init.
           (if (and (pair? (hash-ref file-model 'services))
                    (equal? (hash-ref params 'trace #f) "hooks"))
               (string-append
                "// Tracing (trace=hooks): register an observer with\n"
                "// grpcdc.SetTracer, e.g. via the alias below.\n"
                "var SetTracer = grpcdc.SetTracer\n\n"
                "var SetTraceFilter = grpcdc.SetTraceFilter\n\n"
                (let ([methods (hash-ref params 'trace_methods #f)])
                  (if methods
                      (format "func init() { grpcdc.SetTraceFilter(~s) }\n\n" methods)
                      "")))
               "")
           (apply string-append
                  (map go-service (hash-ref file-model 'services))))))
  (define pb-file (emit-go-pb-file file-model params))
  (if pb-file (list stub pb-file) stub))
