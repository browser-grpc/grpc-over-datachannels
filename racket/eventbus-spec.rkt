#lang racket

;;; eventbus-spec.rkt — the event bus policy, written ONCE.
;;;
;;; The wire contract is proto/events.proto (package
;;; grpcdc.events.v1, service EventBus); the protoc plugins
;;; stamp it into per-language stubs like any user proto. What
;;; the proto cannot express lives here as data and is stamped
;;; by eventbus-gen.rkt into each language's generated
;;; `eventbus` module (broker + client helpers + git log
;;; serde), so the semantics cannot drift between languages:
;;;
;;;   - fan-out is at-most-once; every subscriber has a bounded
;;;     queue (subscriber-queue-capacity) and drops its OLDEST
;;;     events on overflow, counting the drops;
;;;   - matching is containment: an event is delivered when its
;;;     tag list contains every (tag, value) pair of the
;;;     subscription filter; value equality includes the oneof
;;;     kind (numbers compare bit-exact, never via strings);
;;;   - sequence numbers are broker-global, 1-based, in publish
;;;     order; the broker stamps timestamp_unix_ms on accept;
;;;   - the git log is a serde layer beside the broker: one
;;;     commit per event on a branch, payload blob at
;;;     git-blob-path, identity/trailers per
;;;     git-commit-subject / git-trailer-* below; export is
;;;     idempotent (deterministic bytes for a given event log).

(provide eventbus-spec
         eventbus-languages)

(define eventbus-spec-table
  '((service-name . "grpcdc.events.v1.EventBus")
    (publish-path . "/grpcdc.events.v1.EventBus/Publish")
    (subscribe-path . "/grpcdc.events.v1.EventBus/Subscribe")
    (subscriber-queue-capacity . 128)
    ;; User-defined Tag numbers start here (proto/events.proto).
    (user-tag-base . 1000)
    ;; Git log serde.
    (git-blob-path . "event.pb")
    (git-author-name . "grpc-dc eventbus")
    (git-author-email . "eventbus@grpc-dc.local")
    (git-commit-subject . "grpc-dc event")
    ;; Trailer keys stamped on every log commit (git trailers,
    ;; so `git log` alone can filter the log). The blob stays
    ;; authoritative; trailers are the human index.
    (git-trailer-seq . "Seq")
    (git-trailer-publisher . "Publisher")
    (git-trailer-tag . "Tag")))

(define (eventbus-spec key)
  (cdr (assoc key eventbus-spec-table)))

;; Languages with a generated eventbus module, in generation
;; order: (id runtime-module-path gitlog-module-path-or-#f).
;; Browser delivery rides the JS module (the git log stays
;; native, behind a peer log keeper), so js has no gitlog here;
;; Node users import the JS gitlog module explicitly.
(define eventbus-languages
  '((js "js/src/eventbus.js" "js/src/eventbus_gitlog.js")
    (python "python/grpcdc/eventbus.py" "python/grpcdc/eventbus_git.py")
    (go "go/eventbus.go" "go/eventbus_git.go")
    (rust "rust/src/eventbus.rs" "rust/src/eventbus_git.rs")
    (ruby "ruby/grpcdc/eventbus.rb" "ruby/grpcdc/eventbus_git.rb")
    (php "php/grpcdc/eventbus.php" "php/grpcdc/eventbus_git.php")
    (dart "dart/grpcdc/eventbus.dart" "dart/grpcdc/eventbus_git.dart")
    (lua "lua/grpcdc/eventbus.lua" "lua/grpcdc/eventbus_git.lua")
    (java "java/grpcdc/events/v1/Eventbus.java" "java/grpcdc/events/v1/EventbusGit.java")
    (csharp "csharp/grpcdc/events/v1/Eventbus.cs" "csharp/grpcdc/events/v1/EventbusGit.cs")
    (kotlin "kotlin/grpcdc/Eventbus.kt" "kotlin/grpcdc/EventbusGit.kt")
    (scala "scala/grpcdc/Eventbus.scala" "scala/grpcdc/EventbusGit.scala")
    (swift "swift/grpcdc/Eventbus.swift" "swift/grpcdc/EventbusGit.swift")
    (cpp "cpp/grpcdc/eventbus.hpp" "cpp/grpcdc/eventbus_git.hpp")
    (zig "zig/examples/eventbus.zig" "zig/examples/eventbus_git.zig")
    (c "c/grpcdc/eventbus.h" "c/grpcdc/eventbus_git.h")))
