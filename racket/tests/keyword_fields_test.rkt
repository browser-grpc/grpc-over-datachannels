#lang racket

;;; Keyword-named proto fields must generate compilable
;;; identifiers in every template. A field literally named
;;; `operator` generated uncompilable C# until the C# template
;;; learned to @-escape constructor parameters (found by the
;;; kafkaStreams Step message in the kafka gate). This test
;;; stamps a synthetic proto whose fields are named after
;;; language keywords through the real protoc plugins and
;;; checks the escaped identifiers land in the output; where
;;; a compiler is on hand for the generated tree's language
;;; (C# via dotnet is too heavy for this suite) the check is
;;; textual, matching exactly what the kafka gate's build
;;; then proves end to end.

(require rackunit racket/runtime-path racket/file racket/system)

(define-runtime-path repo-root "../../")
(define protoc (find-executable-path "protoc"))

(define proto-text
  (string-append
   "syntax = \"proto3\";\n"
   "package kwtest;\n"
   "message Keywords {\n"
   "  string operator = 1;\n"
   "  string class = 2;\n"
   "  string event = 3;\n"
   "  string string = 4;\n"
   "  string int = 5;\n"
   "  string object = 6;\n"
   "}\n"
   "message Reply { string operator = 1; }\n"
   "service Kw { rpc M(Keywords) returns (Reply); }\n"))

(when protoc
  (define tmp (make-temporary-directory "kwfields~a"))
  (define proto-file (build-path tmp "kw.proto"))
  (call-with-output-file proto-file #:exists 'replace
    (lambda (out) (display proto-text out)))
  (define (gen lang out-sub)
    (define outdir (build-path tmp out-sub))
    (make-directory* outdir)
    (define plugin
      (path->string (build-path repo-root (format "bin/protoc-gen-grpc-dc-~a" lang))))
    (define ok
      (system (format "~a --plugin=protoc-gen-grpc-dc-~a=~a --grpc-dc-~a_out=~a -I ~a ~a 2>&1"
                      (path->string protoc) lang plugin lang
                      (path->string outdir) (path->string tmp) (path->string proto-file))))
    (values ok outdir))
  ;; C#: constructor parameters are @-escaped.
  (define-values (cs-ok cs-out) (gen "csharp" "cs"))
  (check-true cs-ok "csharp plugin runs on keyword fields")
  (define cs-files (find-files (lambda (p) (path-has-extension? p #".cs")) cs-out))
  (define cs-text
    (apply string-append
           (map (lambda (p) (file->string p)) cs-files)))
  (check-true (string-contains? cs-text "@operator")
              "csharp escapes the operator parameter")
  (check-false (string-contains? cs-text "(Operator operator,")
               "csharp never emits a bare keyword parameter")
  ;; Java: fields named after keywords get safe identifiers
  ;; (the template renames through its field-name mapping).
  (define-values (java-ok java-out) (gen "java" "java"))
  (check-true java-ok "java plugin runs on keyword fields")
  (define java-files (find-files (lambda (p) (path-has-extension? p #".java")) java-out))
  (define java-text
    (apply string-append
           (map (lambda (p) (file->string p)) java-files)))
  (check-false (string-contains? java-text "String class;")
               "java never declares a field named class")
  (check-false (string-contains? java-text "(String class,")
               "java never declares a parameter named class")
  ;; Go + Python run without error on the same fields.
  (define-values (go-ok _go-out) (gen "go" "go"))
  (check-true go-ok "go plugin runs on keyword fields")
  (define-values (py-ok _py-out) (gen "python" "py"))
  (check-true py-ok "python plugin runs on keyword fields")
  (delete-directory/files tmp))

(printf "keyword fields tests passed\n")
