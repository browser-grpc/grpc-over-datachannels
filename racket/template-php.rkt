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

(require "spec.rkt" "desc.rkt" "segments.rkt")
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
  (run-segments php-deprecated-program m ""))
(define (php-client-method model m)
  (run-segments php-client-method-program m "" model))
(define (php-fiber-client-method model m)
  (run-segments php-fiber-client-method-program m "" model))
(define (php-server-handler model m)
  (run-segments php-server-handler-program m "" model))
(define (php-method-entry m)
  (run-segments php-method-entry-program m ""))
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
   "    /** Response initial metadata (after the first recv). */\n"
   "    public function headers(): ?array\n"
   "    {\n        return $this->stream->headers?->metadata;\n    }\n\n"
   "    /** Response trailing metadata (after the call ends). */\n"
   "    public function trailers(): ?array\n"
   "    {\n        return $this->stream->trailers;\n    }\n\n"
   "    /** Abandon the call early: RST so the server stops producing. */\n"
   "    public function cancel(): void\n"
   "    {\n        $this->stream->cancel();\n    }\n\n"
   "    public function close(): void\n"
   "    {\n        $this->stream->cancel();\n    }\n\n"
   "    public function __destruct()\n"
   "    {\n        $this->close();\n    }\n\n"
   "    /** @return \\Generator<int, object> */\n"
   "    public function iterate(): \\Generator\n"
   "    {\n        $completed = false;\n        try {\n            while (true) {\n                yield $this->recv();\n            }\n        } catch (\\Grpcdc\\CallClosed $e) {\n            $completed = true;\n            return;\n        } finally {\n            if (!$completed) {\n                $this->close();\n            }\n        }\n    }\n"
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
   "    {\n        $completed = false;\n        try {\n            while (true) {\n                yield $this->next();\n            }\n        } catch (\\Grpcdc\\CallClosed $e) {\n            $completed = true;\n            return;\n        } finally {\n            if (!$completed) {\n                $this->close();\n            }\n        }\n    }\n\n"
   "    /** Response initial metadata (after the first recv). */\n"
   "    public function headers(): ?array\n"
   "    {\n        return $this->stream->headers?->metadata;\n    }\n\n"
   "    /** Response trailing metadata (after the call ends). */\n"
   "    public function trailers(): ?array\n"
   "    {\n        return $this->stream->trailers;\n    }\n\n"
   "    public function cancel(): void\n"
   "    {\n        $this->stream->cancel();\n    }\n\n"
   "    public function close(): void\n"
   "    {\n        $this->stream->cancel();\n    }\n\n"
   "    public function __destruct()\n"
   "    {\n        $this->close();\n    }\n"
   "}\n\n"))

(define (php-service model svc)
  (run-segments php-service-program svc (hash-ref svc 'name) model))
(define php-pb-varint-types varint-scalar-types)
;; type -> (size pack-format) for float/double/fixed32/fixed64.
;; sfixed32/sfixed64 decode through unsigned + sign conversion.
(define php-pb-fixed (fixed-scalar-table 'php))

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

;; PHP reserved words cannot be class names (e.g. the interop
;; Empty message): escape by appending an underscore.
(define php-pb-reserved
  (list->set
   (map string-downcase
        '("abstract" "and" "array" "as" "break" "callable" "case" "catch"
          "class" "clone" "const" "continue" "declare" "default" "do" "echo"
          "else" "elseif" "empty" "enddeclare" "endfor" "endforeach" "endif"
          "endswitch" "endwhile" "enum" "eval" "exit" "extends" "final"
          "finally" "fn" "for" "foreach" "function" "global" "goto" "if"
          "implements" "include" "include_once" "instanceof" "insteadof"
          "interface" "isset" "list" "match" "namespace" "new" "or" "parent"
          "print" "private" "protected" "public" "readonly" "require"
          "require_once" "return" "self" "static" "switch" "throw" "trait"
          "try" "unset" "use" "var" "while" "xor" "yield" "int" "float"
          "bool" "string" "true" "false" "null" "void" "iterable" "object"
          "mixed" "never" "resource" "numeric"))))

(define (php-pb-flat pkg full)
  (define rel (if (and pkg (not (string=? pkg "")) (string-prefix? full (string-append pkg ".")))
                  (substring full (add1 (string-length pkg)))
                  full))
  (define flat (string-join (string-split rel ".") "_"))
  (if (set-member? php-pb-reserved (string-downcase flat))
      (string-append flat "_")
      flat))

(define (php-pb-resolve model type-name)
  (hash-ref (hash-ref model 'types) type-name
            (lambda () (error 'emit-php-pb-file "unresolved type ~a" type-name))))

;; Stub-side reference to a message type: always qualified with
;; the pb namespace of the file that defines it (method types
;; often live in an imported file, not the service's own file).
(define (php-stub-ref file-model full)
  (define e (php-pb-resolve file-model full))
  (format "\\~a\\~a" (php-pb-namespace e)
          (php-pb-flat (hash-ref e 'pkg)
                       (hash-ref (hash-ref e 'msg) 'full-name))))

;; require_once lines for the pb file of every file that defines
;; a method input/output type.
(define (php-stub-requires file-model)
  (if (hash-ref file-model 'types #f)
      (apply string-append
             (map (lambda (fn)
                    (format "require_once __DIR__ . \"/~a_pb.php\";\n"
                            (path->string
                             (path-replace-extension (file-name-from-path fn) ""))))
                  (remove-duplicates
                   (append-map
                    (lambda (svc)
                      (append-map
                       (lambda (m)
                         (list (hash-ref (php-pb-resolve file-model (hash-ref m 'input-full)) 'file)
                               (hash-ref (php-pb-resolve file-model (hash-ref m 'output-full)) 'file)))
                       (hash-ref svc 'methods)))
                    (hash-ref file-model 'services)))))
      (format "require_once __DIR__ . \"/~a_pb.php\";\n"
              (path->string (path-replace-extension
                             (file-name-from-path (hash-ref file-model 'name)) "")))))

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
  (run-segments php-pb-type-program f "" model))
(define (php-pb-explicit-literal model f)
  (define lit (run-segments php-pb-explicit-literal-program f "" model))
  (and (not (string=? lit "")) lit))
(define (php-pb-default model f)
  (run-segments php-pb-default-program f "" model))
(define (php-pb-varint-expr f v)
  (run-segments php-pb-varint-expr-program f "" #f (list v)))
(define (php-pb-varint-decode f v)
  (run-segments php-pb-varint-decode-program f "" #f (list v)))
(define (php-pb-nonzero f v)
  (run-segments php-pb-nonzero-program f "" #f (list v)))
(define (php-pb-fixed-decode f src)
  (run-segments php-pb-fixed-decode-program f "" #f (list src)))
(define (php-pb-encode-singular model f v indent)
  (run-segments php-pb-encode-singular-program f "" model (list v indent)))
(define (php-pb-encode-field model f)
  (run-segments php-pb-encode-field-program f "" model))
(define (php-pb-decode-singular model f target src indent)
  (run-segments php-pb-decode-singular-program f "" model (list target src indent)))
(define (php-pb-oneof-clearing model f)
  (run-segments php-pb-oneof-clearing-program f "" model))
(define (php-pb-decode-case model f)
  (run-segments php-pb-decode-case-program f "" model))
(define (php-pb-map-helpers model entry)
  (run-segments php-pb-map-helpers-program entry "" model))
(define php-pb-support
  (string-append
   "function pbVarintBytes(int $value): string\n{\n    $out = \"\";\n    $v = $value;\n    while (true) {\n        $b = $v & 0x7f;\n        $v = ($v >> 7) & 0x01ffffffffffffff;\n        if ($v === 0) {\n            return $out . chr($b);\n        }\n        $out .= chr($b | 0x80);\n    }\n}\n\n"
   "final class Writer\n{\n    private string $out = \"\";\n\n"
   "    public function varint(int $value): void\n    {\n        $this->out .= pbVarintBytes($value);\n    }\n\n"
   "    public function tag(int $field, int $wire): void\n    {\n        $this->varint(($field << 3) | $wire);\n    }\n\n"
   "    public function bytesField(int $field, string $payload): void\n    {\n        $this->tag($field, 2);\n        $this->varint(strlen($payload));\n        $this->out .= $payload;\n    }\n\n"
   "    public function stringField(int $field, string $value): void\n    {\n        if ($value === \"\") {\n            return;\n        }\n        $this->bytesField($field, $value);\n    }\n\n"
   "    public function fixed(string $fmt, $value): void\n    {\n        $this->out .= pack($fmt, $value);\n    }\n\n"
   "    public function raw(string $payload): void\n    {\n        $this->out .= $payload;\n    }\n\n"
   "    public function toBytes(): string\n    {\n        return $this->out;\n    }\n}\n\n"
   "final class Reader\n{\n    private string $buf;\n    private int $pos = 0;\n\n"
   "    public function __construct(string $buf)\n    {\n        $this->buf = $buf;\n    }\n\n"
   "    public function done(): bool\n    {\n        return $this->pos >= strlen($this->buf);\n    }\n\n"
   "    public function varint(): int\n    {\n        $result = 0;\n        $shift = 0;\n        while (true) {\n            if ($this->pos >= strlen($this->buf)) {\n                throw new \\InvalidArgumentException(\"truncated varint\");\n            }\n            $b = ord($this->buf[$this->pos]);\n            $this->pos++;\n            if ($shift < 63) {\n                $result |= ($b & 0x7f) << $shift;\n            } elseif (($b & 1) !== 0) {\n                $result |= PHP_INT_MIN;\n            }\n            if (($b & 0x80) === 0) {\n                return $result;\n            }\n            $shift += 7;\n            if ($shift >= 70) {\n                throw new \\InvalidArgumentException(\"varint too long\");\n            }\n        }\n    }\n\n"
   "    public function take(int $n): string\n    {\n        if ($this->pos + $n > strlen($this->buf)) {\n            throw new \\InvalidArgumentException(\"truncated field\");\n        }\n        $value = substr($this->buf, $this->pos, $n);\n        $this->pos += $n;\n        return $value;\n    }\n\n"
   "    /** [number, wire, varint_value, bytes_value, fixed_value] or null. */\n"
   "    public function field(): ?array\n    {\n        if ($this->done()) {\n            return null;\n        }\n        $start = $this->pos;\n        $tag = $this->varint();\n        $num = $tag >> 3;\n        $wire = $tag & 7;\n        switch ($wire) {\n            case 0:\n                $v = $this->varint();\n                return [$num, $wire, $v, \"\", \"\", substr($this->buf, $start, $this->pos - $start)];\n            case 2:\n                $n = $this->varint();\n                $b = $this->take($n);\n                return [$num, $wire, 0, $b, \"\", substr($this->buf, $start, $this->pos - $start)];\n            case 1:\n                $b = $this->take(8);\n                return [$num, $wire, 0, \"\", $b, substr($this->buf, $start, $this->pos - $start)];\n            case 5:\n                $b = $this->take(4);\n                return [$num, $wire, 0, \"\", $b, substr($this->buf, $start, $this->pos - $start)];\n            default:\n                throw new \\InvalidArgumentException(\"bad wire type\");\n        }\n    }\n}\n\n"))

(define (php-pb-message-class model msg)
  (run-segments php-pb-message-program msg "" model))
(define (php-pb-enum model e)
  (run-segments php-pb-enum-program e "" model
                (list (if (string=? (hash-ref model 'package) "")
                          (hash-ref e 'name)
                          (format "~a.~a" (hash-ref model 'package) (hash-ref e 'name))))))
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
            "<?php\n// @generated by protoc-gen-grpc-dc-php. DO NOT EDIT.\n\n"
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
  (define ns (string-append (camel base) "GrpcDc"))
  (define stub
    (cons (string-append base "_grpc_dc.php")
        (string-append
         "<?php\n// @generated by protoc-gen-grpc-dc-php. DO NOT EDIT.\n"
         (format "// source: ~a\n\n" (hash-ref file-model 'name))
         (format "namespace ~a;\n\n" ns)
         (php-stub-requires file-model)
         "require_once __DIR__ . \"/../grpcdc.php\";\n\n"
         ;; trace=hooks: baking + namespaced delegates to \Status.
         (if (equal? (hash-ref params 'trace #f) "hooks")
             (string-append
              "// Tracing (trace=hooks): register an observer via set_tracer().\n"
              "function set_tracer(mixed $t): void { \\Status::setTracer($t); }\n"
              "function set_trace_filter(string $p): void { \\Status::setTraceFilter($p); }\n\n"
              (let ([methods (hash-ref params 'trace_methods #f)])
                (if methods
                    (format "\\Status::setTraceFilter(~s);\n\n" methods)
                    "")))
             "")
         php-stream-helpers
         (apply string-append
                (map (lambda (svc) (php-service file-model svc))
                     (hash-ref file-model 'services))))))
  (define pb-file (emit-php-pb-file file-model))
  (if pb-file (list stub pb-file) stub))
