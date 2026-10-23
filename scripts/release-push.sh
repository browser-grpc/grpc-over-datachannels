#!/bin/sh
# Publish the generated public export (make release-public)
# to github.com/browser-grpc/grpc-over-datachannels, tag and
# release it, enable GitHub Pages (docs/ on the default
# branch), publish the org profile, and verify the live site.
# Explicit step: run only after reviewing the dry-run export
# tree. Every step is idempotent; re-running is a no-op when
# the export is unchanged.
#
# Usage: scripts/release-push.sh [VERSION]   (default: make's)
set -eu

VERSION="${1:-$(git describe --tags --abbrev=0)}"
EXPORT="release/browser-grpc"
REPO="browser-grpc/grpc-over-datachannels"
ORG="browser-grpc"
PROFILE_REPO="browser-grpc/.github"
SITE="https://browser-grpc.github.io/grpc-over-datachannels"

command -v gh >/dev/null || { echo "gh is required" >&2; exit 1; }
command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }

[ -d "$EXPORT" ] || { echo "no export at $EXPORT; run: make release-public VERSION=$VERSION" >&2; exit 1; }
grep -q "\"version\": \"$VERSION\"" "$EXPORT/RELEASE.json" || {
  echo "export is not $VERSION; regenerate: make release-public VERSION=$VERSION" >&2; exit 1; }

# ------------------------------------------------------------------
# 1. Repo (create on first use) + export content + tag.
# ------------------------------------------------------------------
if ! gh repo view "$REPO" >/dev/null 2>&1; then
  gh repo create "$REPO" --public \
    --description "gRPC over WebRTC DataChannels — generated multi-language runtimes (public export)"
fi

# Discoverability (idempotent; aligned every publish): keyword
# description for web/browser developers, the live site as
# homepage, and topics GitHub search indexes. gh --add-topic
# merges (verified), so naming the keyword set here suffices.
gh repo edit "$REPO" \
  --description "gRPC in the browser over WebRTC DataChannels: dependency-free generated gRPC clients & servers for JavaScript, Go, Rust, Python + 12 more languages — no grpc-web proxy" \
  --homepage "https://browser-grpc.github.io/grpc-over-datachannels/" \
  --add-topic grpc --add-topic grpc-web --add-topic webrtc \
  --add-topic datachannel --add-topic rtcdatachannel \
  --add-topic protobuf --add-topic protoc --add-topic protoc-plugin \
  --add-topic wasm --add-topic webassembly --add-topic codegen \
  --add-topic browser --add-topic peer-to-peer --add-topic javascript \
  --add-topic typescript | grep -v "graphql:" || true

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
gh repo clone "$REPO" "$WORK/public"
rsync -a --delete --exclude .git "$EXPORT/" "$WORK/public/"
cd "$WORK/public"
git add -A
if git diff --cached --quiet; then
  echo "export unchanged; nothing to publish"
else
  git -c user.name="John Davis" -c user.email="jdavis@pcprogramming.com" \
    commit -m "release $VERSION (generated export)"
  git tag "$VERSION"
  git push origin HEAD
  git push origin "$VERSION"
  echo "published $REPO $VERSION"
fi
cd - >/dev/null

DEFAULT_BRANCH="$(gh repo view "$REPO" --json defaultBranchRef --jq .defaultBranchRef.name)"
echo "default branch: $DEFAULT_BRANCH"

# ------------------------------------------------------------------
# 2. GitHub Pages: /docs on the default branch (create or align).
# ------------------------------------------------------------------
PAGES_JSON="$(printf '{"source":{"branch":"%s","path":"/docs"}}' "$DEFAULT_BRANCH")"
if gh api "repos/$REPO/pages" >/dev/null 2>&1; then
  echo "$PAGES_JSON" | gh api "repos/$REPO/pages" -X PUT --input - >/dev/null
  echo "pages: source aligned to $DEFAULT_BRANCH /docs"
else
  echo "$PAGES_JSON" | gh api "repos/$REPO/pages" -X POST --input - >/dev/null
  echo "pages: enabled ($DEFAULT_BRANCH /docs)"
fi

# ------------------------------------------------------------------
# 3. Org profile: browser-grpc/.github profile/README.md.
# ------------------------------------------------------------------
if [ -f "$EXPORT/org-profile/README.md" ]; then
  if ! gh repo view "$PROFILE_REPO" >/dev/null 2>&1; then
    gh repo create "$PROFILE_REPO" --public \
      --description "Community health files for the browser-grpc org"
  fi
  gh repo clone "$PROFILE_REPO" "$WORK/profile"
  mkdir -p "$WORK/profile/profile"
  cp "$EXPORT/org-profile/README.md" "$WORK/profile/profile/README.md"
  cd "$WORK/profile"
  git add -A
  if git diff --cached --quiet; then
    echo "org profile unchanged"
  else
    git -c user.name="John Davis" -c user.email="jdavis@pcprogramming.com" \
      commit -m "org profile (generated export $VERSION)"
    git push origin HEAD
    echo "org profile published"
  fi
  cd - >/dev/null
fi

# ------------------------------------------------------------------
# 4. GitHub Release for the tag (notes from the export's
#    CHANGELOG section; generated notes as fallback).
# ------------------------------------------------------------------
if gh release view "$VERSION" --repo "$REPO" >/dev/null 2>&1; then
  echo "release $VERSION already exists"
else
  NOTES="$WORK/notes.md"
  awk -v v="## $VERSION" '
    index($0, v) == 1 { found = 1; next }
    found && /^## / { exit }
    found { print }
  ' "$EXPORT/CHANGELOG.md" > "$NOTES"
  if [ -s "$NOTES" ]; then
    gh release create "$VERSION" --repo "$REPO" --title "$VERSION" --notes-file "$NOTES"
  else
    gh release create "$VERSION" --repo "$REPO" --title "$VERSION" --generate-notes
  fi
  echo "release $VERSION created"
fi

# ------------------------------------------------------------------
# 5. Verify the live site (Pages builds take a minute or so;
#    "published" means reachable, so poll and fail loudly).
# ------------------------------------------------------------------
echo "verifying $SITE ..."
i=0
while [ $i -lt 36 ]; do
  if curl -sf -o /dev/null "$SITE/" && curl -sf -o /dev/null "$SITE/app/"; then
    echo "site live: $SITE/ and $SITE/app/ return 200"
    echo "done: $REPO $VERSION published and verified"
    exit 0
  fi
  i=$((i + 1))
  sleep 5
done
echo "error: site did not return 200 within 3 minutes: $SITE/" >&2
exit 1
