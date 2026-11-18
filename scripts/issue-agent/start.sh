#!/usr/bin/env bash
# Start the issue agent: receiver + cloudflared quick tunnel + webhook.
set -euo pipefail

REPO="${IA_REPO:-browser-grpc/grpc-over-datachannels}"
PORT="${IA_PORT:-8787}"
STATE="${IA_STATE_DIR:-$HOME/.local/state/issue-agent}"
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$STATE/work"

if [ ! -f "$STATE/secret.txt" ]; then
  openssl rand -hex 32 > "$STATE/secret.txt"
  chmod 600 "$STATE/secret.txt"
  echo "generated webhook secret in $STATE/secret.txt"
fi
SECRET="$(cat "$STATE/secret.txt")"

gh auth setup-git >/dev/null 2>&1 || true

alive() { [ -f "$1" ] && kill -0 "$(cat "$1")" 2>/dev/null; }

if alive "$STATE/server.pid"; then
  echo "server already running (pid $(cat "$STATE/server.pid"))"
else
  IA_REPO="$REPO" IA_PORT="$PORT" IA_STATE_DIR="$STATE" \
    setsid -f node "$HERE/server.mjs" >> "$STATE/server.log" 2>&1
  # setsid -f forks; find the listener pid via the port owner
  for i in $(seq 1 20); do
    pid="$(ss -tlnp "sport = :$PORT" 2>/dev/null | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2 || true)"
    [ -n "${pid:-}" ] && break
    sleep 0.5
  done
  echo "${pid:-}" > "$STATE/server.pid"
  echo "server started (pid ${pid:-unknown})"
fi

curl -s -m 3 "http://127.0.0.1:$PORT/healthz" >/dev/null || { echo "server health check FAILED - see $STATE/server.log"; exit 1; }

if alive "$STATE/tunnel.pid"; then
  echo "tunnel already running (pid $(cat "$STATE/tunnel.pid"))"
else
  : > "$STATE/tunnel.log"
  setsid -f cloudflared tunnel --url "http://127.0.0.1:$PORT" >> "$STATE/tunnel.log" 2>&1
  sleep 1
  cpid="$(pgrep -f "cloudflared tunnel --url http://127.0.0.1:$PORT" | head -1 || true)"
  echo "${cpid:-}" > "$STATE/tunnel.pid"
  echo "tunnel starting (pid ${cpid:-unknown})"
fi

URL=""
for i in $(seq 1 30); do
  URL="$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' "$STATE/tunnel.log" | head -1 || true)"
  [ -n "$URL" ] && break
  sleep 1
done
[ -n "$URL" ] || { echo "tunnel URL not found - see $STATE/tunnel.log"; exit 1; }
echo "tunnel URL: $URL"

HOOK_ID="$(python3 -c "import json;print(json.load(open('$STATE/state.json')).get('hook_id',''))" 2>/dev/null || echo "")"
if [ -n "$HOOK_ID" ] && gh api "repos/$REPO/hooks/$HOOK_ID" >/dev/null 2>&1; then
  gh api -X PATCH "repos/$REPO/hooks/$HOOK_ID" \
    -f "config[url]=$URL/webhook" -f "config[content_type]=json" -f "config[secret]=$SECRET" >/dev/null
  echo "webhook $HOOK_ID updated -> $URL/webhook"
else
  HOOK_ID="$(gh api -X POST "repos/$REPO/hooks" -f name=web -F active=true \
    -f "config[url]=$URL/webhook" -f "config[content_type]=json" -f "config[secret]=$SECRET" \
    -f "events[]=issues" --jq .id)"
  echo "webhook created: $HOOK_ID -> $URL/webhook"
fi

python3 -c "import json;json.dump({'hook_id':'$HOOK_ID','url':'$URL','repo':'$REPO'},open('$STATE/state.json','w'),indent=1)"
echo "state: $STATE/state.json"
echo "DONE. Issues (opened/reopened) by OWNER/MEMBER/COLLABORATOR on $REPO will trigger the agent."
