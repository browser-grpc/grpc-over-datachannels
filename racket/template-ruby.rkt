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
              "    def ~a(req, metadata = nil, timeout: nil)\n"
              "~a      @channel.unary(~s, req, ~a::~a.new, metadata, timeout: timeout)\n"
              "    end\n\n")
             name (rb-deprecated m) path pb resp)]
    [(server-streaming)
     (format (string-append
              "    def ~a(req, metadata = nil, timeout: nil)\n"
              "~a      stream = @channel.server_stream(~s, req, metadata, timeout: timeout)\n"
              "      RecvStream.new(stream, ~a::~a)\n"
              "    end\n\n")
             name (rb-deprecated m) path pb resp)]
    [(client-streaming)
     (format (string-append
              "    def ~a(reqs, metadata = nil, timeout: nil)\n"
              "~a      @channel.client_stream(~s, reqs, ~a::~a.new, metadata, timeout: timeout)\n"
              "    end\n\n")
             name (rb-deprecated m) path pb resp)]
    [(bidi)
     (format (string-append
              "    def ~a(reqs, metadata = nil, timeout: nil)\n"
              "~a      stream = @channel.bidi(~s, reqs, metadata, timeout: timeout)\n"
              "      RecvStream.new(stream, ~a::~a)\n"
              "    end\n\n")
             name (rb-deprecated m) path pb resp)]))

(define (rb-client-method pb m)
  (rb-client-method/raw pb m))

(define (rb-fiber-client-method pb m)
  (define name (hash-ref m 'name))
  (define resp (hash-ref m 'output))
  (define path (hash-ref m 'path))
  (case (hash-ref m 'kind)
    [(unary)
     (format (string-append
              "    def ~a(req, metadata = nil, timeout: nil)\n"
              "~a      @channel.unary(~s, req, ~a::~a.new, metadata, timeout: timeout)\n"
              "    end\n\n")
             name (rb-deprecated m) path pb resp)]
    [(server-streaming)
     (format (string-append
              "    def ~a(req, metadata = nil, timeout: nil)\n"
              "~a      stream = @channel.server_stream(~s, req, metadata, timeout: timeout)\n"
              "      FiberRecvStream.new(stream, ~a::~a)\n"
              "    end\n\n")
             name (rb-deprecated m) path pb resp)]
    [(client-streaming)
     (format (string-append
              "    def ~a(reqs, metadata = nil, timeout: nil)\n"
              "~a      @channel.client_stream(~s, reqs, ~a::~a.new, metadata, timeout: timeout)\n"
              "    end\n\n")
             name (rb-deprecated m) path pb resp)]
    [(bidi)
     (format (string-append
              "    def ~a(reqs, metadata = nil, timeout: nil)\n"
              "~a      stream = @channel.bidi(~s, reqs, metadata, timeout: timeout)\n"
              "      FiberRecvStream.new(stream, ~a::~a)\n"
              "    end\n\n")
             name (rb-deprecated m) path pb resp)]))

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
   "  end\n\n"
   "  # Fiber-based client receiving stream: a producer Fiber\n"
   "  # yields each response; next_msg resumes it and raises\n"
   "  # StopIteration when the call completes. cancel aborts\n"
   "  # the underlying stream (RST).\n"
   "  class FiberRecvStream\n"
   "    include Enumerable\n\n"
   "    DONE = Object.new\n\n"
   "    def initialize(stream, resp_cls)\n"
   "      @stream = stream\n"
   "      @resp_cls = resp_cls\n"
   "      @fiber = Fiber.new do\n"
   "        begin\n"
   "          loop { Fiber.yield(@stream.recv(@resp_cls.new)) }\n"
   "        rescue EOFError\n"
   "          DONE\n"
   "        end\n"
   "      end\n"
   "    end\n\n"
   "    def next_msg\n"
   "      value = @fiber.resume\n"
   "      raise StopIteration if value.equal?(DONE)\n\n"
   "      value\n"
   "    end\n\n"
   "    def cancel\n"
   "      @stream.cancel\n"
   "    end\n\n"
   "    def each\n"
   "      return enum_for(:each) unless block_given?\n\n"
   "      loop do\n"
   "        begin\n"
   "          yield next_msg\n"
   "        rescue StopIteration\n"
   "          return\n"
   "        end\n"
   "      end\n"
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
     (format "  # Fiber client: wraps a Grpcdc::FiberChannel (a sync Channel is wrapped).\n  class ~aClientFiber\n    def initialize(channel)\n      @channel = channel.is_a?(Grpcdc::FiberChannel) ? channel : Grpcdc::FiberChannel.new(channel)\n    end\n\n" sname)
     (apply string-append (map (lambda (m) (rb-fiber-client-method pb m)) (append methods (alias-client-methods svc))))
     "  end\n\n"
     (format "  def self.register_~a_server(server, impl)\n" (snake (string->symbol sname)))
     (apply string-append (map (lambda (m) (rb-server-handler pb m)) (append methods (alias-server-methods svc))))
     (format "    server.register_service(Grpcdc::ServiceDesc.new(\n      ~s,\n      [\n"
             (hash-ref svc 'full-name))
     (apply string-append (map rb-method-entry (append methods (alias-server-methods svc))))
     "      ]\n    ))\n  end\n")))

;; ---------------------------------------------------------------------------
;; Generated message types (<base>_pb.rb, module <Base>Pb): the
;; stdlib-only protobuf wire codec the stubs require, emitted from
;; the shared desc.rkt model. Mirrors the Lua emitter.
;; ---------------------------------------------------------------------------

(define rb-pb-varint-types '(5 3 13 4 17 18 8 14))
;; type -> (size pack-format) ; pack: e/E float/double, V/Q< unsigned
;; fixed, l</q< signed fixed.
(define rb-pb-fixed '((2 4 "e") (1 8 "E") (7 4 "V") (15 4 "l<") (6 8 "Q<") (16 8 "q<")))

(define (rb-pb-flat pkg full)
  (define rel (if (and pkg (not (string=? pkg "")) (string-prefix? full (string-append pkg ".")))
                  (substring full (add1 (string-length pkg)))
                  full))
  (string-join (string-split rel ".") "_"))

(define (rb-pb-resolve model type-name)
  (hash-ref (hash-ref model 'types) type-name
            (lambda () (error 'emit-ruby-pb-file "unresolved type ~a" type-name))))

(define (rb-pb-module-name entry)
  (define base (path->string (path-replace-extension
                              (file-name-from-path (hash-ref entry 'file)) "")))
  (string-append (camel base) "Pb"))

(define (rb-pb-entry-ref model entry)
  (define local
    (rb-pb-flat (hash-ref entry 'pkg)
                (if (eq? (hash-ref entry 'kind) 'enum)
                    (let ([e (hash-ref entry 'enum)])
                      (if (hash-ref entry 'msg)
                          (format "~a.~a" (hash-ref (hash-ref entry 'msg) 'full-name) (hash-ref e 'name))
                          (format "~a.~a" (hash-ref entry 'pkg) (hash-ref e 'name))))
                    (hash-ref (hash-ref entry 'msg) 'full-name))))
  (if (or (eq? (hash-ref entry 'kind) 'map)
          (equal? (hash-ref entry 'file) (hash-ref model 'name)))
      local
      (format "~a::~a" (rb-pb-module-name entry)
              (if (eq? (hash-ref entry 'kind) 'enum)
                  (hash-ref (hash-ref entry 'enum) 'name)
                  (rb-pb-flat (hash-ref entry 'pkg)
                              (hash-ref (hash-ref entry 'msg) 'full-name))))))

(define (rb-pb-field-name f) (hash-ref f 'name))

(define (rb-pb-explicit-literal model f)
  (define d (field-explicit-default f))
  (and d
       (case (hash-ref f 'type)
         [(9) (format "~s" d)]
         [(8) d]
         [(14) (format "~a" (enum-default-number model f))]
         [(2) (format "~a" d)]
         [else d])))

(define (rb-pb-default model f)
  (cond [(rb-pb-explicit-literal model f) => (lambda (lit) lit)]
        [(and (= (hash-ref f 'type) 11)
              (eq? (hash-ref (rb-pb-resolve model (hash-ref f 'type-name)) 'kind) 'map))
         "{}"]
        [(= (hash-ref f 'label) 3) "[]"]
        [(= (hash-ref f 'type) 11) "nil"]
        [(= (hash-ref f 'type) 9) "\"\""]
        [(= (hash-ref f 'type) 12) "\"\".b"]
        [(= (hash-ref f 'type) 8) "false"]
        [(memv (hash-ref f 'type) '(1 2)) "0.0"]
        [(= (hash-ref f 'type) 14)
         (define entry (rb-pb-resolve model (hash-ref f 'type-name)))
         (format "~a" (hash-ref (car (hash-ref (hash-ref entry 'enum) 'values)) 'number))]
        [else "0"]))

(define (rb-pb-varint-expr f v)
  (case (hash-ref f 'type)
    [(8) (format "(~a ? 1 : 0)" v)]
    [(17) (format "(((~a << 1) ^ (~a >> 31)) & 0xffffffff)" v v)]
    [(18) (format "((~a << 1) ^ (~a >> 63))" v v)]
    [else v]))

(define (rb-pb-varint-decode f v)
  (case (hash-ref f 'type)
    [(5) (format "(((~a & 0xffffffff) ^ 0x80000000) - 0x80000000)" v)]
    [(14) (format "(((~a & 0xffffffff) ^ 0x80000000) - 0x80000000)" v)]
    [(13 7) (format "(~a & 0xffffffff)" v)]
    [(3) (format "(((~a & 0xffffffffffffffff) ^ 0x8000000000000000) - 0x8000000000000000)" v)]
    [(4) (format "(~a & 0xffffffffffffffff)" v)]
    [(8) (format "(~a != 0)" v)]
    [(17) (format "(((~a & 0xffffffff) >> 1) ^ -((~a & 0xffffffff) & 1))" v v)]
    [(18) (format "((~a >> 1) ^ -(~a & 1))" v v)]
    [else v]))

(define (rb-pb-fixed-fmt f)
  (third (assv (hash-ref f 'type) rb-pb-fixed)))

(define (rb-pb-wire f)
  (if (= (second (assv (hash-ref f 'type) rb-pb-fixed)) 8) 1 5))

(define (rb-pb-nonzero f v)
  (case (hash-ref f 'type)
    [(8) v]
    [else (format "~a != 0" v)]))

(define (rb-pb-encode-singular model pb f v indent)
  (define n (hash-ref f 'number))
  (define type (hash-ref f 'type))
  ;; Proto2 optional/required fields have explicit presence.
  (define proto2? (equal? (hash-ref model 'syntax "") "proto2"))
  (cond [(memv type rb-pb-varint-types)
         (if proto2?
             (format "~aw.tag(~a, 0)\n~aw.varint(~a)\n" indent n indent (rb-pb-varint-expr f v))
             (format "~aif ~a\n~a  w.tag(~a, 0)\n~a  w.varint(~a)\n~aend\n" indent (rb-pb-nonzero f v) indent n indent (rb-pb-varint-expr f v) indent))]
        [(assv type rb-pb-fixed)
         (if proto2?
             (format "~aw.tag(~a, ~a)\n~aw.fixed(~s, ~a)\n" indent n (rb-pb-wire f) indent (rb-pb-fixed-fmt f) v)
             (format "~aif ~a != 0\n~a  w.tag(~a, ~a)\n~a  w.fixed(~s, ~a)\n~aend\n" indent v indent n (rb-pb-wire f) indent (rb-pb-fixed-fmt f) v indent))]
        [(= type 9)
         (if proto2?
             (format "~aw.bytes_field(~a, ~a.encode(Encoding::UTF_8).b)\n" indent n v)
             (format "~aw.string_field(~a, ~a)\n" indent n v))]
        [(= type 12)
         (if proto2?
             (format "~aw.bytes_field(~a, ~a)\n" indent n v)
             (format "~aif ~a.bytesize > 0\n~a  w.bytes_field(~a, ~a)\n~aend\n" indent v indent n v indent))]
        [(= type 11) (format "~aunless ~a.nil?\n~a  w.bytes_field(~a, ~a.marshal_dc)\n~aend\n" indent v indent n v indent)]
        [else (error 'emit-ruby-pb-file "unsupported field type ~a (groups)" type)]))

(define (rb-pb-set-expr sib)
  (define v (format "@~a" (rb-pb-field-name sib)))
  (case (hash-ref sib 'type)
    [(11 10) (format "!~a.nil?" v)]
    [(9 12) (format "(!~a.nil? && !~a.empty?)" v v)]
    [else (rb-pb-nonzero sib v)]))

;; Encode-side oneof clearing: suppress f when a later sibling is
;; set, so only the winning member is written.
(define (rb-pb-encode-guard model f code)
  (define later (oneof-later-siblings model f))
  (if (null? later)
      code
      (string-append
       (format "    unless (~a)\n" (string-join (map rb-pb-set-expr later) " || "))
       (if (string-suffix? code "\n") code (string-append code "\n"))
       "    end\n")))

(define (rb-pb-encode-field model pb f)
  (define v (format "@~a" (rb-pb-field-name f)))
  (define n (hash-ref f 'number))
  (define type (hash-ref f 'type))
  (cond [(and (= type 11)
              (eq? (hash-ref (rb-pb-resolve model (hash-ref f 'type-name)) 'kind) 'map))
         (define entry (rb-pb-resolve model (hash-ref f 'type-name)))
         (define helper (format "~aPb.encode_~a" pb (snake (string->symbol (rb-pb-entry-ref model entry)))))
         (format "    ~a.each { |k, val| w.bytes_field(~a, ~a(k, val)) }\n" v n helper)]
        [(not (= (hash-ref f 'label) 3)) (rb-pb-encode-singular model pb f v "    ")]
        [(memv type rb-pb-varint-types)
         (string-append
          (format "    unless ~a.empty?\n      payload = +\"\".b\n" v)
          (format "      ~a.each { |x| payload << ~aPbVarint.call(~a) }\n" v pb (rb-pb-varint-expr f "x"))
          (format "      w.bytes_field(~a, payload)\n    end\n" n))]
        [(assv type rb-pb-fixed)
         => (lambda (info)
              (string-append
               (format "    unless ~a.empty?\n" v)
               (format "      w.bytes_field(~a, ~a.pack(~s))\n    end\n" n v (string-append (third info) "*"))))]
        [(= type 9) (format "    ~a.each { |x| w.bytes_field(~a, x) }\n" v n)]
        [(= type 12) (format "    ~a.each { |x| w.bytes_field(~a, x) }\n" v n)]
        [(= type 11) (format "    ~a.each { |x| w.bytes_field(~a, x.marshal_dc) }\n" v n)]
        [else (error 'emit-ruby-pb-file "unsupported repeated field type ~a" type)]))

(define (rb-pb-decode-singular model f target src indent)
  (define type (hash-ref f 'type))
  (cond [(memv type rb-pb-varint-types)
         (format "~a~a = ~a\n" indent target (rb-pb-varint-decode f src))]
        [(assv type rb-pb-fixed)
         (format "~a~a = ~a.unpack1(~s)\n" indent target src (rb-pb-fixed-fmt f))]
        [(= type 9) (format "~a~a = ~a.dup.force_encoding(Encoding::UTF_8)\n" indent target src)]
        [(= type 12) (format "~a~a = ~a\n" indent target src)]
        [(= type 11)
         (define ref (rb-pb-entry-ref model (rb-pb-resolve model (hash-ref f 'type-name))))
         (string-append
          (format "~a~a = ~a.new\n" indent target ref)
          (format "~a~a.unmarshal_dc(~a)\n" indent target src))]
        [else (error 'emit-ruby-pb-file "unsupported field type ~a" type)]))

(define (rb-pb-oneof-clearing model f)
  (apply string-append
         (map (lambda (sib)
                (format "        @~a = ~a\n" (rb-pb-field-name sib) (rb-pb-default model sib)))
              (oneof-siblings model f))))

(define (rb-pb-decode-case model f)
  (define v (format "@~a" (rb-pb-field-name f)))
  (define type (hash-ref f 'type))
  (define head (format "      when ~a\n" (hash-ref f 'number)))
  (define clearing (rb-pb-oneof-clearing model f))
  (cond [(and (= type 11)
              (eq? (hash-ref (rb-pb-resolve model (hash-ref f 'type-name)) 'kind) 'map))
         (define entry (rb-pb-resolve model (hash-ref f 'type-name)))
         (define pb (rb-pb-module-name (hasheq 'file (hash-ref model 'name))))
         (define helper (format "~a.decode_~a" pb (snake (string->symbol (rb-pb-entry-ref model entry)))))
         (string-append head
                        (format "        kk, vv = ~a(bytes_value)\n" helper)
                        (format "        ~a[kk] = vv\n" v))]
        [(not (= (hash-ref f 'label) 3))
         (string-append head
                        clearing
                        (rb-pb-decode-singular model f v
                                               (cond [(memv type rb-pb-varint-types) "varint_value"]
                                                     [(assv type rb-pb-fixed) "fixed_value"]
                                                     [else "bytes_value"])
                                               "        "))]
        [(memv type rb-pb-varint-types)
         (string-append head
                        "        if wire == 2\n"
                        "          sub = Reader.new(bytes_value)\n"
                        "          until sub.done?\n"
                        "            raw = sub.varint\n"
                        (format "            ~a << ~a\n" v (rb-pb-varint-decode f "raw"))
                        "          end\n        else\n"
                        (format "          ~a << ~a\n" v (rb-pb-varint-decode f "varint_value"))
                        "        end\n")]
        [(assv type rb-pb-fixed)
         => (lambda (info)
              (string-append head
                             "        if wire == 2\n"
                             (format "          bytes_value.unpack(~s).each { |x| ~a << x }\n" (string-append (third info) "*") v)
                             "        else\n"
                             (format "          ~a << fixed_value.unpack1(~s)\n" v (third info))
                             "        end\n"))]
        [(= type 9) (string-append head (format "        ~a << bytes_value.dup.force_encoding(Encoding::UTF_8)\n" v))]
        [(= type 12) (string-append head (format "        ~a << bytes_value\n" v))]
        [(= type 11)
         (string-append head
                        (format "        item = ~a.new\n" (rb-pb-entry-ref model (rb-pb-resolve model (hash-ref f 'type-name))))
                        "        item.unmarshal_dc(bytes_value)\n"
                        (format "        ~a << item\n" v))]
        [else (error 'emit-ruby-pb-file "unsupported repeated field type ~a" type)]))

(define (rb-pb-map-helpers model pb entry)
  (define msg (hash-ref entry 'msg))
  (define base (snake (string->symbol (rb-pb-entry-ref model entry))))
  (define key-f (findf (lambda (x) (= (hash-ref x 'number) 1)) (hash-ref msg 'fields)))
  (define val-f (findf (lambda (x) (= (hash-ref x 'number) 2)) (hash-ref msg 'fields)))
  (unless (and key-f val-f) (error 'emit-ruby-pb-file "map entry ~a lacks key/value" (hash-ref msg 'full-name)))
  (string-append
   (format "  def self.encode_~a(key, value)\n    w = Writer.new\n" base)
   (rb-pb-encode-singular model pb (hash-set key-f 'label 1) "key" "    ")
   (rb-pb-encode-singular model pb (hash-set val-f 'label 1) "value" "    ")
   "    w.to_bytes\n  end\n\n"
   (format "  def self.decode_~a(data)\n" base)
   (format "    key = ~a\n    value = ~a\n" (rb-pb-default model (hash-set key-f 'label 1)) (rb-pb-default model (hash-set val-f 'label 1)))
   "    r = Reader.new(data)\n    loop do\n      item = r.field\n      break if item.nil?\n\n      num, wire, varint_value, bytes_value, fixed_value, _raw_value = item\n"
   (format "      if num == ~a\n~a" (hash-ref key-f 'number)
           (rb-pb-decode-singular model (hash-set key-f 'label 1) "key"
                                  (cond [(memv (hash-ref key-f 'type) rb-pb-varint-types) "varint_value"]
                                        [(assv (hash-ref key-f 'type) rb-pb-fixed) "fixed_value"]
                                        [else "bytes_value"]) "        "))
   (format "      elsif num == ~a\n~a" (hash-ref val-f 'number)
           (if (= (hash-ref val-f 'type) 11)
               (format "        value = ~a.new\n        value.unmarshal_dc(bytes_value)\n"
                       (rb-pb-entry-ref model (rb-pb-resolve model (hash-ref val-f 'type-name))))
               (rb-pb-decode-singular model (hash-set val-f 'label 1) "value"
                                      (cond [(memv (hash-ref val-f 'type) rb-pb-varint-types) "varint_value"]
                                            [(assv (hash-ref val-f 'type) rb-pb-fixed) "fixed_value"]
                                            [else "bytes_value"]) "        ")))
   "      end\n    end\n    [key, value]\n  end\n\n"))

(define (rb-pb-support pb)
  (string-append
   "# @generated by protoc-gen-grpc-dc-ruby (Racket metaprogram). DO NOT EDIT.\n"
   (format "~aPbVarint = lambda do |value|\n  out = +\"\".b\n  v = value & 0xffffffffffffffff\n  while v > 0x7f\n    out << ((v & 0x7f) | 0x80)\n    v >>= 7\n  end\n  out << v\n  out\nend\n\n" pb)
   "  class Writer\n"
   "    def initialize\n      @out = String.new(encoding: Encoding::BINARY)\n    end\n\n"
   "    def varint(value)\n      @out << " pb "PbVarint.call(value)\n    end\n\n"
   "    def tag(field, wire)\n      varint((field << 3) | wire)\n    end\n\n"
   "    def bytes_field(field, payload)\n      tag(field, 2)\n      varint(payload.bytesize)\n      @out << payload.b\n    end\n\n"
   "    def string_field(field, value)\n      return if value.nil? || value.empty?\n\n      bytes_field(field, value.encode(Encoding::UTF_8).b)\n    end\n\n"
   "    def fixed(fmt, value)\n      @out << [value].pack(fmt)\n    end\n\n"
   "    def raw(payload)\n      @out << payload.b\n    end\n\n"
   "    def to_bytes\n      @out\n    end\n  end\n\n"
   "  class Reader\n"
   "    def initialize(buf)\n      @buf = buf.b\n      @pos = 0\n    end\n\n"
   "    def done?\n      @pos >= @buf.bytesize\n    end\n\n"
   "    def varint\n      result = 0\n      shift = 0\n      loop do\n        raise ArgumentError, \"truncated varint\" if @pos >= @buf.bytesize\n\n        b = @buf.getbyte(@pos)\n        @pos += 1\n        result |= (b & 0x7f) << shift\n        return result if (b & 0x80).zero?\n\n        shift += 7\n        raise ArgumentError, \"varint too long\" if shift >= 70\n      end\n    end\n\n"
   "    def take(n)\n      raise ArgumentError, \"truncated field\" if @pos + n > @buf.bytesize\n\n      value = @buf.byteslice(@pos, n)\n      @pos += n\n      value\n    end\n\n"
   "    # [number, wire, varint_value, bytes_value, fixed_value] or nil.\n"
   "    def field\n      return nil if done?\n\n      start = @pos\n      tag = varint\n      num = tag >> 3\n      wire = tag & 7\n      raw = -> { @buf.byteslice(start, @pos - start) }\n      case wire\n      when 0 then [num, wire, varint, \"\".b, \"\".b, raw.call]\n      when 2\n        n = varint\n        v = take(n)\n        [num, wire, 0, v, \"\".b, raw.call]\n      when 1\n        v = take(8)\n        [num, wire, 0, \"\".b, v, raw.call]\n      when 5\n        v = take(4)\n        [num, wire, 0, \"\".b, v, raw.call]\n      else raise ArgumentError, \"bad wire type\"\n      end\n    end\n  end\n\n"))

(define (rb-pb-message-class model pb msg)
  (define name (rb-pb-flat (hash-ref model 'package) (hash-ref msg 'full-name)))
  (define fields (hash-ref msg 'fields))
  (string-append
   (format "  class ~a\n" name)
   (if (null? fields)
       ""
       (format "    attr_accessor ~a\n\n" (string-join (append (map (lambda (f) (format ":~a" (rb-pb-field-name f))) fields) (list ":unknown_fields")) ", ")))
   (format "    def initialize(~a)\n" (string-join (map (lambda (f) (format "~a: ~a" (rb-pb-field-name f) (rb-pb-default model f))) fields) ", "))
   (apply string-append (map (lambda (f) (format "      @~a = ~a\n" (rb-pb-field-name f) (rb-pb-field-name f))) fields))
   "      @unknown_fields = \"\".b\n"
   "    end\n\n"
   "    def marshal_dc\n      w = Writer.new\n"
   (apply string-append (map (lambda (f) (rb-pb-encode-guard model f (rb-pb-encode-field model pb f))) fields))
   "      w.raw(@unknown_fields)\n"
   "      w.to_bytes\n    end\n\n"
   "    def unmarshal_dc(data)\n"
   "      @unknown_fields = \"\".b\n"
   (apply string-append (map (lambda (f) (format "      @~a = ~a\n" (rb-pb-field-name f) (rb-pb-default model f))) fields))
   "      r = Reader.new(data)\n      loop do\n        item = r.field\n        break if item.nil?\n\n        num, wire, varint_value, bytes_value, fixed_value, raw_value = item\n        case num\n"
   (apply string-append (map (lambda (f) (rb-pb-decode-case model f)) fields))
   "        else\n          @unknown_fields = @unknown_fields + raw_value\n        end\n      end\n      self\n    end\n\n"
   (format "    def ==(other)\n      other.is_a?(~a) && ~a\n    end\n" name
           (if (null? fields)
               "true"
               (string-join (map (lambda (f) (format "@~a == other.~a" (rb-pb-field-name f) (rb-pb-field-name f))) fields) " && ")))
   "  end\n\n"
   (apply string-append (map (lambda (n) (rb-pb-message-class model pb n)) (hash-ref msg 'nested)))))

(define (rb-pb-enum model e)
  (define name (rb-pb-flat (hash-ref model 'package)
                           (if (string=? (hash-ref model 'package) "")
                               (hash-ref e 'name)
                               (format "~a.~a" (hash-ref model 'package) (hash-ref e 'name)))))
  (string-append
   (format "  module ~a\n" name)
   (apply string-append
          (map (lambda (v) (format "    ~a = ~a\n" (hash-ref v 'name) (hash-ref v 'number)))
               (hash-ref e 'values)))
   "  end\n\n"))

(define (emit-ruby-pb-file file-model)
  (and (hash-has-key? file-model 'messages)
       (hash-has-key? file-model 'types)
       (emit-ruby-pb-file/inner file-model)))

(define (emit-ruby-pb-file/inner file-model)
  (define messages (hash-ref file-model 'messages))
  (define enums (hash-ref file-model 'enums))
  (and (or (pair? messages) (pair? enums))
       (let ()
         (define base (path->string (path-replace-extension
                                     (file-name-from-path (hash-ref file-model 'name)) "")))
         (define pb (camel base))
         (define pkg (hash-ref file-model 'package))
         (define seen-maps (mutable-set))
         (define helpers '())
         (define (collect msg)
           (for ([f (in-list (hash-ref msg 'fields))])
             (when (= (hash-ref f 'type) 11)
               (define e (rb-pb-resolve file-model (hash-ref f 'type-name)))
               (when (and (eq? (hash-ref e 'kind) 'map)
                          (not (set-member? seen-maps (hash-ref (hash-ref e 'msg) 'full-name))))
                 (set-add! seen-maps (hash-ref (hash-ref e 'msg) 'full-name))
                 (set! helpers (cons (rb-pb-map-helpers file-model pb e) helpers)))))
           (for ([n (in-list (hash-ref msg 'nested))]) (collect n)))
         (for ([m (in-list messages)]) (collect m))
         (define dep-modules
           (remove-duplicates
            (map (lambda (d)
                   (path->string (path-replace-extension (file-name-from-path d) "")))
                 (hash-ref file-model 'dependencies))))
         (define content
           (string-append
            (apply string-append
                   (map (lambda (d) (format "require_relative \"~a_pb\"\n" d)) dep-modules))
            (if (null? dep-modules) "" "\n")
            (format "module ~aPb\n" pb)
            (rb-pb-support pb)
            (apply string-append (map (lambda (e) (rb-pb-enum file-model e)) enums))
            (apply string-append
                   (map (lambda (m) (rb-pb-message-class file-model pb m))
                        (filter (lambda (m) (not (hash-ref m 'map-entry))) messages)))
            (apply string-append (reverse helpers))
            "end\n"))
         (cons (string-append base "_pb.rb") content))))

(define (emit-ruby-file file-model params)
  (define base (path->string (path-replace-extension
                              (file-name-from-path (hash-ref file-model 'name)) "")))
  (define pb (string-append (camel base) "Pb"))
  (define mod (string-append (camel base) "GrpcDc"))
  (define stub
    (cons (string-append base "_grpc_dc.rb")
        (string-append
         "# @generated by protoc-gen-grpc-dc-ruby (Racket metaprogram). DO NOT EDIT.\n"
         (format "# source: ~a\n\n" (hash-ref file-model 'name))
         (format "require_relative \"~a_pb\"\nrequire \"grpcdc\"\n\n" base)
         (format "module ~a\n" mod)
         ;; trace=hooks: delegate the tracer registrar to the runtime.
         (if (equal? (hash-ref params 'trace #f) "hooks")
             (string-append
              "  # Tracing (trace=hooks): register an observer via set_tracer.\n"
              "  def self.set_tracer(t)\n    Grpcdc.set_tracer(t)\n  end\n\n"
              "  def self.set_trace_filter(patterns)\n    Grpcdc.set_trace_filter(patterns)\n  end\n\n"
              (let ([methods (hash-ref params 'trace_methods #f)])
                (if methods
                    (format "  Grpcdc.set_trace_filter(~s)\n\n" methods)
                    "")))
             "")
         rb-stream-helpers
         (apply string-append
                (map (lambda (svc) (rb-service pb svc))
                     (hash-ref file-model 'services)))
         "end\n")))
  (define pb-file (emit-ruby-pb-file file-model))
  (if pb-file (list stub pb-file) stub))
