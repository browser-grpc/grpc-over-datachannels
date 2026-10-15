#lang racket

;;; pb.rkt — minimal protobuf wire codec + grpc-dc frame codec.
;;;
;;; Just enough of the protobuf binary format to read a
;;; CodeGeneratorRequest (descriptor.proto) and write a
;;; CodeGeneratorResponse, plus the 9-byte frame header from SPEC.md.
;;; metagen.rkt splices this file's body into both generated protoc
;;; plugins, so every definition carries a pb-/frame prefix and nothing
;;; here may shadow a plugin-template name.

(require "spec.rkt")
(provide (all-defined-out))

;; ---------------------------------------------------------------------------
;; varints
;; ---------------------------------------------------------------------------

(define (pb-varint-bytes n)
  (unless (and (exact-integer? n) (>= n 0))
    (raise-argument-error 'pb-varint-bytes "exact-nonnegative-integer?" n))
  (let loop ([n n] [acc '()])
    (if (< n 128)
        (list->bytes (reverse (cons n acc)))
        (loop (arithmetic-shift n -7) (cons (bitwise-ior (bitwise-and n 127) 128) acc)))))

;; -> (values value next-index)
(define (pb-read-varint bstr i)
  (let loop ([i i] [shift 0] [acc 0] [count 0])
    (when (>= count 10) (error 'pb-parse "varint too long at byte ~a" i))
    (when (>= i (bytes-length bstr)) (error 'pb-parse "truncated varint at byte ~a" i))
    (define b (bytes-ref bstr i))
    (define acc2 (bitwise-ior acc (arithmetic-shift (bitwise-and b 127) shift)))
    (if (bitwise-bit-set? b 7)
        (loop (add1 i) (+ shift 7) acc2 (add1 count))
        (values acc2 (add1 i)))))

;; ---------------------------------------------------------------------------
;; message parsing: a parsed field is (list field-num wire-type value)
;; wire-type 0 -> value is an integer; 2/1/5 -> value is a byte string
;; ---------------------------------------------------------------------------

(define (pb-parse bstr)
  (let loop ([i 0] [acc '()])
    (if (>= i (bytes-length bstr))
        (reverse acc)
        (let-values ([(tag j) (pb-read-varint bstr i)])
          (define num (arithmetic-shift tag -3))
          (define wire (bitwise-and tag 7))
          (when (zero? num) (error 'pb-parse "field number 0 at byte ~a" i))
          (case wire
            [(0) (let-values ([(v k) (pb-read-varint bstr j)])
                   (loop k (cons (list num wire v) acc)))]
            [(2) (let-values ([(len k) (pb-read-varint bstr j)])
                   (when (> (+ k len) (bytes-length bstr))
                     (error 'pb-parse "truncated length-delimited field ~a" num))
                   (loop (+ k len) (cons (list num wire (subbytes bstr k (+ k len))) acc)))]
            [(1) (loop (+ j 8) (cons (list num wire (subbytes bstr j (+ j 8))) acc))]
            [(5) (loop (+ j 4) (cons (list num wire (subbytes bstr j (+ j 4))) acc))]
            [else (error 'pb-parse "unsupported wire type ~a for field ~a" wire num)])))))

(define (pb-get fields num [default #f])
  (define hit (findf (lambda (f) (= (first f) num)) fields))
  (if hit (third hit) default))

(define (pb-get-all fields num)
  (for/list ([f (in-list fields)] #:when (= (first f) num)) (third f)))

(define (pb-get-string fields num [default #f])
  (define v (pb-get fields num default))
  (if (bytes? v) (bytes->string/utf-8 v) v))

(define (pb-get-bool fields num)
  (define v (pb-get fields num 0))
  (and (integer? v) (not (zero? v))))

;; ---------------------------------------------------------------------------
;; message writing
;; ---------------------------------------------------------------------------

(define (pb-tag-bytes num wire)
  (pb-varint-bytes (bitwise-ior (arithmetic-shift num 3) wire)))

(define (pb-varint-field num n)
  (bytes-append (pb-tag-bytes num 0) (pb-varint-bytes n)))

(define (pb-bytes-field num bstr)
  (bytes-append (pb-tag-bytes num 2) (pb-varint-bytes (bytes-length bstr)) bstr))

(define (pb-string-field num s)
  (pb-bytes-field num (string->bytes/utf-8 s)))

;; ---------------------------------------------------------------------------
;; grpc-dc frames (SPEC.md): type:u8 | stream-id:u32be | len:u32be | payload
;; ---------------------------------------------------------------------------

(define frame-header-size 9)
(define max-data-payload (* 16 1024 1024))

(define (encode-frame type stream-id payload)
  (unless (valid-frame-type? type)
    (raise-argument-error 'encode-frame "valid frame type" type))
  (unless (and (exact-integer? stream-id) (<= 0 stream-id #xFFFFFFFF))
    (raise-argument-error 'encode-frame "uint32 stream id" stream-id))
  (when (and (= type frame:DATA) (> (bytes-length payload) max-data-payload))
    (error 'encode-frame "DATA payload exceeds 16 MiB"))
  (bytes-append (bytes type)
                (integer->integer-bytes stream-id 4 #f #t)
                (integer->integer-bytes (bytes-length payload) 4 #f #t)
                payload))

;; -> (values type stream-id payload)
(define (decode-frame bstr)
  (when (< (bytes-length bstr) frame-header-size)
    (error 'decode-frame "frame shorter than 9-byte header: ~a bytes" (bytes-length bstr)))
  (define type (bytes-ref bstr 0))
  (define stream-id (integer-bytes->integer bstr #f #t 1 5))
  (define len (integer-bytes->integer bstr #f #t 5 9))
  (unless (= len (- (bytes-length bstr) frame-header-size))
    (error 'decode-frame "payload length ~a does not match message size ~a"
           len (bytes-length bstr)))
  (values type stream-id (subbytes bstr frame-header-size)))

;; ---------------------------------------------------------------------------
;; small shared helpers
;; ---------------------------------------------------------------------------

(define (bytes->hex bstr)
  (apply string-append
         (for/list ([b (in-bytes bstr)])
           (~a (number->string b 16) #:width 2 #:align 'right #:pad-string "0"))))

(define (hex->bytes hex)
  (define clean (regexp-replace* #px"\\s+" hex ""))
  (unless (even? (string-length clean)) (error 'hex->bytes "odd hex length"))
  (list->bytes
   (for/list ([i (in-range 0 (string-length clean) 2)])
     (string->number (substring clean i (+ i 2)) 16))))
