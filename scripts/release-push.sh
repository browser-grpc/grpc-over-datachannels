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
  --add-topic typescript 2>/dev/null | grep -v "graphql:" || true

# Social preview card (Settings > Social preview on the repo):
# upload the rendered 1280x640 PNG so shared links render with
# the card. Best-effort — failure never blocks a publish.
if [ -f "$EXPORT/docs/social-preview.png" ]; then
  gh api -X POST "repos/$REPO/social-preview" \
    -H "Accept: application/vnd.github+json" \
    --input "$EXPORT/docs/social-preview.png" >/dev/null 2>&1 \
    || echo "note: social preview upload skipped (needs repo admin via web UI)"
fi

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
# 3b. Package registries (npm). Publishing needs NPM_TOKEN in
#    the environment (or a prior `npm login`); without it this
#    step is a loud note, never a silent skip and never a failed
#    publish. The tarball is always dry-run first (file list +
#    metadata are the newcomer-facing artifact).
# ------------------------------------------------------------------
NPM_DIR="$EXPORT/js"
if [ -d "$NPM_DIR" ] && command -v npm >/dev/null 2>&1; then
  (cd "$NPM_DIR" && npm publish --dry-run 2>&1 | tail -5) || true
  if npm whoami >/dev/null 2>&1; then
    if (cd "$NPM_DIR" && npm publish --access public); then
      echo "npm: grpc-dc@$VERSION published"
    else
      echo "note: npm publish failed (version may already exist); continuing"
    fi
  else
    echo "note: npm publish skipped (not logged in; set NPM_TOKEN or npm login)"
  fi
fi

# ------------------------------------------------------------------
# 3c. Plugin container image (ghcr.io): protoc + all plugins on
#     PATH, no host Node needed. Best-effort like npm — a failed
#     push is a loud note, never a failed publish.
# ------------------------------------------------------------------
if [ -f "$EXPORT/docker/protoc-plugins.Dockerfile" ]; then
  if command -v docker >/dev/null 2>&1; then
    IMAGE="ghcr.io/browser-grpc/protoc-plugins"
    gh auth token 2>/dev/null | docker login ghcr.io -u "$ORG" \
      --password-stdin >/dev/null 2>&1 || true
    if docker build -f "$EXPORT/docker/protoc-plugins.Dockerfile" \
         -t "$IMAGE:$VERSION" -t "$IMAGE:latest" "$EXPORT"; then
      if docker push "$IMAGE:$VERSION" && docker push "$IMAGE:latest"; then
        echo "container: $IMAGE:$VERSION pushed"
        gh api -X PATCH "orgs/$ORG/packages/container/protoc-plugins/visibility" \
          -f visibility=public >/dev/null 2>&1 \
          || echo "note: set the protoc-plugins GHCR package to Public (org > Packages)"
      else
        echo "note: container push failed (ghcr login?); continuing"
      fi
    else
      echo "note: container build failed; continuing"
    fi
  else
    echo "note: container image skipped (docker not available)"
  fi
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
# 4b. Release asset: self-contained plugin zip + SHA256SUMS.
#     The zip mirrors the clone layout (bin/ + docs/app) so the
#     wrappers run in place after unzip. Idempotent (--clobber).
# ------------------------------------------------------------------
STAGE="$WORK/grpc-dc-$VERSION"
mkdir -p "$STAGE/docs/app"
cp -r "$EXPORT/bin" "$STAGE/bin"
cp "$EXPORT/docs/app/protoc-gen-grpc-dc.mjs" "$STAGE/docs/app/"
cp -r "$EXPORT/docs/app/gen" "$STAGE/docs/app/gen"
cp -r "$EXPORT/proto" "$STAGE/proto"
cp "$EXPORT/PLUGINS.md" "$EXPORT/LICENSE" "$STAGE/"
ZIP="$WORK/grpc-dc-$VERSION.zip"
(cd "$WORK" && zip -qr "$ZIP" "grpc-dc-$VERSION")
(cd "$WORK" && sha256sum "grpc-dc-$VERSION.zip" > SHA256SUMS)
gh release upload "$VERSION" --repo "$REPO" --clobber \
  "$ZIP" "$WORK/SHA256SUMS"
echo "release asset: grpc-dc-$VERSION.zip + SHA256SUMS uploaded"

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
