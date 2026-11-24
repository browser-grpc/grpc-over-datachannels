#lang racket

;;; kafka-streams-spec.rkt — streams e2e scenarios as data.
;;; One table drives the JS and Python streams suites, so
;;; the word-count / aggregation / window scenarios every
;;; client language runs can never drift apart. Each
;;; language keeps one small hand-written interpreter
;;; (js/test/kafka_streams.test.js generated-scenario leg,
;;; python/tests/test_kafka_streams.py) against a running
;;; kafka_proxy; cases are data, never unrolled code.
;;;
;;; Scenario: (name title steps operators produce expect)
;;;   operators: chain as (op param aggregator) triples,
;;;              op symbols mirror proto Operator names.
;;;   produce:   (lines (partition text ...)) — one record
;;;              per text, empty key, on the source topic.
;;;   expect:    (store ((key . value) ...)) and/or
;;;              (sink ((key . value) ...)) final maps.

(provide kafka-streams-scenarios)

(define kafka-streams-scenarios
  (list
   (list 'word-count
         "TOKENIZE_WORDS -> GROUP_BY_KEY -> COUNT counts words"
         '((tokenize-words "" 0) (group-by-key "" 0) (count "" 0))
         '(("hello world hello" "world of streams" "hello streams"))
         '((store (("hello" . 3) ("world" . 2) ("streams" . 2) ("of" . 1)))
           (sink (("hello" . "3") ("world" . "2") ("streams" . "2") ("of" . "1")))))
   (list 'sum-filter
         "FILTER + SELECT_KEY + AGGREGATE SUM sums kept values per key"
         '((filter "value_gt:2" 0) (select-key "value" 0) (group-by-key "" 0) (aggregate "" 2))
         '(("1" "5" "5" "9" "2"))
         '((store (("5" . 10) ("9" . 9)))
           (sink (("5" . "10") ("9" . "9")))))))
