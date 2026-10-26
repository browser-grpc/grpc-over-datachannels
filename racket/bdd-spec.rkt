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
;;;                (server-stream-fail msg count) (bidi-fail msg ...)
;;;                (deadline msg delay-ms) (cancel msg count)
;;;   expectation: (responds msg index) (fails code)
;;;                (streams msg count) (echoes msg ...) (cancels)
;;;
;;; The *-fail actions rely on the reference Echo contract that
;;; "fail" is rejected with INVALID_ARGUMENT in every method
;;; (unary, server-stream, and bidi alike). The deadline action
;;; sends a unary the service delays by delay-ms; the runner
;;; applies a client deadline far shorter than the delay and
;;; expects DEADLINE_EXCEEDED. The cancel action opens a
;;; server-stream, reads one response, cancels, and expects the
;;; stream to terminate (status or end) rather than hang.

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
   (list 'trailer-marker
         "Response trailing metadata reaches the client"
         '(unary-trailer "hello" "meta")
         '(responds "echo: hello" 0))
   (list 'unknown-method
         "Unknown methods are rejected as UNIMPLEMENTED"
         '(raw-unary "/echo.Echo/Nope" "hello")
         '(fails 12))
   (list 'server-stream-failure
         "Server streaming rejects the message \"fail\""
         '(server-stream-fail "fail" 3)
         '(fails 3))
   (list 'bidi-failure
         "Bidi streaming rejects the message \"fail\""
         '(bidi-fail "fail")
         '(fails 3))
   (list 'deadline-exceeded
         "A unary delayed past the client deadline fails"
         '(deadline "slow" 600)
         '(fails 4))
   (list 'stream-cancel
         "Cancelling a server stream terminates it"
         '(cancel "tick" 5)
         '(cancels))
   (list 'stream-break
         "Breaking a server stream stops the server"
         '(breaks "tick" 100)
         '(stops))))

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
      [(unary-trailer) (values "unary-trailer" (list (second action)) 0 "" (third action))]
      [(server-stream) (values "server-stream" (list (second action)) (third action) "" "")]
      [(client-stream) (values "client-stream" (rest action) 0 "" "")]
      [(bidi) (values "bidi" (rest action) 0 "" "")]
      [(raw-unary) (values "raw-unary" (list (third action)) 0 (second action) "")]
      [(server-stream-fail) (values "server-stream-fail" (list (second action)) (third action) "" "")]
      [(bidi-fail) (values "bidi-fail" (rest action) 0 "" "")]
      [(deadline) (values "deadline" (list (second action)) (third action) "" "")]
      [(cancel) (values "cancel" (list (second action)) (third action) "" "")]
      [(breaks) (values "stream-break" (list (second action)) (third action) "" "")]))
  (define-values (expect-message expect-num expect-status)
    (case (first expectation)
      [(responds) (values (second expectation) (third expectation) #f)]
      [(fails) (values "" 0 (second expectation))]
      [(streams) (values (second expectation) (third expectation) #f)]
      [(echoes) (values "" (length (rest expectation)) #f)]
      [(cancels) (values "" 0 #f)]
      [(stops) (values "" 0 #f)]))
  (list (symbol->string (first s)) kind messages count path metadata
        expect-message expect-num expect-status))
