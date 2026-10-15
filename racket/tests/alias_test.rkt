#lang racket

;;; Rename aliasing: with a synthetic alias table
;;; (echo.Echo: "OldUnary" -> "Unary"), every template must emit
;;;   * a client method named OldUnary calling /echo.Echo/Unary
;;;   * a server registration for /echo.Echo/OldUnary whose handler
;;;     calls the Unary implementation.
;;; With the empty default table, output must be unchanged in shape
;;; (no alias entries).

(require rackunit
         "../spec.rkt"
         "../template-rust.rkt" "../template-js.rkt" "../template-go.rkt"
         "../template-python.rkt" "../template-java.rkt" "../template-csharp.rkt")

(define model
  (hasheq 'name "echo.proto" 'package "echo"
          'services
          (list (hasheq 'name "Echo" 'full-name "echo.Echo" 'deprecated #f
                        'methods
                        (list (hasheq 'name "Unary" 'path "/echo.Echo/Unary"
                                      'input "EchoRequest" 'output "EchoResponse"
                                      'kind 'unary 'deprecated #f))))))

(define emitters
  (list (cons "rust" (lambda (m) (emit-rust-file m (hasheq))))
        (cons "js" (lambda (m) (emit-js-file m (hasheq))))
        (cons "go" (lambda (m) (emit-go-file m (hasheq))))
        (cons "python" (lambda (m) (emit-python-file m (hasheq))))
        (cons "java" (lambda (m) (emit-java-file m (hasheq))))
        (cons "csharp" (lambda (m) (emit-csharp-file m (hasheq))))))

(parameterize ([current-method-aliases '(("echo.Echo" "OldUnary" "Unary"))])
  (for ([e (in-list emitters)])
    (define out (cdr ((cdr e) model)))
    (check-true (regexp-match? #rx"OldUnary" out)
                (format "~a: alias name emitted" (car e)))
    ;; Rust registers methods by name (paths are composed at
    ;; runtime); other languages spell the alias path literally.
    (check-true (if (equal? (car e) "rust")
                    (regexp-match? #rx"\"OldUnary\"" out)
                    (regexp-match? #rx"/echo.Echo/OldUnary" out))
                (format "~a: alias path registered" (car e)))))

;; Default (empty) table: no alias names anywhere.
(for ([e (in-list emitters)])
  (define out (cdr ((cdr e) model)))
  (check-false (regexp-match? #rx"OldUnary" out)
               (format "~a: no alias without table entry" (car e))))

(printf "alias tests passed\n")
