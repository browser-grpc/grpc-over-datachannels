#lang racket

;;; Black-box tests for releasegen rules, run against a real
;;; export into temp dirs (the script is a top-level program,
;;; so its rules are proven on outputs, not internals):
;;;  - version stamping reaches package.json and the
;;;    kafka-native Cargo.toml *and* Cargo.lock (crate and its
;;;    grpc-dc path dependency — the v0.42.0 crates.io failure
;;;    was a stale lock entry),
;;;  - the allow-list keeps Racket sources and target/ dirs
;;;    out of every export,
;;;  - CONTRIBUTING.md / SECURITY.md land in every export root.

(require rackunit racket/runtime-path racket/file racket/system)

(define-runtime-path repo-root "../../")
(define test-version "v9.9.9-test")
(define bare-version "9.9.9-test")

(define out-root (make-temporary-directory "releasegen-test-~a"))
(define (out name) (build-path out-root name))

(define releasegen (build-path repo-root "racket" "releasegen.rkt"))
(define cmd
  (format "racket ~a --version ~a --out ~a --kafka-proxy-out ~a --kafka-native-out ~a --php-out ~a --kafka-php-out ~a --eventbus-php-out ~a --eventbus-out ~a --examples-out ~a"
          (path->string releasegen) test-version
          (path->string (out "main")) (path->string (out "kafka-proxy"))
          (path->string (out "kafka-native")) (path->string (out "grpc-php"))
          (path->string (out "kafka-php")) (path->string (out "eventbus-php"))
          (path->string (out "eventbus")) (path->string (out "examples"))))

(define ok
  (parameterize ([current-directory repo-root])
    (system cmd)))
(check-true ok "releasegen export run failed")

(define (slurp path) (file->string (build-path out-root path)))

;; Version stamping.
(check-true (string-contains? (slurp "main/js/package.json")
                              (format "\"version\": \"~a\"" bare-version))
            "main export package.json not stamped")
(define kn-cargo (slurp "kafka-native/crates/kafka-native/Cargo.toml"))
(check-true (string-contains? kn-cargo (format "version = \"~a\"" bare-version))
            "kafka-native Cargo.toml not stamped")
(define kn-lock (slurp "kafka-native/crates/kafka-native/Cargo.lock"))
(check-true (string-contains? kn-lock
                              (format "name = \"kafka-native\"\nversion = \"~a\"" bare-version))
            "kafka-native Cargo.lock crate entry not stamped (cargo publish would dirty the tree)")
(check-true (string-contains? kn-lock
                              (format "name = \"grpc-dc\"\nversion = \"~a\"" bare-version))
            "kafka-native Cargo.lock grpc-dc entry not stamped (cargo publish would dirty the tree)")
(check-false (string-contains? kn-lock "version = \"0.1.0\"")
             "stale 0.1.0 left in kafka-native Cargo.lock")

;; Allow-list: no Racket sources, no target/ dirs, community
;; files present in every export root.
(for ([name (in-list '("main" "kafka-proxy" "kafka-native" "grpc-php"
                       "kafka-php" "eventbus-php" "eventbus" "examples"))])
  (define files
    (for/list ([f (in-list (find-files file-exists? (out name)))])
      (path->string (find-relative-path (out name) f))))
  (check-false (for/or ([f (in-list files)]) (string-suffix? f ".rkt"))
               (format "~a export contains Racket sources" name))
  (check-false (for/or ([f (in-list files)])
                 (regexp-match? #rx"(^|/)target/" f))
               (format "~a export contains target/ artifacts" name))
  (check-not-false (member "CONTRIBUTING.md" files)
                   (format "~a export missing CONTRIBUTING.md" name))
  (check-not-false (member "SECURITY.md" files)
                   (format "~a export missing SECURITY.md" name)))

(delete-directory/files out-root)
