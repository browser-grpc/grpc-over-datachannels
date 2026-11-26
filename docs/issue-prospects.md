# Issue Prospects — find/track GitHub issues that may want what we offer

What we offer, in one line: full gRPC (unary + bidirectional streaming)
in the browser and peer-to-peer over WebRTC data channels, with no
Envoy/grpc-web proxy, plus Kafka and Kafka Streams over the same gRPC
surface, in 16+ languages from one Racket/Rust codegen core.

This file tracks external issues where that is a genuine answer.
Populated 2026-11-25 from live `gh api search/issues` runs (queries
at the bottom). Status column is ours: `new` → `engaged` →
`answered` / `not-a-fit`. Only add a row with a real URL you opened.
Once a comment is drafted or posted, the authoritative record is
[docs/outreach/comment-log.md](outreach/comment-log.md) — check it
before engaging (never comment twice on the same thread).

## Tier 1 — direct fit (bidirectional/browser streaming pain)

| Issue | Opened | Signal | Fit | Status |
|---|---|---|---|---|
| [Multiple server-side streaming calls hangs the browser — grpc/grpc-web#1104](https://github.com/grpc/grpc-web/issues/1104) | 2021-07-10 | 4 comments, still open | Streaming over data channels has no HTTP/1.1 browser connection cap | new |
| [Browser CPU increases over time when streaming — grpc/grpc-web#714](https://github.com/grpc/grpc-web/issues/714) | 2020-01-23 | 6 comments, still open | No per-message HTTP framing/parsing in browser | new |
| [When streaming, the browser CPU increases with time — grpc/grpc-web#949](https://github.com/grpc/grpc-web/issues/949) | 2020-09-02 | duplicate of #714 theme | Same as #714 — one good answer can link both | new |
| [truncated response frame ends a streaming call silently — grpc/grpc-web#1563](https://github.com/grpc/grpc-web/issues/1563) | 2026-11-21 | fresh, 0 comments | Data-channel framing surfaces truncation as a status, not silence | new |
| [Server - Client Bidirectional streaming — improbable-eng/grpc-web#996](https://github.com/improbable-eng/grpc-web/issues/996) | 2021-06-07 | 5 comments; grpc-web cannot do client-streaming | Our browser client does full bidirectional streaming | new |
| [Support Client Streaming for fetch API — connectrpc/connect-es#669](https://github.com/connectrpc/connect-es/issues/669) | 2023-06-06 | 15 comments | Client-streaming without fetch-API limits, via data channel transport | new |
| [WebTransport transport — connectrpc/connect-es#1106](https://github.com/connectrpc/connect-es/issues/1106) | 2024-06-13 | 16 comments; appetite for non-HTTP transports | WebRTC data channel is the shipped alternative transport | new |
| [Support HTTP/2 bidirectional streaming (gRPC) in Workers/Durable Objects — cloudflare/workerd#6455](https://github.com/cloudflare/workerd/issues/6455) | 2026-03-29 | 12 comments | Edge/browser-adjacent bidi streaming want | new |
| [console: Watch streams disabled — gRPC-web does not support bidirectional streaming — rbkrabbe/ginnungagap#53](https://github.com/rbkrabbe/ginnungagap/issues/53) | 2026-06-06 | small project, explicit limitation | Direct swap story; small projects reply best | drafted |
| [Support for grpc-web — spring-projects/spring-grpc#427](https://github.com/spring-projects/spring-grpc/issues/427) | 2026-09-08 | server-side project wanting browser story | Java stubs on both sides; browser angle confirmed in body | drafted |

## Tier 2 — adjacent (transport/framework appetite)

| Issue | Opened | Signal | Fit | Status |
|---|---|---|---|---|
| [[feature]: gRPC-Web support — hoppscotch/hoppscotch#402](https://github.com/hoppscotch/hoppscotch/issues/402) | — | 118 reactions | Tooling, not runtime — low priority | new |
| [Add new transport: gRPC-Web — socketio/socket.io#5068](https://github.com/socketio/socket.io/issues/5068) | 2024-02-02 | transport-pluggability interest | Weak fit; watch only | new |
| [What can the Pion team do to make WebRTC easier — pion/webrtc#1981](https://github.com/pion/webrtc/issues/1981) | 2021-10-10 | 23 comments | "RPC over data channels" is a named ergonomics gap | new |
| [RFC: Evaluation of network remote call protocols for Wechaty 2.0 — wechaty/wechaty#3058](https://github.com/wechaty/wechaty/issues/3058) | 2026-11-23 | fresh protocol evaluation | Offer only with a concrete comparison, no drive-by | new |

## Checked, weak/no fit (kept so we don't re-triage)

- Kafka browser searches return mostly unrelated client-maintenance
  issues (kafkajs deprecation etc.) — no live "Kafka from browser"
  prospect found 2026-11-25. Re-run quarterly.
- Generic "grpc browser" / "grpc webrtc" searches are dominated by
  unrelated projects and notes repos. Always scope with `repo:` or
  quoted pain phrases.

## How to refresh (weekly is enough)

```bash
q() { gh api -X GET search/issues -f q="$1" -f per_page=10 \
  --jq '.items[] | "\(.title) | \(.html_url) | \(.created_at[0:10]) | comments:\(.comments)"'; }

q 'repo:grpc/grpc-web is:issue is:open (streaming OR browser OR bidirectional)'
q 'repo:connectrpc/connect-es is:issue is:open (webrtc OR datachannel OR peer OR streaming)'
q 'is:issue is:open "bidirectional streaming" grpc browser'
q 'is:issue is:open kafka (browser OR websocket) client javascript'
gh api -X GET search/issues -f q='is:issue is:open grpc browser streaming' \
  -f sort=reactions -f per_page=10 --jq '.items[] | "\(.title) | \(.html_url) | reactions:\(.reactions.total_count)"'
```

Diff against the tables above, add new rows as `new`, and bump
`updated` dates. There is no webhook for other people's repos —
polling this file's queries is the mechanism.

## Engagement rules

1. Answer the question first; mention this project once, with a
   working example sized to their problem.
2. Never post the same text twice; never post where the maintainer
   is the solution (e.g. pitching Pion users inside pion/webrtc
   unless the thread asks for higher-level RPC).
3. Mark `engaged` with the comment URL; if a maintainer says no,
   mark `not-a-fit` and don't repost on that repo.
