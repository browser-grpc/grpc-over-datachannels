#!/usr/bin/env bash
# Stop the issue agent and remove its GitHub webhook.
set -uo pipefail

REPO="${IA_REPO:-browser-grpc/grpc-over-datachannels}"
STATE="${IA_STATE_DIR:-$HOME/.local/state/issue-agent}"

for name in tunnel server; do
  f="$STATE/$name.pid"
  if [ -f "$f" ] && kill -0 "$(cat "$f")" 2>/dev/null; then
    kill "$(cat "$f")" && echo "$name stopped (pid $(cat "$f"))"
  fi
  rm -f "$f"
done

HOOK_ID="$(python3 -c "import json;print(json.load(open('$STATE/state.json')).get('hook_id',''))" 2>/dev/null || echo "")"
if [ -n "$HOOK_ID" ]; then
  if gh api -X DELETE "repos/$REPO/hooks/$HOOK_ID" 2>/dev/null; then
    echo "webhook $HOOK_ID removed from $REPO"
  else
    echo "webhook $HOOK_ID already gone (or not removable)"
  fi
  rm -f "$STATE/state.json"
fi
echo "stopped."
