#lang racket

;;; runner.rkt — generic in-browser plugin host, seeded by
;;; webapp/app.js as /tmp/main.rkt next to /tmp/plugins/<lang>.rkt
;;; (the assembled bin/protoc-gen-grpc-dc-* sources, verbatim).
;;;
;;; Protocol (line-framed, page <-> runner over stdin/stdout):
;;;   runner -> page: "GRPCDC-RUNNER-READY\n" once at startup.
;;;   page -> runner: one JSON line per batch:
;;;     {"jobs":[{"lang":"python","requestB64":"<b64 request>"}, ...]}
;;;   runner -> page per job: "GRPCDC/1 <lang> <byte-count>\n" +
;;;     <byte-count raw bytes: the plugin's CodeGeneratorResponse>,
;;;     or "GRPCDC-ERR <lang> <byte-count>\n" + error text.
;;; The first job for a language dynamic-requires the plugin
;;; module (its top level calls plugin-main once, under redirected
;;; byte ports); later jobs invoke the module's plugin-main
;;; procedure directly in the module's own namespace.

(require json net/base64)

(define plugins-dir "/tmp/plugins")
(define loaded (make-hash))

(define (plugin-path lang)
  (string->path (string-append plugins-dir "/" lang ".rkt")))

(define (run-job lang request-bytes)
  (define collected (open-output-bytes))
  (define mod (plugin-path lang))
  (parameterize ([current-input-port (open-input-bytes request-bytes)]
                 [current-output-port collected])
    (cond [(hash-has-key? loaded lang)
           (parameterize ([current-namespace (module->namespace mod)])
             ((namespace-variable-value 'plugin-main #t)))]
          [else
           (hash-set! loaded lang #t)
           (dynamic-require mod #f)]))
  (get-output-bytes collected))

(display "GRPCDC-RUNNER-READY\n")
(flush-output)
(let loop ()
  (define line (read-line (current-input-port) 'any))
  (unless (eof-object? line)
    (define batch (string->jsexpr line))
    (for ([job (in-list (hash-ref batch 'jobs))])
      (define lang (hash-ref job 'lang))
      (with-handlers ([exn:fail?
                       (lambda (e)
                         (define msg (string->bytes/utf-8 (exn-message e)))
                         (printf "GRPCDC-ERR ~a ~a\n" lang (bytes-length msg))
                         (write-bytes msg)
                         (flush-output))])
        (define request
          (base64-decode (string->bytes/utf-8 (hash-ref job 'requestB64))))
        (define response (run-job lang request))
        (printf "GRPCDC/1 ~a ~a\n" lang (bytes-length response))
        (write-bytes response)
        (flush-output)))
    (loop)))
