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

(define (sack-step-json s)
  (match s
    [(list 'recv tsn gaps)
     (hasheq 'recv tsn
             'gaps (for/list ([g (in-list gaps)])
                     (list (first g) (second g))))]
    [(list 'sack cum blocks unacked acked retransmit)
     (hasheq 'sack (hasheq 'cum cum
                           'blocks (for/list ([b (in-list blocks)])
                                     (list (first b) (second b)))
                           'unacked unacked)
             'acked acked
             'retransmit retransmit)]))

(define (sack-scenario-json s)
  (match-define (list name initial-cum steps) s)
  (hasheq 'name (symbol->string name)
          'initial_cum initial-cum
          'steps (map sack-step-json steps)))

(define (emit-sctp-vectors-json)
  (jsexpr->string
   (hasheq 'scenarios (map scenario-json sctp-scenarios)
           'sack_scenarios (map sack-scenario-json sctp-sack-scenarios))))
