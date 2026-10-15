#lang racket

;;; Deprecation stamping: a synthetic file model with one deprecated
;;; unary method must produce each language's annotation in the
;;; generated stub (desc.rkt surfaces MethodOptions.deprecated=33).

(require rackunit
         "../template-rust.rkt" "../template-js.rkt" "../template-go.rkt"
         "../template-python.rkt" "../template-java.rkt" "../template-csharp.rkt")

(define deprecated-model
  (hasheq 'name "echo.proto" 'package "echo"
          'services
          (list (hasheq 'name "Echo" 'full-name "echo.Echo" 'deprecated #f
                        'methods
                        (list (hasheq 'name "Old" 'path "/echo.Echo/Old"
                                      'input "EchoRequest" 'output "EchoResponse"
                                      'kind 'unary 'deprecated #t))))
          'method-count 1))

(define plain-model
  (hasheq 'name "echo.proto" 'package "echo"
          'services
          (list (hasheq 'name "Echo" 'full-name "echo.Echo" 'deprecated #f
                        'methods
                        (list (hasheq 'name "Old" 'path "/echo.Echo/Old"
                                      'input "EchoRequest" 'output "EchoResponse"
                                      'kind 'unary 'deprecated #f))))))

(define emitters
  (list (cons "rust" (lambda (m) (emit-rust-file m (hasheq))))
        (cons "js" (lambda (m) (emit-js-file m (hasheq))))
        (cons "go" (lambda (m) (emit-go-file m (hasheq))))
        (cons "python" (lambda (m) (emit-python-file m (hasheq))))
        (cons "java" (lambda (m) (emit-java-file m (hasheq))))
        (cons "csharp" (lambda (m) (emit-csharp-file m (hasheq))))))

(for ([e (in-list emitters)])
  (define out (cdr ((cdr e) deprecated-model)))
  (check-true (regexp-match? #rx"deprecated|Deprecated|DeprecationWarning|Obsolete" out)
              (format "~a: deprecated method must be stamped" (car e)))
  (define plain (cdr ((cdr e) plain-model)))
  (check-false (regexp-match? #rx"#\\[deprecated|@deprecated|// Deprecated:|DeprecationWarning|@Deprecated|\\[Obsolete" plain)
               (format "~a: non-deprecated method must not be stamped" (car e))))

(printf "deprecation tests passed\n")
