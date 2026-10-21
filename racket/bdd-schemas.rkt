#lang racket

;;; bdd-schemas.rkt — protoc schema examples as BDD scenarios.
;;;
;;; Each scenario is golden bytes produced by protoc itself
;;; (--encode over webapp/testdata/{kitchen,features}.proto; the
;;; kitchen text is the same KITCHEN_TEXT the Python pb test
;;; uses), stamped as data into every language by bdd-gen.rkt.
;;; The interpreter in each language decodes the bytes with its
;;; generated message classes and re-encodes: the result must be
;;; byte-identical. That is a stronger schema assertion than a
;;; self-round-trip — it pins every generated marshal/unmarshal
;;; pair to protoc's own wire output for every scalar type,
;;; nested messages, maps, repeated packed fields, oneofs, and
;;; cross-file references.
;;;
;;; Scenario shape: (name title message input-hex expect-hex)
;;;   message:    "kitchen" | "outer" (the generated class)
;;;   input-hex:  bytes to decode
;;;   expect-hex: bytes re-encoding must produce (differs from
;;;               input for the oneof last-one-wins case, where
;;;               both variants are on the wire and only the
;;;               later survives, and is input + the unknown
;;;               field echoed back for unknown retention)

(provide bdd-schema-scenarios)

(define kitchen-full-hex
  (string-append
   "09000000000000f83f150000204018fdffffffffffffffff0120fcffffffffffffffff012805"
   "3006380d400f4d09000000510a000000000000005df5ffffff61f4ffffffffffffff68017204"
   "73696e6b7a030102038001028a01050a016e10039201070a0361626310029a010d01feffffff"
   "ffffffffff01ac02a2010161a20100a201026263aa01050a016d1001b20110000000000000e0"
   "3f000000000000f4bfba01050a01781001ba010e0a017910feffffffffffffffff01c2010908"
   "0712050a017a1009ca010663686f73656ed801ffffffffffffffefff01e001ff880f"))

(define outer-hex
  "0a0c0a080a04636f72651003100218052a070a03736b791002320807000000080000003801")

;; Kitchen wire bytes carrying only name="x" (field 14).
(define kitchen-name-hex "720178")

;; Unknown field 999, varint 1: appended to a message, a correct
;; runtime captures it as an unknown field and re-emits it.
(define unknown-field-hex "b83e01")

(define bdd-schema-scenarios
  (list
   (list 'kitchen-full
         "Kitchen sink (every scalar, nested, maps, packed, oneof) round-trips protoc's bytes"
         "kitchen" kitchen-full-hex kitchen-full-hex)
   (list 'kitchen-empty
         "An empty Kitchen message encodes to zero bytes"
         "kitchen" "" "")
   (list 'outer-nested
         "Three-level nesting with a nested enum and enum map round-trips protoc's bytes"
         "outer" outer-hex outer-hex)
   (list 'kitchen-oneof-last-wins
         "With both oneof variants on the wire, only the later (code) survives re-encoding"
         "kitchen"
         (string-append "ca010161" "d00107") ; text="a" then code=7
         "d00107")
   (list 'kitchen-unknown-field
         "An unknown field is captured on decode and re-emitted verbatim"
         "kitchen"
         (string-append kitchen-name-hex unknown-field-hex)
         (string-append kitchen-name-hex unknown-field-hex))))
