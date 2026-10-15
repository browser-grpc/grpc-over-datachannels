#lang racket

;;; template-rust.rkt — emitter body spliced into protoc-gen-grpc-dc-rust.
;;; (metagen.rkt strips the #lang / #require / #provide lines and inlines
;;;  this body into the generated plugin, after spec/pb/desc bodies.)
;;;
;;; Generated code assumes the runtime crate is named `grpc_dc` and that
;;; protobuf message types live in the module named by the protoc plugin
;;; parameter `message_module` (default `crate::pb`), each implementing
;;; `grpc_dc::Message`.

(require "spec.rkt" "desc.rkt")
(provide emit-rust-file)

(define (snake-case s)
  (list->string
   (for/fold ([out '()] [prev-lower? #f] #:result (reverse out))
             ([c (in-string s)])
     (cond [(char-upper-case? c)
            (values (cons (char-downcase c)
                          (if (and prev-lower? (not (null? out))) (cons #\_ out) out))
                    #f)]
           [else (values (cons c out) #t)]))))

(define (rust-deprecated m indent)
  (if (hash-ref m 'deprecated #f)
      (format "~a#[deprecated = \"deprecated in the proto schema\"]\n" indent)
      ""))

(define (rust-client-method m msgmod)
  (define name (hash-ref m 'name))
  (define fn-name (snake-case name))
  (define req (format "~a::~a" msgmod (hash-ref m 'input)))
  (define resp (format "~a::~a" msgmod (hash-ref m 'output)))
  (define path (hash-ref m 'path))
  (define depr (rust-deprecated m "    "))
  (case (hash-ref m 'kind)
    [(unary)
     (format "~a    pub async fn ~a(&self, req: ~a) -> Result<~a, ::grpc_dc::Status> {\n        self.channel.unary(~s, req).await\n    }\n"
             depr fn-name req resp path)]
    [(server-streaming)
     (format "~a    pub async fn ~a(&self, req: ~a) -> Result<::grpc_dc::ResponseStream<~a>, ::grpc_dc::Status> {\n        self.channel.server_stream(~s, req).await\n    }\n"
             depr fn-name req resp path)]
    [(client-streaming)
     (format "~a    pub async fn ~a<S>(&self, reqs: S) -> Result<~a, ::grpc_dc::Status>\n    where S: ::grpc_dc::futures_core::Stream<Item = ~a> + Send + 'static {\n        self.channel.client_stream(~s, reqs).await\n    }\n"
             depr fn-name resp req path)]
    [(bidi)
     (format "~a    pub async fn ~a<S>(&self, reqs: S) -> Result<::grpc_dc::ResponseStream<~a>, ::grpc_dc::Status>\n    where S: ::grpc_dc::futures_core::Stream<Item = ~a> + Send + 'static {\n        self.channel.bidi(~s, reqs).await\n    }\n"
             depr fn-name resp req path)]))

(define (rust-trait-method/deprecated m msgmod)
  (string-append (rust-deprecated m "    ") (rust-trait-method m msgmod)))

(define (rust-trait-method m msgmod)
  (define fn-name (snake-case (hash-ref m 'name)))
  (define req (format "~a::~a" msgmod (hash-ref m 'input)))
  (define resp (format "~a::~a" msgmod (hash-ref m 'output)))
  (case (hash-ref m 'kind)
    [(unary)
     (format "    async fn ~a(&self, req: ~a, ctx: ::grpc_dc::CallCtx) -> Result<~a, ::grpc_dc::Status>;\n"
             fn-name req resp)]
    [(server-streaming)
     (format "    async fn ~a(&self, req: ~a, ctx: ::grpc_dc::CallCtx) -> Result<::grpc_dc::ResponseStream<~a>, ::grpc_dc::Status>;\n"
             fn-name req resp)]
    [(client-streaming)
     (format "    async fn ~a(&self, reqs: ::grpc_dc::RequestStream<~a>, ctx: ::grpc_dc::CallCtx) -> Result<~a, ::grpc_dc::Status>;\n"
             fn-name req resp)]
    [(bidi)
     (format "    async fn ~a(&self, reqs: ::grpc_dc::RequestStream<~a>, ctx: ::grpc_dc::CallCtx) -> Result<::grpc_dc::ResponseStream<~a>, ::grpc_dc::Status>;\n"
             fn-name req resp)]))

(define (rust-register-method m service-var)
  (define fn-name (snake-case (method-impl-name m)))
  (define helper (case (hash-ref m 'kind)
                   [(unary) "unary_method"]
                   [(server-streaming) "server_stream_method"]
                   [(client-streaming) "client_stream_method"]
                   [(bidi) "bidi_method"]))
  (format "        ::grpc_dc::~a(~s, { let svc = ~a.clone(); move |req, ctx| { let svc = svc.clone(); async move { svc.~a(req, ctx).await } } }),\n"
          helper (hash-ref m 'name) service-var fn-name))

(define (rust-service svc msgmod)
  (define sname (hash-ref svc 'name))
  (define methods (hash-ref svc 'methods))
  (string-append
   (format "pub struct ~aClient { channel: ::grpc_dc::Channel }\n\n" sname)
   (format "impl ~aClient {\n    pub fn new(channel: ::grpc_dc::Channel) -> Self { Self { channel } }\n" sname)
   (apply string-append (map (lambda (m) (rust-client-method m msgmod))
                              (append methods (alias-client-methods svc))))
   "}\n\n"
   (format "#[::grpc_dc::async_trait]\npub trait ~a: Send + Sync + 'static {\n" sname)
   (apply string-append (map (lambda (m) (rust-trait-method/deprecated m msgmod)) methods))
   "}\n\n"
   (format "pub fn ~a_service<S: ~a>(svc: std::sync::Arc<S>) -> ::grpc_dc::ServiceDef {\n    ::grpc_dc::ServiceDef::new(~s, vec![\n"
           (snake-case sname) sname (hash-ref svc 'full-name))
   (apply string-append (map (lambda (m) (rust-register-method m "svc"))
                              (append methods (alias-server-methods svc))))
   "    ])\n}\n"))

(define (emit-rust-file file-model params)
  (define msgmod (hash-ref params 'message_module "crate::pb"))
  (define base (path->string (path-replace-extension
                              (file-name-from-path (hash-ref file-model 'name)) "")))
  (cons (string-append base "_grpc_dc.rs")
        (string-append
         "// @generated by protoc-gen-grpc-dc-rust (Racket metaprogram). DO NOT EDIT.\n"
         (format "// source: ~a\n" (hash-ref file-model 'name))
         "#![allow(dead_code, unused_imports, clippy::all)]\n\n"
         (apply string-append
                (map (lambda (s) (rust-service s msgmod))
                     (hash-ref file-model 'services))))))
