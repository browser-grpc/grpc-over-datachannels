#lang racket

;;; template-ruby.rkt — emitter body spliced into
;;; protoc-gen-grpc-dc-ruby.
;;;
;;; Generated code lives beside hand-written message types in a
;;; `<base>_pb` file (module <Base>Pb, classes with
;;; marshal_dc/unmarshal_dc), and requires the runtime as
;;; grpcdc. Method names keep the proto spelling (Unary,
;;; ServerStream, ...), mirroring the Python stub.

(require "spec.rkt" "desc.rkt")
(provide emit-ruby-file)

(define current-service (make-parameter ""))

(define (snake sym) ; EchoService -> echo_service
  (define s (symbol->string sym))
  (apply string-append
         (for/list ([c (in-string s)] [i (in-naturals)])
           (cond [(char-upper-case? c)
                  (string-append (if (> i 0) "_" "") (string (char-downcase c)))]
                 [else (string c)]))))

(define (camel str) ; "echo" -> "Echo", "my_svc" -> "MySvc"
  (apply string-append
         (for/list ([part (in-list (string-split str "_"))])
           (if (string=? part "")
               ""
               (string-append (string (char-upcase (string-ref part 0)))
                              (substring part 1))))))

(define (rb-deprecated m)
  (if (hash-ref m 'deprecated #f)
      "      warn \"deprecated\"\n"
      ""))

(define (rb-client-method/raw pb m)
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define path (hash-ref m 'path))
  (case (hash-ref m 'kind)
    [(unary)
     (format (string-append
              "    def ~a(req, metadata = nil)\n"
              "~a      @channel.unary(~s, req, ~a::~a.new, metadata)\n"
              "    end\n\n")
             name (rb-deprecated m) path pb resp)]
    [(server-streaming)
     (format (string-append
              "    def ~a(req, metadata = nil)\n"
              "~a      stream = @channel.server_stream(~s, req, metadata)\n"
              "      RecvStream.new(stream, ~a::~a)\n"
              "    end\n\n")
             name (rb-deprecated m) path pb resp)]
    [(client-streaming)
     (format (string-append
              "    def ~a(reqs, metadata = nil)\n"
              "~a      @channel.client_stream(~s, reqs, ~a::~a.new, metadata)\n"
              "    end\n\n")
             name (rb-deprecated m) path pb resp)]
    [(bidi)
     (format (string-append
              "    def ~a(reqs, metadata = nil)\n"
              "~a      stream = @channel.bidi(~s, reqs, metadata)\n"
              "      RecvStream.new(stream, ~a::~a)\n"
              "    end\n\n")
             name (rb-deprecated m) path pb resp)]))

(define (rb-client-method pb m)
  (rb-client-method/raw pb m))

(define (rb-server-handler pb m)
  (define name (hash-ref m 'name))
  (define impl-name (method-impl-name m))
  (define req (hash-ref m 'input))
  (define handler-var (string-append (snake (string->symbol name)) "_handler"))
  (case (hash-ref m 'kind)
    [(unary)
     (format (string-append
              "    ~a = lambda do |ctx, reqs, sink|\n"
              "      req = reqs.recv_into(~a::~a.new)\n"
              "      resp = impl.~a(ctx, req)\n"
              "      sink.send(resp.marshal_dc)\n"
              "    end\n\n")
             handler-var pb req impl-name)]
    [(server-streaming)
     (format (string-append
              "    ~a = lambda do |ctx, reqs, sink|\n"
              "      req = reqs.recv_into(~a::~a.new)\n"
              "      impl.~a(req, SendStream.new(ctx, sink))\n"
              "    end\n\n")
             handler-var pb req impl-name)]
    [(client-streaming)
     (format (string-append
              "    ~a = lambda do |ctx, reqs, sink|\n"
              "      stream = ClientStreamImpl.new(ctx, reqs, ~a::~a)\n"
              "      impl.~a(stream)\n"
              "      if stream.resp.nil?\n"
              "        raise Grpcdc::StatusError.new(Grpcdc::CODE_INTERNAL, \"client-streaming handler never called SendAndClose\")\n"
              "      end\n"
              "      sink.send(stream.resp.marshal_dc)\n"
              "    end\n\n")
             handler-var pb req impl-name)]
    [(bidi)
     (format (string-append
              "    ~a = lambda do |ctx, reqs, sink|\n"
              "      impl.~a(BidiStream.new(ctx, reqs, sink, ~a::~a))\n"
              "    end\n\n")
             handler-var impl-name pb req)]))

(define (rb-method-entry m)
  (define kind-name
    (case (hash-ref m 'kind)
      [(unary) "KIND_UNARY"]
      [(server-streaming) "KIND_SERVER_STREAMING"]
      [(client-streaming) "KIND_CLIENT_STREAMING"]
      [(bidi) "KIND_BIDI"]))
  (format "        Grpcdc::Method.new(~s, ~s, Grpcdc::~a, ~a),\n"
          (hash-ref m 'name) (hash-ref m 'path) kind-name
          (string-append (snake (string->symbol (hash-ref m 'name))) "_handler")))

(define rb-stream-helpers
  (string-append
   "  # Client receiving stream: recv raises EOFError at end.\n"
   "  class RecvStream\n"
   "    include Enumerable\n\n"
   "    def initialize(stream, resp_cls)\n"
   "      @stream = stream\n"
   "      @resp_cls = resp_cls\n"
   "    end\n\n"
   "    def recv\n"
   "      @stream.recv(@resp_cls.new)\n"
   "    end\n\n"
   "    def each\n"
   "      return enum_for(:each) unless block_given?\n\n"
   "      loop do\n"
   "        begin\n"
   "          yield recv\n"
   "        rescue EOFError\n"
   "          return\n"
   "        end\n"
   "      end\n"
   "    end\n"
   "  end\n\n"
   "  # Server-streaming sink passed to service implementations.\n"
   "  class SendStream\n"
   "    attr_reader :context\n\n"
   "    def initialize(ctx, sink)\n"
   "      @context = ctx\n"
   "      @sink = sink\n"
   "    end\n\n"
   "    def send(resp)\n"
   "      @sink.send(resp.marshal_dc)\n"
   "    end\n"
   "  end\n\n"
   "  # Client-streaming stream passed to service implementations.\n"
   "  class ClientStreamImpl\n"
   "    attr_reader :context, :resp\n\n"
   "    def initialize(ctx, reqs, req_cls)\n"
   "      @context = ctx\n"
   "      @reqs = reqs\n"
   "      @req_cls = req_cls\n"
   "      @resp = nil\n"
   "    end\n\n"
   "    def recv\n"
   "      @reqs.recv_into(@req_cls.new)\n"
   "    end\n\n"
   "    def send_and_close(resp)\n"
   "      @resp = resp\n"
   "    end\n"
   "  end\n\n"
   "  # Bidi stream passed to service implementations.\n"
   "  class BidiStream\n"
   "    attr_reader :context\n\n"
   "    def initialize(ctx, reqs, sink, req_cls)\n"
   "      @context = ctx\n"
   "      @reqs = reqs\n"
   "      @sink = sink\n"
   "      @req_cls = req_cls\n"
   "    end\n\n"
   "    def send(resp)\n"
   "      @sink.send(resp.marshal_dc)\n"
   "    end\n\n"
   "    def recv\n"
   "      @reqs.recv_into(@req_cls.new)\n"
   "    end\n"
   "  end\n\n"))

(define (rb-service pb svc)
  (define sname (hash-ref svc 'name))
  (define methods (hash-ref svc 'methods))
  (parameterize ([current-service sname])
    (string-append
     (format "  class ~aClient\n    def initialize(channel)\n      @channel = channel\n    end\n\n" sname)
     (apply string-append (map (lambda (m) (rb-client-method pb m)) (append methods (alias-client-methods svc))))
     "  end\n\n"
     (format "  def self.register_~a_server(server, impl)\n" (snake (string->symbol sname)))
     (apply string-append (map (lambda (m) (rb-server-handler pb m)) (append methods (alias-server-methods svc))))
     (format "    server.register_service(Grpcdc::ServiceDesc.new(\n      ~s,\n      [\n"
             (hash-ref svc 'full-name))
     (apply string-append (map rb-method-entry (append methods (alias-server-methods svc))))
     "      ]\n    ))\n  end\n")))

(define (emit-ruby-file file-model params)
  (define base (path->string (path-replace-extension
                              (file-name-from-path (hash-ref file-model 'name)) "")))
  (define pb (string-append (camel base) "Pb"))
  (define mod (string-append (camel base) "GrpcDc"))
  (cons (string-append base "_grpc_dc.rb")
        (string-append
         "# @generated by protoc-gen-grpc-dc-ruby (Racket metaprogram). DO NOT EDIT.\n"
         (format "# source: ~a\n\n" (hash-ref file-model 'name))
         (format "require_relative \"~a_pb\"\nrequire \"grpcdc\"\n\n" base)
         (format "module ~a\n" mod)
         rb-stream-helpers
         (apply string-append
                (map (lambda (svc) (rb-service pb svc))
                     (hash-ref file-model 'services)))
         "end\n")))
