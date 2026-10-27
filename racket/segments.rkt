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

(require "desc.rkt")

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

(define segment-programs
  (hasheq 'goRegisterMethod go-register-method-program
          'goDeprecated go-deprecated-program
          'goClientMethod go-client-method-program
          'goServerIfaceMethod go-server-iface-method-program
          'goServerIfaceMethodDeprecated go-server-iface-method-deprecated-program
          'goStreamIfaces go-stream-ifaces-program
          'goStreamImpls go-stream-impls-program
          'goService go-service-program))

;; ---------------------------------------------------------------------------
;; Racket interpreter. node: the current model hash; svc: the
;; enclosing service name ("" outside a service).
;; ---------------------------------------------------------------------------

(define (seg-ref node key)
  (if (eq? key 'impl-name)
      (hash-ref node 'impl-name (hash-ref node 'name))
      (hash-ref node key)))

(define (run-segments program node svc)
  (apply string-append
         (for/list ([seg (in-list program)])
           (run-segment seg node svc))))

(define (run-segment seg node svc)
  (cond
    [(string? seg) seg]
    [(eq? (car seg) 'fmt)
     (apply format (second seg)
            (map (lambda (e) (run-segment e node svc)) (cddr seg)))]
    [(eq? (car seg) 'ref) (seg-ref node (second seg))]
    [(eq? (car seg) 'svc) svc]
    [(eq? (car seg) 'kind-case)
     (define kind (hash-ref node 'kind))
     (define branch (assq kind (cdr seg)))
     (unless branch (error 'run-segments "no kind branch for ~e" kind))
     (run-segments (cdr branch) node svc)]
    [(eq? (car seg) 'when)
     (if (hash-ref node (second (second seg)) #f)
         (run-segments (cddr seg) node svc)
         "")]
    [(eq? (car seg) 'call)
     (run-segments (hash-ref segment-programs (second seg)) node svc)]
    [(eq? (car seg) 'each)
     (apply string-append
            (for/list ([el (in-list (hash-ref node (second seg)))])
              (run-segments (cddr seg) el svc)))]
    [(eq? (car seg) 'each+)
     (define aliases (if (eq? (third seg) 'client)
                         (alias-client-methods node)
                         (alias-server-methods node)))
     (apply string-append
            (for/list ([el (in-list (append (hash-ref node (second seg)) aliases))])
              (run-segments (cdddr seg) el svc)))]
    [else (error 'run-segments "bad segment: ~e" seg)]))
