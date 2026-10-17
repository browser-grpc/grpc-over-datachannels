#lang racket

;;; bdd-spec.rkt — behavior scenarios as data: the executable
;;; examples. One table drives three things, so examples,
;;; documentation and tests can never drift apart:
;;;   * BDD.md (generated documentation, Given/When/Then prose),
;;;   * a per-language bdd_scenarios data file (stamped by
;;;     bdd-gen.rkt), interpreted by a small hand-written TestBdd in
;;;     each language against a loopback client+server,
;;;   * the echo semantics every language must agree on.
;;;
;;; Scenario shape: (name title action expectation)
;;;   action:      (unary msg) (unary-metadata msg marker)
;;;                (server-stream msg count) (client-stream msg ...)
;;;                (bidi msg ...) (raw-unary path msg)
;;;   expectation: (responds msg index) (fails code)
;;;                (streams msg count) (echoes msg ...)

(provide bdd-scenarios bdd-fields bdd-scenario-count)

(define bdd-scenarios
  (list
   (list 'unary-echo
         "A unary call echoes the message"
         '(unary "hello")
         '(responds "echo: hello" 0))
   (list 'unary-empty
         "A unary call accepts an empty message"
         '(unary "")
         '(responds "echo: " 0))
   (list 'unary-failure
         "The service rejects the message \"fail\""
         '(unary "fail")
         '(fails 3))
   (list 'server-stream-count
         "Server streaming produces the requested number of responses"
         '(server-stream "tick" 3)
         '(streams "tick" 3))
   (list 'server-stream-zero
         "Server streaming with count zero produces no responses"
         '(server-stream "zero" 0)
         '(streams "zero" 0))
   (list 'client-stream-join
         "Client streaming joins all messages into one response"
         '(client-stream "a" "b" "c")
         '(responds "a+b+c" 3))
   (list 'client-stream-solo
         "Client streaming accepts a single message"
         '(client-stream "solo")
         '(responds "solo" 1))
   (list 'client-stream-empty
         "Client streaming with no messages produces an empty response"
         '(client-stream)
         '(responds "" 0))
   (list 'bidi-order
         "Bidi streaming echoes each message in order"
         '(bidi "x" "y")
         '(echoes "x" "y"))
   (list 'bidi-single
         "Bidi streaming accepts a single message"
         '(bidi "one")
         '(echoes "one"))
   (list 'metadata-marker
         "Call metadata reaches the service implementation"
         '(unary-metadata "hello" "meta")
         '(responds "echo: hello [meta]" 0))
   (list 'unknown-method
         "Unknown methods are rejected as UNIMPLEMENTED"
         '(raw-unary "/echo.Echo/Nope" "hello")
         '(fails 12))))

(define bdd-scenario-count (length bdd-scenarios))

;; Flatten one scenario to the row every language's data file carries:
;; (name kind messages count path metadata expect-message expect-num
;;  expect-status); expect-status is #f when the call succeeds.
(define (bdd-fields s)
  (define action (third s))
  (define expectation (fourth s))
  (define-values (kind messages count path metadata)
    (case (first action)
      [(unary) (values "unary" (list (second action)) 0 "" "")]
      [(unary-metadata) (values "unary" (list (second action)) 0 "" (third action))]
      [(server-stream) (values "server-stream" (list (second action)) (third action) "" "")]
      [(client-stream) (values "client-stream" (rest action) 0 "" "")]
      [(bidi) (values "bidi" (rest action) 0 "" "")]
      [(raw-unary) (values "raw-unary" (list (third action)) 0 (second action) "")]))
  (define-values (expect-message expect-num expect-status)
    (case (first expectation)
      [(responds) (values (second expectation) (third expectation) #f)]
      [(fails) (values "" 0 (second expectation))]
      [(streams) (values (second expectation) (third expectation) #f)]
      [(echoes) (values "" (length (rest expectation)) #f)]))
  (list (symbol->string (first s)) kind messages count path metadata
        expect-message expect-num expect-status))
