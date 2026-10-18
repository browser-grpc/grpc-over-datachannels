#lang racket

;;; template-php.rkt — emitter body spliced into
;;; protoc-gen-grpc-dc-php.
;;;
;;; Generated code lives beside hand-written message types in a
;;; `<base>_pb.php` file (namespace <Base>Pb, classes with
;;; marshalDc/unmarshalDc), and requires the runtime as grpcdc.php.
;;; Method names keep the proto spelling (Unary, ServerStream,
;;; ...), mirroring the Ruby stub. PHP has no threads, so the
;;; generated client composes with the runtime's cooperative
;;; pump; the Fiber client mirror uses PHP 8.1 Fibers like the
;;; Ruby stub's Fiber surface.

(require "spec.rkt" "desc.rkt")
(provide emit-php-file)

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

(define (php-deprecated m)
  (if (hash-ref m 'deprecated #f)
      "        trigger_error(\"deprecated\", E_USER_DEPRECATED);\n"
      ""))

(define (php-client-method pb m)
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define path (hash-ref m 'path))
  (case (hash-ref m 'kind)
    [(unary)
     (format (string-append
              "    public function ~a(\\~a\\~a $req, ?array $metadata = null, ?float $timeout = null): \\~a\\~a\n"
              "    {\n~a        return $this->channel->unary(~s, $req, new \\~a\\~a(), $metadata, $timeout);\n    }\n\n")
             name pb req pb resp (php-deprecated m) path pb resp)]
    [(server-streaming)
     (format (string-append
              "    public function ~a(\\~a\\~a $req, ?array $metadata = null, ?float $timeout = null): RecvStream\n"
              "    {\n~a        $stream = $this->channel->serverStream(~s, $req, $metadata, $timeout);\n"
              "        return new RecvStream($stream, \\~a\\~a::class);\n    }\n\n")
             name pb req (php-deprecated m) path pb resp)]
    [(client-streaming)
     (format (string-append
              "    public function ~a(array $reqs, ?array $metadata = null, ?float $timeout = null): \\~a\\~a\n"
              "    {\n~a        return $this->channel->clientStream(~s, $reqs, new \\~a\\~a(), $metadata, $timeout);\n    }\n\n")
             name pb resp (php-deprecated m) path pb resp)]
    [(bidi)
     (format (string-append
              "    public function ~a(array $reqs, ?array $metadata = null, ?float $timeout = null): RecvStream\n"
              "    {\n~a        $stream = $this->channel->bidi(~s, $reqs, $metadata, $timeout);\n"
              "        return new RecvStream($stream, \\~a\\~a::class);\n    }\n\n")
             name (php-deprecated m) path pb resp)]))

(define (php-fiber-client-method pb m)
  (define name (hash-ref m 'name))
  (define req (hash-ref m 'input))
  (define resp (hash-ref m 'output))
  (define path (hash-ref m 'path))
  (case (hash-ref m 'kind)
    [(unary)
     (format (string-append
              "    public function ~a(\\~a\\~a $req, ?array $metadata = null, ?float $timeout = null): \\~a\\~a\n"
              "    {\n~a        return $this->channel->unary(~s, $req, new \\~a\\~a(), $metadata, $timeout);\n    }\n\n")
             name pb req pb resp (php-deprecated m) path pb resp)]
    [(server-streaming)
     (format (string-append
              "    public function ~a(\\~a\\~a $req, ?array $metadata = null, ?float $timeout = null): FiberRecvStream\n"
              "    {\n~a        $stream = $this->channel->serverStream(~s, $req, $metadata, $timeout);\n"
              "        return new FiberRecvStream($stream, \\~a\\~a::class);\n    }\n\n")
             name pb req (php-deprecated m) path pb resp)]
    [(client-streaming)
     (format (string-append
              "    public function ~a(array $reqs, ?array $metadata = null, ?float $timeout = null): \\~a\\~a\n"
              "    {\n~a        return $this->channel->clientStream(~s, $reqs, new \\~a\\~a(), $metadata, $timeout);\n    }\n\n")
             name pb resp (php-deprecated m) path pb resp)]
    [(bidi)
     (format (string-append
              "    public function ~a(array $reqs, ?array $metadata = null, ?float $timeout = null): FiberRecvStream\n"
              "    {\n~a        $stream = $this->channel->bidi(~s, $reqs, $metadata, $timeout);\n"
              "        return new FiberRecvStream($stream, \\~a\\~a::class);\n    }\n\n")
             name (php-deprecated m) path pb resp)]))

(define (php-server-handler pb m)
  (define name (hash-ref m 'name))
  (define impl-name (method-impl-name m))
  (define req (hash-ref m 'input))
  (define handler-var (string-append "$" (snake (string->symbol name)) "Handler"))
  (case (hash-ref m 'kind)
    [(unary)
     (format (string-append
              "    ~a = function (\\Grpcdc\\CallContext $ctx, \\Grpcdc\\RequestStream $reqs, \\Grpcdc\\ResponseSink $sink) use ($impl) {\n"
              "        $req = $reqs->recvInto(new \\~a\\~a());\n"
              "        $resp = $impl->~a($ctx, $req);\n"
              "        $sink->send($resp->marshalDc());\n"
              "    };\n\n")
             handler-var pb req impl-name)]
    [(server-streaming)
     (format (string-append
              "    ~a = function (\\Grpcdc\\CallContext $ctx, \\Grpcdc\\RequestStream $reqs, \\Grpcdc\\ResponseSink $sink) use ($impl) {\n"
              "        $req = $reqs->recvInto(new \\~a\\~a());\n"
              "        $impl->~a($req, new SendStream($ctx, $sink));\n"
              "    };\n\n")
             handler-var pb req impl-name)]
    [(client-streaming)
     (format (string-append
              "    ~a = function (\\Grpcdc\\CallContext $ctx, \\Grpcdc\\RequestStream $reqs, \\Grpcdc\\ResponseSink $sink) use ($impl) {\n"
              "        $stream = new ClientStreamImpl($ctx, $reqs, \\~a\\~a::class);\n"
              "        $impl->~a($stream);\n"
              "        if ($stream->resp === null) {\n"
              "            throw new \\Grpcdc\\StatusError(\\Grpcdc\\Wire::CODE_INTERNAL, \"client-streaming handler never called sendAndClose\");\n"
              "        }\n"
              "        $sink->send($stream->resp->marshalDc());\n"
              "    };\n\n")
             handler-var pb req impl-name)]
    [(bidi)
     (format (string-append
              "    ~a = function (\\Grpcdc\\CallContext $ctx, \\Grpcdc\\RequestStream $reqs, \\Grpcdc\\ResponseSink $sink) use ($impl) {\n"
              "        $impl->~a(new BidiStream($ctx, $reqs, $sink, \\~a\\~a::class));\n"
              "    };\n\n")
             handler-var impl-name pb req)]))

(define (php-method-entry m)
  (define kind-name
    (case (hash-ref m 'kind)
      [(unary) "KIND_UNARY"]
      [(server-streaming) "KIND_SERVER_STREAMING"]
      [(client-streaming) "KIND_CLIENT_STREAMING"]
      [(bidi) "KIND_BIDI"]))
  (format "            new \\Grpcdc\\Method(~s, ~s, \\Grpcdc\\Server::~a, ~a),\n"
          (hash-ref m 'name) (hash-ref m 'path) kind-name
          (string-append "$" (snake (string->symbol (hash-ref m 'name))) "Handler")))

(define php-stream-helpers
  (string-append
   "// Client receiving stream: recv throws CallClosed at end.\n"
   "class RecvStream\n"
   "{\n"
   "    private \\Grpcdc\\ClientStream $stream;\n"
   "    private string $respClass;\n\n"
   "    public function __construct(\\Grpcdc\\ClientStream $stream, string $respClass)\n"
   "    {\n        $this->stream = $stream;\n        $this->respClass = $respClass;\n    }\n\n"
   "    public function recv(): object\n"
   "    {\n        $cls = $this->respClass;\n        return $this->stream->recv(new $cls());\n    }\n\n"
   "    /** @return \\Generator<int, object> */\n"
   "    public function iterate(): \\Generator\n"
   "    {\n        try {\n            while (true) {\n                yield $this->recv();\n            }\n        } catch (\\Grpcdc\\CallClosed $e) {\n            return;\n        }\n    }\n"
   "}\n\n"
   "// Server-streaming sink passed to service implementations.\n"
   "class SendStream\n"
   "{\n"
   "    public \\Grpcdc\\CallContext $context;\n"
   "    private \\Grpcdc\\ResponseSink $sink;\n\n"
   "    public function __construct(\\Grpcdc\\CallContext $ctx, \\Grpcdc\\ResponseSink $sink)\n"
   "    {\n        $this->context = $ctx;\n        $this->sink = $sink;\n    }\n\n"
   "    public function send(object $resp): void\n"
   "    {\n        $this->sink->send($resp->marshalDc());\n    }\n"
   "}\n\n"
   "// Client-streaming stream passed to service implementations.\n"
   "class ClientStreamImpl\n"
   "{\n"
   "    public \\Grpcdc\\CallContext $context;\n"
   "    public ?object $resp = null;\n"
   "    private \\Grpcdc\\RequestStream $reqs;\n"
   "    private string $reqClass;\n\n"
   "    public function __construct(\\Grpcdc\\CallContext $ctx, \\Grpcdc\\RequestStream $reqs, string $reqClass)\n"
   "    {\n        $this->context = $ctx;\n        $this->reqs = $reqs;\n        $this->reqClass = $reqClass;\n    }\n\n"
   "    public function recv(): object\n"
   "    {\n        $cls = $this->reqClass;\n        return $this->reqs->recvInto(new $cls());\n    }\n\n"
   "    public function sendAndClose(object $resp): void\n"
   "    {\n        $this->resp = $resp;\n    }\n"
   "}\n\n"
   "// Bidi stream passed to service implementations.\n"
   "class BidiStream\n"
   "{\n"
   "    public \\Grpcdc\\CallContext $context;\n"
   "    private \\Grpcdc\\RequestStream $reqs;\n"
   "    private \\Grpcdc\\ResponseSink $sink;\n"
   "    private string $reqClass;\n\n"
   "    public function __construct(\\Grpcdc\\CallContext $ctx, \\Grpcdc\\RequestStream $reqs, \\Grpcdc\\ResponseSink $sink, string $reqClass)\n"
   "    {\n        $this->context = $ctx;\n        $this->reqs = $reqs;\n        $this->sink = $sink;\n        $this->reqClass = $reqClass;\n    }\n\n"
   "    public function send(object $resp): void\n"
   "    {\n        $this->sink->send($resp->marshalDc());\n    }\n\n"
   "    public function recv(): object\n"
   "    {\n        $cls = $this->reqClass;\n        return $this->reqs->recvInto(new $cls());\n    }\n"
   "}\n\n"
   "// Fiber-based client receiving stream: a producer Fiber suspends\n"
   "// per response; next() resumes it and throws CallClosed when the\n"
   "// call completes. cancel aborts the underlying stream (RST).\n"
   "class FiberRecvStream\n"
   "{\n"
   "    /** @var \\Grpcdc\\ClientStream|\\Grpcdc\\FiberClientStream */\n"
   "    private $stream;\n"
   "    private string $respClass;\n"
   "    private ?\\Fiber $fiber = null;\n"
   "    private bool $started = false;\n"
   "    private bool $done = false;\n\n"
   "    public function __construct($stream, string $respClass)\n"
   "    {\n        $this->stream = $stream;\n        $this->respClass = $respClass;\n    }\n\n"
   "    public function next(): object\n"
   "    {\n"
   "        if ($this->done) {\n            throw new \\Grpcdc\\CallClosed(\"stream exhausted\");\n        }\n"
   "        if (!$this->started) {\n"
   "            $this->started = true;\n"
   "            $cls = $this->respClass;\n"
   "            $stream = $this->stream;\n"
   "            $this->fiber = new \\Fiber(function () use ($stream, $cls) {\n"
   "                try {\n"
   "                    while (true) {\n"
   "                        \\Fiber::suspend($stream->recv(new $cls()));\n"
   "                    }\n"
   "                } catch (\\Grpcdc\\CallClosed $e) {\n"
   "                    return;\n"
   "                }\n"
   "            });\n"
   "            $value = $this->fiber->start();\n"
   "        } else {\n"
   "            $value = $this->fiber->resume();\n"
   "        }\n"
   "        if ($this->fiber->isTerminated()) {\n"
   "            $this->done = true;\n"
   "            throw new \\Grpcdc\\CallClosed(\"stream exhausted\");\n"
   "        }\n"
   "        return $value;\n"
   "    }\n\n"
   "    /** @return \\Generator<int, object> */\n"
   "    public function iterate(): \\Generator\n"
   "    {\n        try {\n            while (true) {\n                yield $this->next();\n            }\n        } catch (\\Grpcdc\\CallClosed $e) {\n            return;\n        }\n    }\n\n"
   "    public function cancel(): void\n"
   "    {\n        $this->stream->cancel();\n    }\n"
   "}\n\n"))

(define (php-service pb svc)
  (define sname (hash-ref svc 'name))
  (define methods (hash-ref svc 'methods))
  (parameterize ([current-service sname])
    (string-append
     (format "class ~aClient\n{\n    private \\Grpcdc\\Channel $channel;\n\n    public function __construct(\\Grpcdc\\Channel $channel)\n    {\n        $this->channel = $channel;\n    }\n\n" sname)
     (apply string-append (map (lambda (m) (php-client-method pb m)) (append methods (alias-client-methods svc))))
     "}\n\n"
     (format "// Fiber client: wraps a Grpcdc\\FiberChannel (a sync Channel is wrapped).\nclass ~aClientFiber\n{\n    private \\Grpcdc\\FiberChannel $channel;\n\n    public function __construct($channel)\n    {\n        $this->channel = $channel instanceof \\Grpcdc\\FiberChannel ? $channel : new \\Grpcdc\\FiberChannel($channel);\n    }\n\n" sname)
     (apply string-append (map (lambda (m) (php-fiber-client-method pb m)) (append methods (alias-client-methods svc))))
     "}\n\n"
     (format "function register~aServer(\\Grpcdc\\Server $server, object $impl): void\n{\n" sname)
     (apply string-append (map (lambda (m) (php-server-handler pb m)) (append methods (alias-server-methods svc))))
     (format "    $server->registerService(new \\Grpcdc\\ServiceDesc(\n        ~s,\n        [\n"
             (hash-ref svc 'full-name))
     (apply string-append (map php-method-entry (append methods (alias-server-methods svc))))
     "        ]\n    ));\n}\n")))

;; ---------------------------------------------------------------------------
;; Generated message types (<base>_pb.php, namespace <Base>Pb): the
;; stdlib-only protobuf wire codec the stubs require, emitted from
;; the shared desc.rkt model. Mirrors the Ruby emitter.
;; ---------------------------------------------------------------------------

(define php-pb-varint-types '(5 3 13 4 17 18 8 14))
;; type -> (size pack-format) for float/double/fixed32/fixed64.
;; sfixed32/sfixed64 decode through unsigned + sign conversion.
(define php-pb-fixed '((2 4 "g") (1 8 "e") (7 4 "V") (15 4 "V") (6 8 "P") (16 8 "P")))

(define (php-pb-camel s)
  (define parts (string-split s "_"))
  (if (null? parts)
      s
      (apply string-append (car parts)
             (map (lambda (p) (if (string=? p "") "" (string-append (string (char-upcase (string-ref p 0))) (substring p 1))))
                  (cdr parts)))))

(define (php-pb-field-name f)
  (define jn (hash-ref f 'json-name ""))
  (if (and jn (not (string=? jn ""))) jn (php-pb-camel (hash-ref f 'name))))

(define (php-pb-flat pkg full)
  (define rel (if (and pkg (not (string=? pkg "")) (string-prefix? full (string-append pkg ".")))
                  (substring full (add1 (string-length pkg)))
                  full))
  (string-join (string-split rel ".") "_"))

(define (php-pb-resolve model type-name)
  (hash-ref (hash-ref model 'types) type-name
            (lambda () (error 'emit-php-pb-file "unresolved type ~a" type-name))))

(define (php-pb-namespace entry)
  (define base (path->string (path-replace-extension
                              (file-name-from-path (hash-ref entry 'file)) "")))
  (string-append (camel base) "Pb"))

(define (php-pb-entry-ref model entry)
  (define local
    (php-pb-flat (hash-ref entry 'pkg)
                 (if (eq? (hash-ref entry 'kind) 'enum)
                     (let ([e (hash-ref entry 'enum)])
                       (if (hash-ref entry 'msg)
                           (format "~a.~a" (hash-ref (hash-ref entry 'msg) 'full-name) (hash-ref e 'name))
                           (format "~a.~a" (hash-ref entry 'pkg) (hash-ref e 'name))))
                     (hash-ref (hash-ref entry 'msg) 'full-name))))
  (if (or (eq? (hash-ref entry 'kind) 'map)
          (equal? (hash-ref entry 'file) (hash-ref model 'name)))
      local
      (format "\\~a\\~a" (php-pb-namespace entry)
              (if (eq? (hash-ref entry 'kind) 'enum)
                  (hash-ref (hash-ref entry 'enum) 'name)
                  (php-pb-flat (hash-ref entry 'pkg)
                               (hash-ref (hash-ref entry 'msg) 'full-name))))))

(define (php-pb-type model f)
  (define type (hash-ref f 'type))
  (cond [(and (= type 11)
              (eq? (hash-ref (php-pb-resolve model (hash-ref f 'type-name)) 'kind) 'map)) "array"]
        [(= (hash-ref f 'label) 3) "array"]
        [(memv type '(1 2)) "float"]
        [(memv type '(9 12)) "string"]
        [(= type 8) "bool"]
        [(= type 11) (format "?~a" (php-pb-entry-ref model (php-pb-resolve model (hash-ref f 'type-name))))]
        [else "int"]))

(define (php-pb-default model f)
  (cond [(and (= (hash-ref f 'type) 11)
              (eq? (hash-ref (php-pb-resolve model (hash-ref f 'type-name)) 'kind) 'map)) "[]"]
        [(= (hash-ref f 'label) 3) "[]"]
        [(= (hash-ref f 'type) 11) "null"]
        [(memv (hash-ref f 'type) '(9 12)) "\"\""]
        [(= (hash-ref f 'type) 8) "false"]
        [(memv (hash-ref f 'type) '(1 2)) "0.0"]
        [(= (hash-ref f 'type) 14)
         (define entry (php-pb-resolve model (hash-ref f 'type-name)))
         (format "~a" (hash-ref (car (hash-ref (hash-ref entry 'enum) 'values)) 'number))]
        [else "0"]))

(define (php-pb-varint-expr f v)
  (case (hash-ref f 'type)
    [(8) (format "(~a ? 1 : 0)" v)]
    [(17) (format "(((~a << 1) ^ (~a >> 31)) & 0xffffffff)" v v)]
    [(18) (format "((~a << 1) ^ (~a >> 63))" v v)]
    [else v]))

(define (php-pb-varint-decode f v)
  (case (hash-ref f 'type)
    [(5 14) (format "(((~a & 0xffffffff) >= 0x80000000) ? ((~a & 0xffffffff) - 0x100000000) : (~a & 0xffffffff))" v v v)]
    [(13 7) (format "(~a & 0xffffffff)" v)]
    [(8) (format "(~a !== 0)" v)]
    [(17) (format "(((~a & 0xffffffff) >> 1) ^ -((~a & 0xffffffff) & 1))" v v)]
    [(18) (format "((~a >> 1) ^ -(~a & 1))" v v)]
    [else v]))

(define (php-pb-fixed-fmt f)
  (third (assv (hash-ref f 'type) php-pb-fixed)))

(define (php-pb-wire f)
  (if (= (second (assv (hash-ref f 'type) php-pb-fixed)) 8) 1 5))

(define (php-pb-nonzero f v)
  (case (hash-ref f 'type)
    [(8) v]
    [else (format "~a !== 0" v)]))

(define (php-pb-fixed-decode f src)
  (case (hash-ref f 'type)
    [(15) (format "(((unpack('V', ~a)[1]) >= 0x80000000) ? (unpack('V', ~a)[1] - 0x100000000) : unpack('V', ~a)[1])" src src src)]
    [(16) (format "(((((unpack('V', substr(~a, 4, 4))[1]) >= 0x80000000) ? (unpack('V', substr(~a, 4, 4))[1] - 0x100000000) : unpack('V', substr(~a, 4, 4))[1]) << 32) | unpack('V', substr(~a, 0, 4))[1])" src src src src)]
    [else (format "unpack(~s, ~a)[1]" (php-pb-fixed-fmt f) src)]))

(define (php-pb-encode-singular model f v indent)
  (define n (hash-ref f 'number))
  (define type (hash-ref f 'type))
  (cond [(memv type php-pb-varint-types)
         (format "~aif (~a) {\n~a    $w->tag(~a, 0);\n~a    $w->varint(~a);\n~a}\n" indent (php-pb-nonzero f v) indent n indent (php-pb-varint-expr f v) indent)]
        [(assv type php-pb-fixed)
         (format "~aif (~a != 0) {\n~a    $w->tag(~a, ~a);\n~a    $w->fixed(~s, ~a);\n~a}\n" indent v indent n (php-pb-wire f) indent
                 (if (= type 16) "P" (php-pb-fixed-fmt f))
                 (if (= type 15) (format "(~a & 0xffffffff)" v) v) indent)]
        [(= type 9) (format "~a$w->stringField(~a, ~a);\n" indent n v)]
        [(= type 12) (format "~aif (strlen(~a) > 0) {\n~a    $w->bytesField(~a, ~a);\n~a}\n" indent v indent n v indent)]
        [(= type 11) (format "~aif (~a !== null) {\n~a    $w->bytesField(~a, ~a->marshalDc());\n~a}\n" indent v indent n v indent)]
        [else (error 'emit-php-pb-file "unsupported field type ~a (groups)" type)]))

(define (php-pb-encode-field model f)
  (define v (format "$this->~a" (php-pb-field-name f)))
  (define n (hash-ref f 'number))
  (define type (hash-ref f 'type))
  (cond [(and (= type 11)
              (eq? (hash-ref (php-pb-resolve model (hash-ref f 'type-name)) 'kind) 'map))
         (define entry (php-pb-resolve model (hash-ref f 'type-name)))
         (define helper (format "encode~a" (php-pb-entry-ref model entry)))
         (format "        foreach (~a as $k => $val) {\n            $w->bytesField(~a, ~a($k, $val));\n        }\n" v n helper)]
        [(not (= (hash-ref f 'label) 3)) (php-pb-encode-singular model f v "        ")]
        [(memv type php-pb-varint-types)
         (string-append
          (format "        if (!empty(~a)) {\n            $payload = \"\";\n" v)
          (format "            foreach (~a as $x) {\n                $payload .= pbVarintBytes(~a);\n            }\n" v (php-pb-varint-expr f "$x"))
          (format "            $w->bytesField(~a, $payload);\n        }\n" n))]
        [(assv type php-pb-fixed)
         (string-append
          (format "        if (!empty(~a)) {\n            $payload = \"\";\n" v)
          (format "            foreach (~a as $x) {\n                $payload .= pack(~s, ~a);\n            }\n" v
                  (if (= type 16) "P" (php-pb-fixed-fmt f))
                  (if (= type 15) "($x & 0xffffffff)" "$x"))
          (format "            $w->bytesField(~a, $payload);\n        }\n" n))]
        [(= type 9) (format "        foreach (~a as $x) {\n            $w->bytesField(~a, $x);\n        }\n" v n)]
        [(= type 12) (format "        foreach (~a as $x) {\n            $w->bytesField(~a, $x);\n        }\n" v n)]
        [(= type 11) (format "        foreach (~a as $x) {\n            $w->bytesField(~a, $x->marshalDc());\n        }\n" v n)]
        [else (error 'emit-php-pb-file "unsupported repeated field type ~a" type)]))

(define (php-pb-decode-singular model f target src indent)
  (define type (hash-ref f 'type))
  (cond [(memv type php-pb-varint-types)
         (format "~a~a = ~a;\n" indent target (php-pb-varint-decode f src))]
        [(assv type php-pb-fixed)
         (format "~a~a = ~a;\n" indent target (php-pb-fixed-decode f src))]
        [(= type 9) (format "~a~a = ~a;\n" indent target src)]
        [(= type 12) (format "~a~a = ~a;\n" indent target src)]
        [(= type 11)
         (define ref (php-pb-entry-ref model (php-pb-resolve model (hash-ref f 'type-name))))
         (string-append
          (format "~a~a = new ~a();\n" indent target ref)
          (format "~a~a->unmarshalDc(~a);\n" indent target src))]
        [else (error 'emit-php-pb-file "unsupported field type ~a" type)]))

(define (php-pb-decode-case model f)
  (define v (format "$this->~a" (php-pb-field-name f)))
  (define type (hash-ref f 'type))
  (define head (format "                case ~a:\n" (hash-ref f 'number)))
  (define foot "                    break;\n")
  (cond [(and (= type 11)
              (eq? (hash-ref (php-pb-resolve model (hash-ref f 'type-name)) 'kind) 'map))
         (define entry (php-pb-resolve model (hash-ref f 'type-name)))
         (define helper (format "decode~a" (php-pb-entry-ref model entry)))
         (string-append head
                        (format "                    [$kk, $vv] = ~a($bytesValue);\n" helper)
                        (format "                    ~a[$kk] = $vv;\n" v)
                        foot)]
        [(not (= (hash-ref f 'label) 3))
         (string-append head
                        (php-pb-decode-singular model f v
                                                (cond [(memv type php-pb-varint-types) "$varintValue"]
                                                      [(assv type php-pb-fixed) "$fixedValue"]
                                                      [else "$bytesValue"])
                                                "                    ")
                        foot)]
        [(memv type php-pb-varint-types)
         (string-append head
                        "                    if ($wire === 2) {\n"
                        "                        $sub = new Reader($bytesValue);\n"
                        "                        while (!$sub->done()) {\n"
                        "                            $raw = $sub->varint();\n"
                        (format "                            ~a[] = ~a;\n" v (php-pb-varint-decode f "$raw"))
                        "                        }\n                    } else {\n"
                        (format "                        ~a[] = ~a;\n" v (php-pb-varint-decode f "$varintValue"))
                        "                    }\n"
                        foot)]
        [(assv type php-pb-fixed)
         (string-append head
                        "                    if ($wire === 2) {\n"
                        (format "                        for ($i = 0; $i < strlen($bytesValue); $i += ~a) {\n" (second (assv type php-pb-fixed)))
                        (format "                            ~a[] = ~a;\n" v (php-pb-fixed-decode f (format "substr($bytesValue, $i, ~a)" (second (assv type php-pb-fixed)))))
                        "                        }\n                    } else {\n"
                        (format "                        ~a[] = ~a;\n" v (php-pb-fixed-decode f "$fixedValue"))
                        "                    }\n"
                        foot)]
        [(= type 9) (string-append head (format "                    ~a[] = $bytesValue;\n" v) foot)]
        [(= type 12) (string-append head (format "                    ~a[] = $bytesValue;\n" v) foot)]
        [(= type 11)
         (string-append head
                        (format "                    $item = new ~a();\n" (php-pb-entry-ref model (php-pb-resolve model (hash-ref f 'type-name))))
                        "                    $item->unmarshalDc($bytesValue);\n"
                        (format "                    ~a[] = $item;\n" v)
                        foot)]
        [else (error 'emit-php-pb-file "unsupported repeated field type ~a" type)]))

(define (php-pb-map-helpers model entry)
  (define msg (hash-ref entry 'msg))
  (define base (php-pb-entry-ref model entry))
  (define key-f (findf (lambda (x) (= (hash-ref x 'number) 1)) (hash-ref msg 'fields)))
  (define val-f (findf (lambda (x) (= (hash-ref x 'number) 2)) (hash-ref msg 'fields)))
  (unless (and key-f val-f) (error 'emit-php-pb-file "map entry ~a lacks key/value" (hash-ref msg 'full-name)))
  (string-append
   (format "function encode~a($key, $value): string\n{\n    $w = new Writer();\n" base)
   (php-pb-encode-singular model (hash-set key-f 'label 1) "$key" "    ")
   (php-pb-encode-singular model (hash-set val-f 'label 1) "$value" "    ")
   "    return $w->toBytes();\n}\n\n"
   (format "function decode~a(string $data): array\n{\n" base)
   (format "    $key = ~a;\n    $value = ~a;\n" (php-pb-default model (hash-set key-f 'label 1)) (php-pb-default model (hash-set val-f 'label 1)))
   "    $r = new Reader($data);\n    while (($item = $r->field()) !== null) {\n        [$num, $wire, $varintValue, $bytesValue, $fixedValue] = $item;\n"
   (format "        if ($num === ~a) {\n~a" (hash-ref key-f 'number)
           (php-pb-decode-singular model (hash-set key-f 'label 1) "$key"
                                   (cond [(memv (hash-ref key-f 'type) php-pb-varint-types) "$varintValue"]
                                         [(assv (hash-ref key-f 'type) php-pb-fixed) "$fixedValue"]
                                         [else "$bytesValue"]) "            "))
   (format "        } elseif ($num === ~a) {\n~a" (hash-ref val-f 'number)
           (if (= (hash-ref val-f 'type) 11)
               (format "            $value = new ~a();\n            $value->unmarshalDc($bytesValue);\n"
                       (php-pb-entry-ref model (php-pb-resolve model (hash-ref val-f 'type-name))))
               (php-pb-decode-singular model (hash-set val-f 'label 1) "$value"
                                       (cond [(memv (hash-ref val-f 'type) php-pb-varint-types) "$varintValue"]
                                             [(assv (hash-ref val-f 'type) php-pb-fixed) "$fixedValue"]
                                             [else "$bytesValue"]) "            ")))
   "        }\n    }\n    return [$key, $value];\n}\n\n"))

(define php-pb-support
  (string-append
   "function pbVarintBytes(int $value): string\n{\n    $out = \"\";\n    $v = $value;\n    while (true) {\n        $b = $v & 0x7f;\n        $v = ($v >> 7) & 0x01ffffffffffffff;\n        if ($v === 0) {\n            return $out . chr($b);\n        }\n        $out .= chr($b | 0x80);\n    }\n}\n\n"
   "final class Writer\n{\n    private string $out = \"\";\n\n"
   "    public function varint(int $value): void\n    {\n        $this->out .= pbVarintBytes($value);\n    }\n\n"
   "    public function tag(int $field, int $wire): void\n    {\n        $this->varint(($field << 3) | $wire);\n    }\n\n"
   "    public function bytesField(int $field, string $payload): void\n    {\n        $this->tag($field, 2);\n        $this->varint(strlen($payload));\n        $this->out .= $payload;\n    }\n\n"
   "    public function stringField(int $field, string $value): void\n    {\n        if ($value === \"\") {\n            return;\n        }\n        $this->bytesField($field, $value);\n    }\n\n"
   "    public function fixed(string $fmt, $value): void\n    {\n        $this->out .= pack($fmt, $value);\n    }\n\n"
   "    public function toBytes(): string\n    {\n        return $this->out;\n    }\n}\n\n"
   "final class Reader\n{\n    private string $buf;\n    private int $pos = 0;\n\n"
   "    public function __construct(string $buf)\n    {\n        $this->buf = $buf;\n    }\n\n"
   "    public function done(): bool\n    {\n        return $this->pos >= strlen($this->buf);\n    }\n\n"
   "    public function varint(): int\n    {\n        $result = 0;\n        $shift = 0;\n        while (true) {\n            if ($this->pos >= strlen($this->buf)) {\n                throw new \\InvalidArgumentException(\"truncated varint\");\n            }\n            $b = ord($this->buf[$this->pos]);\n            $this->pos++;\n            if ($shift < 63) {\n                $result |= ($b & 0x7f) << $shift;\n            } elseif (($b & 1) !== 0) {\n                $result |= PHP_INT_MIN;\n            }\n            if (($b & 0x80) === 0) {\n                return $result;\n            }\n            $shift += 7;\n            if ($shift >= 70) {\n                throw new \\InvalidArgumentException(\"varint too long\");\n            }\n        }\n    }\n\n"
   "    public function take(int $n): string\n    {\n        if ($this->pos + $n > strlen($this->buf)) {\n            throw new \\InvalidArgumentException(\"truncated field\");\n        }\n        $value = substr($this->buf, $this->pos, $n);\n        $this->pos += $n;\n        return $value;\n    }\n\n"
   "    /** [number, wire, varint_value, bytes_value, fixed_value] or null. */\n"
   "    public function field(): ?array\n    {\n        if ($this->done()) {\n            return null;\n        }\n        $tag = $this->varint();\n        $num = $tag >> 3;\n        $wire = $tag & 7;\n        switch ($wire) {\n            case 0:\n                return [$num, $wire, $this->varint(), \"\", \"\"];\n            case 2:\n                $n = $this->varint();\n                return [$num, $wire, 0, $this->take($n), \"\"];\n            case 1:\n                return [$num, $wire, 0, \"\", $this->take(8)];\n            case 5:\n                return [$num, $wire, 0, \"\", $this->take(4)];\n            default:\n                throw new \\InvalidArgumentException(\"bad wire type\");\n        }\n    }\n}\n\n"))

(define (php-pb-message-class model msg)
  (define name (php-pb-flat (hash-ref model 'package) (hash-ref msg 'full-name)))
  (define fields (hash-ref msg 'fields))
  (string-append
   (format "class ~a\n{\n" name)
   (apply string-append
          (map (lambda (f) (format "    public ~a $~a = ~a;\n" (php-pb-type model f) (php-pb-field-name f) (php-pb-default model f))) fields))
   (if (null? fields) "" "\n")
   (format "    public function __construct(~a)\n    {\n" (string-join (map (lambda (f) (format "~a $~a = ~a" (php-pb-type model f) (php-pb-field-name f) (php-pb-default model f))) fields) ", "))
   (apply string-append (map (lambda (f) (format "        $this->~a = $~a;\n" (php-pb-field-name f) (php-pb-field-name f))) fields))
   "    }\n\n"
   "    public function marshalDc(): string\n    {\n        $w = new Writer();\n"
   (apply string-append (map (lambda (f) (php-pb-encode-field model f)) fields))
   "        return $w->toBytes();\n    }\n\n"
   "    public function unmarshalDc(string $data): self\n    {\n"
   (apply string-append (map (lambda (f) (format "        $this->~a = ~a;\n" (php-pb-field-name f) (php-pb-default model f))) fields))
   "        $r = new Reader($data);\n        while (($item = $r->field()) !== null) {\n            [$num, $wire, $varintValue, $bytesValue, $fixedValue] = $item;\n            switch ($num) {\n"
   (apply string-append (map (lambda (f) (php-pb-decode-case model f)) fields))
   "            }\n        }\n        return $this;\n    }\n\n"
   (format "    public function equals(?object $other): bool\n    {\n        return $other instanceof ~a~a;\n    }\n}\n\n" name
           (if (null? fields)
               ""
               (string-append "\n            && " (string-join (map (lambda (f) (format "$this->~a === $other->~a" (php-pb-field-name f) (php-pb-field-name f))) fields) "\n            && "))))
   (apply string-append (map (lambda (n) (php-pb-message-class model n)) (hash-ref msg 'nested)))))

(define (php-pb-enum model e)
  (define name (php-pb-flat (hash-ref model 'package)
                            (if (string=? (hash-ref model 'package) "")
                                (hash-ref e 'name)
                                (format "~a.~a" (hash-ref model 'package) (hash-ref e 'name)))))
  (string-append
   (format "final class ~a\n{\n" name)
   (apply string-append
          (map (lambda (v) (format "    public const ~a = ~a;\n" (hash-ref v 'name) (hash-ref v 'number)))
               (hash-ref e 'values)))
   "}\n\n"))

(define (emit-php-pb-file file-model)
  (and (hash-has-key? file-model 'messages)
       (hash-has-key? file-model 'types)
       (emit-php-pb-file/inner file-model)))

(define (emit-php-pb-file/inner file-model)
  (define messages (hash-ref file-model 'messages))
  (define enums (hash-ref file-model 'enums))
  (and (or (pair? messages) (pair? enums))
       (let ()
         (define base (path->string (path-replace-extension
                                     (file-name-from-path (hash-ref file-model 'name)) "")))
         (define pkg (hash-ref file-model 'package))
         (define seen-maps (mutable-set))
         (define helpers '())
         (define (collect msg)
           (for ([f (in-list (hash-ref msg 'fields))])
             (when (= (hash-ref f 'type) 11)
               (define e (php-pb-resolve file-model (hash-ref f 'type-name)))
               (when (and (eq? (hash-ref e 'kind) 'map)
                          (equal? (hash-ref e 'file) (hash-ref file-model 'name))
                          (not (set-member? seen-maps (hash-ref (hash-ref e 'msg) 'full-name))))
                 (set-add! seen-maps (hash-ref (hash-ref e 'msg) 'full-name))
                 (set! helpers (cons (php-pb-map-helpers file-model e) helpers)))))
           (for ([n (in-list (hash-ref msg 'nested))]) (collect n)))
         (for ([m (in-list messages)]) (collect m))
         (define dep-modules
           (remove-duplicates
            (map (lambda (d)
                   (path->string (path-replace-extension (file-name-from-path d) "")))
                 (hash-ref file-model 'dependencies))))
         (define content
           (string-append
            "<?php\n// @generated by protoc-gen-grpc-dc-php (Racket metaprogram). DO NOT EDIT.\n\n"
            (format "namespace ~aPb;\n\n" (camel base))
            (apply string-append
                   (map (lambda (d) (format "require_once __DIR__ . \"/~a_pb.php\";\n" d)) dep-modules))
            (if (null? dep-modules) "" "\n")
            php-pb-support
            (apply string-append (map (lambda (e) (php-pb-enum file-model e)) enums))
            (apply string-append
                   (map (lambda (m) (php-pb-message-class file-model m))
                        (filter (lambda (m) (not (hash-ref m 'map-entry))) messages)))
            (apply string-append (reverse helpers))))
         (cons (string-append base "_pb.php") content))))

(define (emit-php-file file-model params)
  (define base (path->string (path-replace-extension
                              (file-name-from-path (hash-ref file-model 'name)) "")))
  (define pb (string-append (camel base) "Pb"))
  (define ns (string-append (camel base) "GrpcDc"))
  (define stub
    (cons (string-append base "_grpc_dc.php")
        (string-append
         "<?php\n// @generated by protoc-gen-grpc-dc-php (Racket metaprogram). DO NOT EDIT.\n"
         (format "// source: ~a\n\n" (hash-ref file-model 'name))
         (format "namespace ~a;\n\n" ns)
         (format "require_once __DIR__ . \"/~a_pb.php\";\n" base)
         "require_once __DIR__ . \"/../grpcdc.php\";\n\n"
         php-stream-helpers
         (apply string-append
                (map (lambda (svc) (php-service pb svc))
                     (hash-ref file-model 'services))))))
  (define pb-file (emit-php-pb-file file-model))
  (if pb-file (list stub pb-file) stub))
