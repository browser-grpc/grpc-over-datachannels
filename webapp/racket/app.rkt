#lang racket/base
;; Webapp runtime app: a core-only Racket/Wasm build whose sole
;; job is to host the grpc-dc runner (racket/runner.rkt, seeded by
;; webapp/app.js as /tmp/main.rkt) executing the real protoc
;; plugins in-browser. scripts/build-racket-wasm.sh builds this
;; and copies racket-web.{js,wasm,data}, share.data{,.js} and
;; shell-worker.js into webapp/assets/racket/. The public/ dir is
;; a placeholder host page; the real UI is webapp/index.html.
(provide app)

(define app
  (hash
   'pkgs      '()
   'wasm-libs '()
   'public    "public"
   'target    'browser))
