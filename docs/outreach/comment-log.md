# Outreach comment log

2026-10-26: refreshed awesome-grpc PR #273 body for v0.32.15
(body-only edit, no ping). Status: v0.32.15 published — see
CHANGELOG.md and the GitHub release.

Threads where a grpc-over-datachannels comment has been posted
or drafted. Check this before drafting/posting anywhere new —
never comment twice on the same thread.

Candidate threads not yet engaged live in
[docs/issue-prospects.md](../issue-prospects.md); this log is the
authoritative record once a comment is drafted or posted. When a
prospect is engaged, move it here and mark it `engaged` there.

Posted:

- 2026-10-26 grpc/grpc-web discussion #1416 "has Bidirectional
  streaming been implemented for grpc-web?"
  https://github.com/grpc/grpc-web/discussions/1416#discussioncomment-19205800
  (answer: no as of 2026 + why; alternative: this project)

- 2026-11-25 rbkrabbe/ginnungagap issue #53 "console: Watch
  streams disabled — gRPC-web does not support bidirectional
  streaming"
  https://github.com/rbkrabbe/ginnungagap/issues/53#issuecomment-7188663052
  (Option C pitch: swap transport, keep proto/Watch; disclosed
  maintainership and SSE trade-off)
- 2026-11-25 spring-projects/spring-grpc issue #427 "Support
  for grpc-web"
  https://github.com/spring-projects/spring-grpc/issues/427#issuecomment-7188663583
  ("not grpc-web, possibly out of scope" framing; Java
  data-channel alternative for browser access)

Considered and rejected (do not revisit):

- grpc/grpc-web issues #24, #13, #95 — closed 2016-2023,
  necroposting.
- grpc/grpc-web discussion #1531 — maintainers' status
  thread; a pitch there reads as hijacking.
- connectrpc/connect-go discussion #254 — question is
  Connect-specific; a different-transport pitch is off-topic
  in a sibling project's repo.
- google/j2cl discussion #231 — wants j2cl examples
  specifically.
