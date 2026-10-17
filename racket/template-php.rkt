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

(define (emit-php-file file-model params)
  (define base (path->string (path-replace-extension
                              (file-name-from-path (hash-ref file-model 'name)) "")))
  (define pb (string-append (camel base) "Pb"))
  (define ns (string-append (camel base) "GrpcDc"))
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
