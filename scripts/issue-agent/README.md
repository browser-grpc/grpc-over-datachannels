# Issue agent

Realtime GitHub issue responder for `browser-grpc/grpc-over-datachannels`.
A webhook delivers `issues` events through a cloudflared tunnel to a
local receiver, which queues member-authored issues and works them
serially: ack comment, fresh clone, `muse exec` fix on a branch,
push, PR, and a summary comment on the issue. Nothing merges
automatically.

## Run

```sh
scripts/issue-agent/start.sh   # server + tunnel + webhook registration
scripts/issue-agent/stop.sh    # stops processes, removes the webhook
```

State (secret, logs, pidfiles, work clones) lives in
`~/.local/state/issue-agent/` — never in this repo. The webhook secret
is generated on first start (mode 600) and registered with the hook.

## Trigger policy

Only `issues` `opened`/`reopened` whose `author_association` is
OWNER, MEMBER, or COLLABORATOR. Everyone else is logged and ignored.
Add the `agent-dry-run` label in a payload to exercise the pipeline
with no side effects (used by the built-in proof below).

## Proof / smoke test

With the tunnel URL from `~/.local/state/issue-agent/state.json`:

```sh
# signed dry-run event (no comments, no PR) - see server.log
node scripts/issue-agent/prove.mjs
```

## Notes

- Quick-tunnel URLs change on every tunnel restart; `start.sh`
  re-registers (PATCHes) the existing webhook when hook state exists.
- The agent runs `muse exec --yolo` in a throwaway clone under the
  state dir, so issue text never touches the main checkout. Output is
  limited to a branch + PR by construction.
- Serial queue: one issue at a time, 30-minute agent timeout
  (`IA_AGENT_TIMEOUT_MS`).
