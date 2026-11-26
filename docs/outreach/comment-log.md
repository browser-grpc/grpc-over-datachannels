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

Drafted (not posted — awaiting approval):

- 2026-11-25 rbkrabbe/ginnungagap issue #53 "console: Watch
  streams disabled — gRPC-web does not support bidirectional
  streaming"
  https://github.com/rbkrabbe/ginnungagap/issues/53
  Draft: "A third option alongside SSE: keep the same proto and
  the same Watch RPC, but swap the browser transport. gRPC-web
  can't forward client/bidi streams (as you note), whereas
  grpc-over-datachannels runs full gRPC — including
  bidirectional streaming — from the browser over a WebRTC data
  channel, with generated JS/TS clients from the same .proto
  (no Envoy/tonic-web hop). Trade-off to weigh against your
  Option A: the browser side needs WebRTC signalling/rendezvous
  instead of plain HTTP, so SSE is simpler if Watch is the only
  bidi call you ever need; the data-channel route pays off if
  more of the console wants client-streaming. Worked example:
  https://browser-grpc.github.io/grpc-over-datachannels/
  (maintainer of that project — happy to be told this is out of
  scope here.)"

- 2026-11-25 spring-projects/spring-grpc issue #427 "Support
  for grpc-web"
  https://github.com/spring-projects/spring-grpc/issues/427
  Draft: "Not a grpc-web implementation, so possibly out of
  scope for this issue — flagging only because the underlying
  goal is browser clients reaching a Spring gRPC service,
  including streaming shapes grpc-web can't carry. An
  alternative that exists today: grpc-over-datachannels
  generates Java clients/servers (same .proto) that speak gRPC
  over WebRTC data channels, so a browser can call the service
  with full bidirectional streaming and no grpc-web proxy or
  encoder/decoder layer. It doesn't help if grpc-web spec
  compliance itself is the requirement.
  https://github.com/browser-grpc/grpc-over-datachannels
  (I'm the maintainer; feel free to close as off-topic.)"

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
