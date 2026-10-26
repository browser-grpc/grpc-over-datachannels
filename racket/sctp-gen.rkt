#lang racket

;;; sctp-gen.rkt — stamps sctp-spec.rkt scenarios as JSON for the
;;; Go/JS/Rust SCTP test suites (fixtures/sctp_vectors.json).

(require "sctp-spec.rkt" json)
(provide emit-sctp-vectors-json)

(define (scenario-json s)
  (match-define (list name stream messages deliver expect) s)
  (hasheq 'name (symbol->string name)
          'stream stream
          'messages (for/list ([m (in-list messages)])
                      (hasheq 'fill (symbol->string (first m))
                              'size (second m)))
          'deliver deliver
          'expect expect))

(define (emit-sctp-vectors-json)
  (jsexpr->string
   (hasheq 'scenarios (map scenario-json sctp-scenarios))))
