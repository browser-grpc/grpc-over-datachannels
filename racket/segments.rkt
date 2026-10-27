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
;;;
;;; The Racket interpreter below runs the native templates; the
;;; same datum is serialized by webgen.rkt into the browser
;;; generators (SEGMENT_PROGRAMS) with a JS interpreter, so the
;;; emission exists exactly once. Programs are rolled out one
;;; emitter function at a time; unconverted functions stay
;;; hand-mirrored and parity-pinned.

(provide go-register-method-program run-segments)

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
    [else (error 'run-segments "bad segment: ~e" seg)]))
