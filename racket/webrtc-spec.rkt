#lang racket

;;; webrtc-spec.rkt — single source of truth for the reimplemented
;;; WebRTC stack (SPEC-WEBRTC.md), plus crypto constant tables that are
;;; COMPUTED here by the metaprogram (never transcribed):
;;;   * SHA-256 H/K: fractional parts of sqrt/cuberoot of the first
;;;     primes, via exact integer Newton roots — asserted against the
;;;     published first/last values before anything is emitted.
;;;   * AES S-box: GF(2^8) multiplicative inverse + affine transform.
;;;   * CRC-32 table: reflected polynomial 0xEDB88320 expanded per byte.
;;; webrtc-gen.rkt stamps all of it into Rust and JS.

(provide (all-defined-out))

;; ---------------------------------------------------------------------------
;; Protocol tables (name . code)
;; ---------------------------------------------------------------------------

(define stun-message-types
  '((BindingRequest . #x0001) (BindingSuccess . #x0101) (BindingError . #x0111)
    (AllocateRequest . #x0003) (AllocateSuccess . #x0103) (AllocateError . #x0113)
    (RefreshRequest . #x0004) (RefreshSuccess . #x0104) (RefreshError . #x0114)
    (CreatePermissionRequest . #x0008) (CreatePermissionSuccess . #x0108)
    (CreatePermissionError . #x0118) (SendIndication . #x0016) (DataIndication . #x0017)
    (ChannelBindRequest . #x0009) (ChannelBindSuccess . #x0109)
    (ChannelBindError . #x0119)))

(define stun-attributes
  '((MappedAddress . #x0001) (Username . #x0006) (MessageIntegrity . #x0008)
    (ErrorCode . #x0009) (UnknownAttributes . #x000A) (ChannelNumber . #x000C)
    (Lifetime . #x000D)
    (XorPeerAddress . #x0012) (Data . #x0013) (Realm . #x0014)
    (Nonce . #x0015) (XorRelayedAddress . #x0016) (RequestedAddressFamily . #x0017) (RequestedTransport . #x0019)
    (XorMappedAddress . #x0020) (Priority . #x0024)
    (UseCandidate . #x0025) (Software . #x8022) (Fingerprint . #x8028)
    (IceControlled . #x8029) (IceControlling . #x802A)))

(define sctp-chunk-types
  '((Data . 0) (Init . 1) (InitAck . 2) (Sack . 3) (Heartbeat . 4)
    (HeartbeatAck . 5) (Abort . 6) (Shutdown . 7) (ShutdownAck . 8)
    (Error . 9) (CookieEcho . 10) (CookieAck . 11) (ShutdownComplete . 14)
    ;; ReConfig is 130 (RFC 6525); ForwardTsn is 192 (RFC 3758).
    ;; (Verified against Chrome's INIT Supported Extensions: 82 c0.)
    (ReConfig . 130) (ForwardTsn . 192)))

(define sctp-param-types
  '((HeartbeatInfo . 1) (Ipv4Address . 5) (Ipv6Address . 6) (StateCookie . 7)
    (UnrecognizedParameter . 8) (CookiePreservative . 9) (HostnameAddress . 11)
    (SupportedAddressTypes . 12) (EcnCapable . 32768)
    (SupportedExtensions . 32776) (ForwardTsnSupported . 49152)))

;; RFC 6525 re-configuration parameter types.
(define sctp-reconfig-params
  '((OutgoingSsnResetRequest . 13) (IncomingSsnResetRequest . 14)
    (SsnTsnResetRequest . 15) (ReconfigurationResponse . 16)
    (AddOutgoingStreamsRequest . 17) (AddIncomingStreamsRequest . 18)))

(define sctp-error-causes
  '((InvalidMandatoryParameter . 4) (UnrecognizedChunkType . 6)
    (InvalidStreamIdentifier . 1) (MissingMandatoryParameter . 2)
    (StaleCookie . 3) (OutOfResource . 5) (UnresolvableAddress . 7)
    (UnrecognizedParameter . 8) (NoUserData . 9) (CookieWhileShuttingDown . 10)
    (ProtocolViolation . 13)))

(define dtls-content-types
  '((ChangeCipherSpec . 20) (Alert . 21) (Handshake . 22) (ApplicationData . 23)))

(define dtls-handshake-types
  '((HelloRequest . 0) (ClientHello . 1) (ServerHello . 2) (HelloVerifyRequest . 3)
    (NewSessionTicket . 4)
    (Certificate . 11) (ServerKeyExchange . 12) (CertificateRequest . 13)
    (ServerHelloDone . 14) (CertificateVerify . 15) (ClientKeyExchange . 16)
    (Finished . 20)))

(define dtls-extension-types
  '((SupportedGroups . 10) (EcPointFormats . 11) (SignatureAlgorithms . 13)
    (UseSrtp . 14) (ExtendedMasterSecret . 23) (SessionTicket . 35)
    (RenegotiationInfo . 65281)))

(define dtls-named-groups '((Secp256r1 . 23) (X25519 . 29) (Secp384r1 . 24)))

(define srtp-profiles
  '((SrtpAes128CmHmacSha1_80 . #x0001) (SrtpAes128CmHmacSha1_32 . #x0002)
    (SrtpAeadAes128Gcm . #x0007) (SrtpAeadAes256Gcm . #x0008)))

(define cipher-suite-ecdhe-ecdsa-aes128-gcm-sha256 #xC02B)

;; ---------------------------------------------------------------------------
;; Computed tables (exact integer arithmetic; asserted before use)
;; ---------------------------------------------------------------------------

(define (first-primes n)
  (let loop ([candidate 2] [found '()])
    (cond [(= (length found) n) (reverse found)]
          [(andmap (lambda (p) (not (zero? (remainder candidate p))))
                   (filter (lambda (p) (<= (* p p) candidate)) found))
           (loop (add1 candidate) (cons candidate found))]
          [else (loop (add1 candidate) found)])))

;; floor of the integer k-th root via Newton iteration on exact integers.
(define (integer-root n k)
  (define (improve x) (quotient (+ (* (sub1 k) x) (quotient n (expt x (sub1 k)))) k))
  (let loop ([x (max 1 (arithmetic-shift 1 (quotient (+ (integer-length n) k) k)))])
    (define y (improve x))
    (if (>= y x) (let settle ([x x]) (if (<= (expt (add1 x) k) n) (settle (add1 x)) x)) (loop y))))

(define sha256-h
  (for/list ([p (in-list (first-primes 8))])
    (modulo (integer-root (arithmetic-shift p 64) 2) (expt 2 32))))

(define sha256-k
  (for/list ([p (in-list (first-primes 64))])
    (modulo (integer-root (arithmetic-shift p 96) 3) (expt 2 32))))

;; SHA-512 (FIPS 180-4): H from the square roots of the first 8
;; primes at 64-bit precision, K from the cube roots of the first
;; 80. SHA-384 is SHA-512 with the IV taken from the square roots
;; of the 9th-16th primes and output truncated to 384 bits.
(define sha512-h
  (for/list ([p (in-list (first-primes 8))])
    (modulo (integer-root (arithmetic-shift p 128) 2) (expt 2 64))))

(define sha384-h
  (for/list ([p (in-list (list-tail (first-primes 16) 8))])
    (modulo (integer-root (arithmetic-shift p 128) 2) (expt 2 64))))

(define sha512-k
  (for/list ([p (in-list (first-primes 80))])
    (modulo (integer-root (arithmetic-shift p 192) 3) (expt 2 64))))

(define (gf-mul a b)
  (let loop ([a a] [b b] [acc 0])
    (cond [(zero? b) acc]
          [(odd? b) (loop (gf-xtime a) (arithmetic-shift b -1) (bitwise-xor acc a))]
          [else (loop (gf-xtime a) (arithmetic-shift b -1) acc)])))

(define (gf-xtime a)
  (define shifted (arithmetic-shift a 1))
  (if (bitwise-bit-set? a 7)
      (bitwise-xor (bitwise-and shifted #xFF) #x1B)
      (bitwise-and shifted #xFF)))

(define (gf-inv a)
  (cond [(zero? a) 0]
        [else (let loop ([base a] [exp 254] [acc 1])
                (cond [(zero? exp) acc]
                      [(odd? exp) (loop (gf-mul base base) (arithmetic-shift exp -1) (gf-mul acc base))]
                      [else (loop (gf-mul base base) (arithmetic-shift exp -1) acc)]))]))

(define (rotl8 x n)
  (bitwise-and (bitwise-ior (arithmetic-shift x n) (arithmetic-shift x (- n 8))) #xFF))

(define aes-sbox
  (for/list ([i (in-range 256)])
    (define inv (gf-inv i))
    (bitwise-xor inv (rotl8 inv 1) (rotl8 inv 2) (rotl8 inv 3) (rotl8 inv 4) #x63)))

(define aes-inv-sbox
  (let ([v (make-vector 256 0)])
    (for ([(s i) (in-indexed aes-sbox)]) (vector-set! v s i))
    (vector->list v)))

(define (crc-table poly)
  (for/list ([i (in-range 256)])
    (let loop ([c i] [k 0])
      (cond [(= k 8) c]
            [(odd? c) (loop (bitwise-xor (arithmetic-shift c -1) poly) (add1 k))]
            [else (loop (arithmetic-shift c -1) (add1 k))]))))

;; MD5 (RFC 1321 section 3.4) for TURN long-term credentials:
;; K[i] = floor(2^32 * |sin(i+1)|), computed in flonums and
;; asserted below against published values before anything is
;; emitted; S is the four base rotate schedules, each repeated
;; four times per round.
(define md5-k
  (for/list ([i (in-range 1 65)])
    (inexact->exact (floor (* 4294967296 (abs (sin i)))))))

(define md5-s
  (apply append
         (for/list ([base (in-list '((7 12 17 22) (5 9 14 20) (4 11 16 23) (6 10 15 21)))])
           (apply append (make-list 4 base)))))

(define crc32-table (crc-table #xEDB88320))
;; SCTP checksum is CRC-32C (Castagnoli), a different polynomial.
(define crc32c-table (crc-table #x82F63B78))

;; Generation must never emit an unverified constant.
(unless (and (= (first sha256-k) #x428a2f98) (= (last sha256-k) #xc67178f2)
             (= (first sha256-h) #x6a09e667) (= (last sha256-h) #x5be0cd19)
             (= (first sha512-h) #x6a09e667f3bcc908) (= (last sha512-h) #x5be0cd19137e2179)
             (= (first sha384-h) #xcbbb9d5dc1059ed8) (= (last sha384-h) #x47b5481dbefa4fa4)
             (= (first sha512-k) #x428a2f98d728ae22) (= (last sha512-k) #x6c44198c4a475817)
             (= (list-ref aes-sbox 0) #x63) (= (list-ref aes-sbox 1) #x7c)
             (= (list-ref aes-sbox #x53) #xed)
             (= (list-ref crc32-table 1) #x77073096)
             (= (list-ref crc32-table 255) #x2d02ef8d)
             (= (list-ref crc32c-table 1) #xF26B8303)
             (= (first md5-k) #xD76AA478) (= (list-ref md5-k 32) #xFFFA3942)
             (= (last md5-k) #xEB86D391)
             (= (length md5-s) 64) (= (first md5-s) 7) (= (last md5-s) 21))
  (error 'webrtc-spec "computed crypto table failed its published-value assertion"))
