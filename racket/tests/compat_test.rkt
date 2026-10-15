#lang racket

;;; Tests for the descriptor compatibility gate (../compat.rkt):
;;; synthetic descriptor sets are built with ../pb.rkt writers and
;;; diffed. Additive changes pass; breaking changes are reported.

(require rackunit
         "../pb.rkt" "../compat.rkt")

(define (field name number type [label 1])
  (bytes-append (pb-string-field 1 name)
                (pb-varint-field 3 number)
                (pb-varint-field 4 label)
                (pb-varint-field 5 type)))

(define (message name fields [reserved-ranges '()] [reserved-names '()] [nested '()])
  (apply bytes-append
         (pb-string-field 1 name)
         (append (map (lambda (f) (pb-bytes-field 2 f)) fields)
                 (map (lambda (n) (pb-bytes-field 3 n)) nested)
                 (map (lambda (r)
                        (pb-bytes-field 9 (bytes-append (pb-varint-field 1 (car r))
                                                        (pb-varint-field 2 (cdr r)))))
                      reserved-ranges)
                 (map (lambda (n) (pb-string-field 10 n)) reserved-names))))

(define (method name input output [client #f] [server #f])
  (bytes-append (pb-string-field 1 name)
                (pb-string-field 2 input)
                (pb-string-field 3 output)
                (if client (pb-varint-field 5 1) #"")
                (if server (pb-varint-field 6 1) #"")))

(define (service name methods)
  (apply bytes-append
         (pb-string-field 1 name)
         (map (lambda (m) (pb-bytes-field 2 m)) methods)))

(define (descriptor-set messages services)
  (pb-bytes-field
   1
   (apply bytes-append
          (pb-string-field 2 "echo")
          (append (map (lambda (m) (pb-bytes-field 4 m)) messages)
                  (map (lambda (s) (pb-bytes-field 6 s)) services)))))

(define req-v1
  (message "EchoRequest"
           (list (field "message" 1 9) (field "count" 2 5) (field "delay_ms" 3 5))))
(define resp (message "EchoResponse" (list (field "message" 1 9) (field "index" 2 5))))
(define echo-svc
  (service "Echo" (list (method "Unary" ".echo.EchoRequest" ".echo.EchoResponse")
                        (method "ServerStream" ".echo.EchoRequest" ".echo.EchoResponse" #f #t))))
(define v1 (descriptor-set (list req-v1 resp) (list echo-svc)))

;; identical -> OK
(check-equal? (descriptor-diff v1 v1) '())

;; additive field + method -> OK
(define req-v2-add
  (message "EchoRequest"
           (list (field "message" 1 9) (field "count" 2 5) (field "delay_ms" 3 5)
                 (field "extra" 4 9))))
(define svc-add
  (service "Echo" (list (method "Unary" ".echo.EchoRequest" ".echo.EchoResponse")
                        (method "ServerStream" ".echo.EchoRequest" ".echo.EchoResponse" #f #t)
                        (method "Extra" ".echo.EchoRequest" ".echo.EchoResponse"))))
(check-equal? (descriptor-diff v1 (descriptor-set (list req-v2-add resp) (list svc-add))) '())

;; field removed without reserved -> BREAKING
(define req-v2-remove
  (message "EchoRequest" (list (field "message" 1 9) (field "count" 2 5))))
(check-equal? (length (descriptor-diff v1 (descriptor-set (list req-v2-remove resp) (list echo-svc)))) 1)

;; field removed with reserved -> OK
(define req-v2-reserved
  (message "EchoRequest" (list (field "message" 1 9) (field "count" 2 5))
           (list (cons 3 4)) (list "delay_ms")))
(check-equal? (descriptor-diff v1 (descriptor-set (list req-v2-reserved resp) (list echo-svc))) '())

;; field renumbered (same name, new number; old slot not reserved) -> BREAKING
(define req-v2-renumber
  (message "EchoRequest"
           (list (field "message" 1 9) (field "count" 7 5) (field "delay_ms" 3 5))))
(check-false (null? (descriptor-diff v1 (descriptor-set (list req-v2-renumber resp) (list echo-svc)))))

;; field type changed -> BREAKING
(define req-v2-retype
  (message "EchoRequest"
           (list (field "message" 1 9) (field "count" 2 9) (field "delay_ms" 3 5))))
(check-false (null? (descriptor-diff v1 (descriptor-set (list req-v2-retype resp) (list echo-svc)))))

;; method removed -> BREAKING
(define svc-removed
  (service "Echo" (list (method "Unary" ".echo.EchoRequest" ".echo.EchoResponse"))))
(check-false (null? (descriptor-diff v1 (descriptor-set (list req-v1 resp) (list svc-removed)))))

;; streaming shape changed -> BREAKING
(define svc-shape
  (service "Echo" (list (method "Unary" ".echo.EchoRequest" ".echo.EchoResponse")
                        (method "ServerStream" ".echo.EchoRequest" ".echo.EchoResponse"))))
(check-false (null? (descriptor-diff v1 (descriptor-set (list req-v1 resp) (list svc-shape)))))

(printf "compat tests passed\n")
