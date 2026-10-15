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

(define (emit-go-file file-model params)
  (define base (path->string (path-replace-extension
                              (file-name-from-path (hash-ref file-model 'name)) "")))
  (cons (string-append base "_grpc_dc.go")
        (string-append
         "// @generated by protoc-gen-grpc-dc-go (Racket metaprogram). DO NOT EDIT.\n"
         (format "// source: ~a\n\n" (hash-ref file-model 'name))
         (format "package ~a\n\n" (go-package file-model params))
         "import (\n\t\"context\"\n\n\tgrpcdc \"grpcdc\"\n)\n\n"
         (apply string-append
                (map go-service (hash-ref file-model 'services))))))
