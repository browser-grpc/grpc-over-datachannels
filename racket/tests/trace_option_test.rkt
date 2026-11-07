#lang racket

;;; trace=off|hooks plugin option: with trace=hooks every native
;;; template wires the runtime tracer registrar into the stub
;;; (and bakes trace_methods as a filter); with trace off (the
;;; default) no registrar appears. JS is the documented
;;; exception: its stubs never import the runtime, so hooks and
;;; off output are identical (SPEC.md, Tracing).

(require rackunit racket/runtime-path
         "../spec.rkt" "../pb.rkt" "../desc.rkt"
         "../template-rust.rkt" "../template-js.rkt" "../template-go.rkt"
         "../template-python.rkt" "../template-java.rkt" "../template-csharp.rkt"
         "../template-cpp.rkt" "../template-swift.rkt" "../template-kotlin.rkt"
         "../template-dart.rkt" "../template-zig.rkt" "../template-c.rkt"
         "../template-lua.rkt" "../template-ruby.rkt" "../template-php.rkt"
         "../template-scala.rkt")

;; Build the file model through the real descriptor walk, so
;; every template sees the full model it gets from protoc.
(define (msg-desc name)
  (pb-bytes-field 4
    (bytes-append (pb-string-field 1 name)
                  (pb-bytes-field 2
                    (bytes-append (pb-string-field 1 "message")
                                  (pb-varint-field 3 1)
                                  (pb-varint-field 4 1)
                                  (pb-varint-field 5 9))))))
(define method-desc
  (bytes-append (pb-string-field 1 "Unary")
                (pb-string-field 2 ".echo.EchoRequest")
                (pb-string-field 3 ".echo.EchoResponse")))
(define file-desc
  (bytes-append (pb-string-field 1 "echo.proto")
                (pb-string-field 2 "echo")
                (msg-desc "EchoRequest")
                (msg-desc "EchoResponse")
                (pb-bytes-field 6
                  (bytes-append (pb-string-field 1 "Echo")
                                (pb-bytes-field 2 method-desc)))
                (pb-string-field 12 "proto3")))
(define request
  (bytes-append (pb-string-field 1 "echo.proto") (pb-bytes-field 15 file-desc)))
(define-values (model-files _param) (parse-request request))
(define model (first model-files))

(define (emit-string emit params)
  (define out (emit model params))
  ;; Emitters return one (name . content) pair, or a list of
  ;; them when a pb file is also produced; join all contents.
  (if (and (pair? out) (string? (car out)))
      (cdr out)
      (string-join (map cdr out) "\n")))

;; (language emit registrar-token-in-hooks-output)
(define cases
  (list (list "rust" (lambda (m p) (emit-rust-file m p)) "set_tracer")
        (list "go" (lambda (m p) (emit-go-file m p)) "SetTracer")
        (list "python" (lambda (m p) (emit-python-file m p)) "set_tracer = grpcdc.set_tracer")
        (list "java" (lambda (m p) (emit-java-file m p)) "grpcdc.Tracing.setTracer")
        (list "csharp" (lambda (m p) (emit-csharp-file m p)) "Tracing.SetTracer")
        (list "cpp" (lambda (m p) (emit-cpp-file m p)) "grpcdc::Tracing::SetTracer")
        (list "swift" (lambda (m p) (emit-swift-file m p)) "Tracing.SetTracer")
        (list "kotlin" (lambda (m p) (emit-kotlin-file m p)) "grpcdc.Tracing.setTracer")
        (list "dart" (lambda (m p) (emit-dart-file m p)) "show setTracer, setTraceFilter")
        (list "zig" (lambda (m p) (emit-zig-file m p)) "status_mod.setTracer")
        (list "c" (lambda (m p) (emit-c-file m p)) "grpcdc_set_tracer")
        (list "lua" (lambda (m p) (emit-lua-file m p)) "statusModule.setTracer")
        (list "ruby" (lambda (m p) (emit-ruby-file m p)) "Grpcdc.set_tracer")
        (list "php" (lambda (m p) (emit-php-file m p)) "Status::setTracer")
        (list "scala" (lambda (m p) (emit-scala-file m p)) "grpcdc.Tracing.setTracer")))

(define off-params (hasheq))
(define hooks-params (hasheq 'trace "hooks"))
(define methods-params (hasheq 'trace "hooks" 'trace_methods "/echo.Echo/*"))

(for ([c (in-list cases)])
  (define lang (first c))
  (define emit (second c))
  (define token (third c))
  (define off-out (emit-string emit off-params))
  (define hooks-out (emit-string emit hooks-params))
  (define methods-out (emit-string emit methods-params))
  (check-false (string-contains? off-out token)
               (format "~a: no registrar with trace off" lang))
  (check-true (string-contains? hooks-out token)
              (format "~a: registrar wired with trace=hooks" lang))
  (check-true (string-contains? methods-out "/echo.Echo/*")
              (format "~a: trace_methods filter baked" lang)))

;; JS exception: stubs never import the runtime, so the option
;; changes nothing in the emitted stub.
(check-equal? (emit-string (lambda (m p) (emit-js-file m p)) hooks-params)
              (emit-string (lambda (m p) (emit-js-file m p)) off-params)
              "js: hooks == off (documented exception)")

;; Plugin-main parameter validation, through real protoc: a
;; bogus trace value and trace_methods without trace=hooks are
;; usage errors (metagen.rkt plugin-main-template).
(define-runtime-path repo-root "../../")
(define protoc (find-executable-path "protoc"))
(when protoc
  (define plugin (path->string (build-path repo-root
                                           "bin/protoc-gen-grpc-dc-python")))
  (define (protoc-fails opt)
    (define out (open-output-string))
    (define ok
      (parameterize ([current-output-port out]
                     [current-error-port out])
        (system (format "~a --plugin=protoc-gen-grpc-dc-python=~a '--grpc-dc-python_opt=~a' --grpc-dc-python_out=/tmp/trace-opt-out -I ~a ~a"
                        (path->string protoc) plugin opt
                        (path->string (build-path repo-root "proto"))
                        (path->string (build-path repo-root "proto/echo.proto"))))))
    (values (not ok) (get-output-string out)))
  (define-values (bogus-fails bogus-out) (protoc-fails "trace=bogus"))
  (check-true bogus-fails "plugin rejects trace=bogus")
  (check-true (string-contains? bogus-out "unknown trace option")
              "plugin names the bad trace value")
  (define-values (orphan-fails orphan-out)
    (protoc-fails "trace_methods=/echo.Echo/*"))
  (check-true orphan-fails "plugin rejects trace_methods without hooks")
  (check-true (string-contains? orphan-out "requires trace=hooks")
              "plugin explains trace_methods gating"))

(printf "trace option tests passed\n")
