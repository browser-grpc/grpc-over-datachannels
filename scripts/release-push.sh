#!/bin/sh
# Publish the generated public export (make release-public)
# to github.com/browser-grpc/grpc-over-datachannels and tag
# it. Explicit step: run only after reviewing the dry-run
# export tree. Creates the GitHub repo on first use.
#
# Usage: scripts/release-push.sh [VERSION]   (default: make's)
set -eu

VERSION="${1:-$(git describe --tags --abbrev=0)}"
EXPORT="release/browser-grpc"
REPO="browser-grpc/grpc-over-datachannels"

[ -d "$EXPORT" ] || { echo "no export at $EXPORT; run: make release-public VERSION=$VERSION" >&2; exit 1; }
grep -q "\"version\": \"$VERSION\"" "$EXPORT/RELEASE.json" || {
  echo "export is not $VERSION; regenerate: make release-public VERSION=$VERSION" >&2; exit 1; }

if ! gh repo view "$REPO" >/dev/null 2>&1; then
  gh repo create "$REPO" --public \
    --description "gRPC over WebRTC DataChannels — generated multi-language runtimes (public export)"
  gh repo edit "$REPO" --add-topic grpc --add-topic webrtc \
    --add-topic datachannel --add-topic wasm --add-topic codegen
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
gh repo clone "$REPO" "$WORK/public"
rsync -a --delete --exclude .git "$EXPORT/" "$WORK/public/"
cd "$WORK/public"
git add -A
if git diff --cached --quiet; then
  echo "export unchanged; nothing to publish"
  exit 0
fi
git -c user.name="John Davis" -c user.email="jdavis@pcprogramming.com" \
  commit -m "release $VERSION (generated export)"
git tag "$VERSION"
git push origin HEAD
git push origin "$VERSION"
echo "published $REPO $VERSION"
echo "Pages: enable docs/ on the default branch once via repo Settings if not yet on;"
echo "site will be https://browser-grpc.github.io/grpc-over-datachannels/"
