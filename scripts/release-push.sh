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
# SKIP_CENTRAL=1 skips the Maven Central dispatch (e.g. while
# Sonatype's deployment count is throttled); Central is synced
# later in its weekly slot. The GitHub-hosted Maven channel
# (publish-maven-github) is unaffected and always dispatched.
set -eu

VERSION="${1:-$(git describe --tags --abbrev=0)}"
EXPORT="release/browser-grpc"
KP_EXPORT="release/kafka-proxy"
KN_EXPORT="release/kafka-native"
KN_REPO="browser-grpc/kafka-native"
PHP_EXPORT="release/grpc-php"
PHP_REPO="browser-grpc/grpc-dc-php"
KPHP_EXPORT="release/kafka-php"
KPHP_REPO="browser-grpc/kafka-grpc-php"
EBPHP_EXPORT="release/eventbus-php"
EBPHP_REPO="browser-grpc/eventbus-grpc-php"
KP_REPO="browser-grpc/kafka-proxy"
EB_EXPORT="release/eventbus"
EB_REPO="browser-grpc/eventbus"
EX_EXPORT="release/examples"
EX_REPO="browser-grpc/examples"
REPO="browser-grpc/grpc-over-datachannels"
ORG="browser-grpc"
PROFILE_REPO="browser-grpc/.github"
SITE="https://browser-grpc.github.io/grpc-over-datachannels"

# Persistent NuGet key (one-time setup; see the NuGet step).
if [ -z "${NUGET_API_KEY:-}" ] && [ -f "$HOME/.config/grpc-dc/nuget.env" ]; then
  . "$HOME/.config/grpc-dc/nuget.env"
  export NUGET_API_KEY
fi

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
rsync -a --delete --exclude .git --exclude docs/maven "$EXPORT/" "$WORK/public/"
cd "$WORK/public"
git add -A
if git diff --cached --quiet; then
  echo "export unchanged; nothing to publish"
else
  git -c user.name="John Davis" -c user.email="jdavis@pcprogramming.com" \
    commit -m "release $VERSION (generated export)"
  # Re-runs after the tag exists (export fixups) must still push
  # the new commit; only create/push the tag the first time.
  if git rev-parse "$VERSION" >/dev/null 2>&1; then
    echo "tag $VERSION already exists; pushing export commit only"
    git push origin HEAD
  else
    git rev-parse "$VERSION" >/dev/null 2>&1 || git tag "$VERSION"
    git push origin HEAD
    git push origin "$VERSION"
  fi
  # Submodule tags: the Go module proxy resolves the modules at
  # go/ and webrtc/go/ only via go/<version> / webrtc/go/<version>
  # tags (pkg.go.dev). Same commit as $VERSION.
  for sub in go webrtc/go kafka eventbus; do
    git rev-parse "$sub/$VERSION" >/dev/null 2>&1 || git tag "$sub/$VERSION"
  done
  git push origin "go/$VERSION" "webrtc/go/$VERSION" "kafka/$VERSION" "eventbus/$VERSION"
  echo "published $REPO $VERSION"
fi
cd - >/dev/null

# ------------------------------------------------------------------
# 1b. Kafka proxy repo (browser-grpc/kafka-proxy): standalone
#     generated subset export (no Racket source; the exporter's
#     leak gate enforces it). Same version/tag as the main repo.
# ------------------------------------------------------------------
if [ -d "$KP_EXPORT" ]; then
  if ! gh repo view "$KP_REPO" >/dev/null 2>&1; then
    gh repo create "$KP_REPO" --public \
      --description "Kafka over gRPC proxy — expose Apache Kafka/Redpanda as a generated gRPC service for browser + native clients"
  fi
  gh repo clone "$KP_REPO" "$WORK/kafka-proxy"
  rsync -a --delete --exclude .git "$KP_EXPORT/" "$WORK/kafka-proxy/"
  cd "$WORK/kafka-proxy"
  git add -A
  if git diff --cached --quiet; then
    echo "kafka-proxy export unchanged; nothing to publish"
  else
    git -c user.name="John Davis" -c user.email="jdavis@pcprogramming.com" \
      commit -m "release $VERSION (generated export)"
    git rev-parse "$VERSION" >/dev/null 2>&1 || git tag "$VERSION"
    git push origin HEAD
    git push origin "$VERSION"
    echo "published $KP_REPO $VERSION"
  fi
  cd - >/dev/null
else
  echo "note: no kafka-proxy export at $KP_EXPORT; skipping repo publish"
fi

# ------------------------------------------------------------------
# 1ba. Kafka native repo (browser-grpc/kafka-native): standalone
#     in-process client export (no Racket source; the
#     exporter's leak gate enforces it). Same version/tag.
# ------------------------------------------------------------------
if [ -d "$KN_EXPORT" ]; then
  if ! gh repo view "$KN_REPO" >/dev/null 2>&1; then
    gh repo create "$KN_REPO" --public \
      --description "Kafka native client — in-process Kafka protocol library (Rust crate, C ABI, Python) for Apache Kafka/Redpanda"
  fi
  gh repo clone "$KN_REPO" "$WORK/kafka-native"
  rsync -a --delete --exclude .git "$KN_EXPORT/" "$WORK/kafka-native/"
  cd "$WORK/kafka-native"
  git add -A
  if git diff --cached --quiet; then
    echo "kafka-native export unchanged; nothing to publish"
  else
    git -c user.name="John Davis" -c user.email="jdavis@pcprogramming.com" \
      commit -m "release $VERSION (generated export)"
    git rev-parse "$VERSION" >/dev/null 2>&1 || git tag "$VERSION"
    git push origin HEAD
    git push origin "$VERSION"
    echo "published $KN_REPO $VERSION"
  fi
  cd - >/dev/null
else
  echo "note: no kafka-native export at $KN_EXPORT; skipping repo publish"
fi

# 1bb. kafka-native registry workflows (crates.io + PyPI via
# Trusted Publishing from the kafka-native repo itself).
# Best-effort: both fail until the owner's Trusted Publisher
# entries exist on crates.io / PyPI.
if [ -d "$KN_EXPORT" ]; then
  echo "== dispatching kafka-native publish workflows"
  gh workflow run publish-crates.yml --repo "$KN_REPO" 2>&1 || \
    echo "note: kafka-native publish-crates dispatch failed (Trusted Publisher pending?)"
  gh workflow run publish-pypi.yml --repo "$KN_REPO" 2>&1 || \
    echo "note: kafka-native publish-pypi dispatch failed (Trusted Publisher pending?)"
fi

# ------------------------------------------------------------------
# 1bb. Packagist repos (browser-grpc/grpc-dc-php,
#     browser-grpc/kafka-grpc-php): one composer package per
#     repo for Packagist. Same version/tag; Packagist picks up
#     new tags automatically after the one-time submission.
# ------------------------------------------------------------------
for pair in "$PHP_EXPORT $PHP_REPO" "$KPHP_EXPORT $KPHP_REPO" "$EBPHP_EXPORT $EBPHP_REPO"; do
  set -- $pair
  P_EXPORT="$1"; P_REPO="$2"
  if [ -d "$P_EXPORT" ]; then
    if ! gh repo view "$P_REPO" >/dev/null 2>&1; then
      gh repo create "$P_REPO" --public \
        --description "Generated PHP package for Packagist (browser-grpc) — dependency-free gRPC over WebRTC DataChannels"
    fi
    gh repo clone "$P_REPO" "$WORK/$(basename "$P_REPO")"
    rsync -a --delete --exclude .git "$P_EXPORT/" "$WORK/$(basename "$P_REPO")/"
    cd "$WORK/$(basename "$P_REPO")"
    git add -A
    if git diff --cached --quiet; then
      echo "$P_REPO export unchanged; nothing to publish"
    else
      git -c user.name="John Davis" -c user.email="jdavis@pcprogramming.com" \
        commit -m "release $VERSION (generated export)"
      git rev-parse "$VERSION" >/dev/null 2>&1 || git tag "$VERSION"
      git push origin HEAD
      git push origin "$VERSION"
      echo "published $P_REPO $VERSION"
    fi
    cd - >/dev/null
  else
    echo "note: no export at $P_EXPORT; skipping $P_REPO publish"
  fi
done

# ------------------------------------------------------------------
# 1c. EventBus repo (browser-grpc/eventbus): standalone generated
#     subset export (no Racket source; leak gate enforced).
#     Same version/tag as the main repo.
# ------------------------------------------------------------------
if [ -d "$EB_EXPORT" ]; then
  if ! gh repo view "$EB_REPO" >/dev/null 2>&1; then
    gh repo create "$EB_REPO" --public \
      --description "Event bus over gRPC — generated grpcdc.events.v1 publish/subscribe brokers and clients for browser + native"
  fi
  gh repo clone "$EB_REPO" "$WORK/eventbus"
  rsync -a --delete --exclude .git "$EB_EXPORT/" "$WORK/eventbus/"
  cd "$WORK/eventbus"
  git add -A
  if git diff --cached --quiet; then
    echo "eventbus export unchanged; nothing to publish"
  else
    git -c user.name="John Davis" -c user.email="jdavis@pcprogramming.com" \
      commit -m "release $VERSION (generated export)"
    git rev-parse "$VERSION" >/dev/null 2>&1 || git tag "$VERSION"
    git push origin HEAD
    git push origin "$VERSION"
    echo "published $EB_REPO $VERSION"
  fi
  cd - >/dev/null
else
  echo "note: no eventbus export at $EB_EXPORT; skipping repo publish"
fi

# ------------------------------------------------------------------
# 1d. Examples catalog repo (browser-grpc/examples): generated
#     index only, no copied code (leak gate enforced). Same
#     version/tag as the main repo.
# ------------------------------------------------------------------
if [ -d "$EX_EXPORT" ]; then
  if ! gh repo view "$EX_REPO" >/dev/null 2>&1; then
    gh repo create "$EX_REPO" --public \
      --description "grpc-dc examples catalog — every runnable gRPC-over-WebRTC example, indexed by language and scenario"
  fi
  gh repo clone "$EX_REPO" "$WORK/examples"
  rsync -a --delete --exclude .git "$EX_EXPORT/" "$WORK/examples/"
  cd "$WORK/examples"
  git add -A
  if git diff --cached --quiet; then
    echo "examples export unchanged; nothing to publish"
  else
    git -c user.name="John Davis" -c user.email="jdavis@pcprogramming.com" \
      commit -m "release $VERSION (generated catalog)"
    git rev-parse "$VERSION" >/dev/null 2>&1 || git tag "$VERSION"
    git push origin HEAD
    git push origin "$VERSION"
    echo "published $EX_REPO $VERSION"
  fi
  cd - >/dev/null
else
  echo "note: no examples export at $EX_EXPORT; skipping repo publish"
fi

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
# 3b. Package registries (npm). Canonical publish is the
#    publish-npm Trusted Publishing workflow (dispatched in 4b;
#    OIDC, no stored token — required since npm retires
#    bypass-2FA token publishing in Jan 2027). Here we only
#    dry-run both tarballs (file list + metadata are the
#    newcomer-facing artifact) so a malformed package fails
#    loudly before anything is dispatched.
# ------------------------------------------------------------------
NPM_DIR="$EXPORT/js"
if [ -d "$NPM_DIR" ] && command -v npm >/dev/null 2>&1; then
  (cd "$NPM_DIR" && npm publish --dry-run 2>&1 | tail -5) || true
fi
KAFKA_NPM_DIR="$EXPORT/packages/kafka-js"
if [ -d "$KAFKA_NPM_DIR" ] && command -v npm >/dev/null 2>&1; then
  (cd "$KAFKA_NPM_DIR" && npm publish --dry-run 2>&1 | tail -5) || true
fi
EB_NPM_DIR="$EXPORT/packages/eventbus-js"
if [ -d "$EB_NPM_DIR" ] && command -v npm >/dev/null 2>&1; then
  (cd "$EB_NPM_DIR" && npm publish --dry-run 2>&1 | tail -5) || true
fi

# 3b2. Package registries (PyPI). Publishing needs a persistent
#     API token: TWINE_PASSWORD in the environment, or a
#     ~/.pypirc with a [pypi] __token__ entry (the one-time
#     setup printed below); without one this step is a loud
#     note, never a silent skip and never a failed publish.
#     The sdist + wheel are always built and checked first
#     (artifact contents + metadata are newcomer-facing).
PYPI_DIR="$EXPORT/python"
if [ -d "$PYPI_DIR" ] && command -v twine >/dev/null 2>&1; then
  (cd "$PYPI_DIR" && rm -rf dist && python3 -m build --outdir dist 2>&1 | tail -3 && twine check dist/*) || true
  if [ -n "${TWINE_PASSWORD:-}" ] || [ -f "$HOME/.pypirc" ]; then
    if (cd "$PYPI_DIR" && twine upload dist/*); then
      PYPI_OK=1
      echo "pypi: grpc-dc $VERSION published"
    else
      echo "note: pypi upload failed (version may already exist); continuing"
    fi
  else
    echo "note: pypi upload skipped (no TWINE_PASSWORD env and no ~/.pypirc)."
    echo "note: one-time setup: create an API token at https://pypi.org/manage/account/#api-tokens"
    echo "note: then store it persistently:"
    echo "note:   printf '[pypi]\\nusername = __token__\\npassword = <token>\\n' > ~/.pypirc && chmod 600 ~/.pypirc"
  fi
fi

# PyPI (kafka-grpc): separate package, same treatment.
KAFKA_PYPI_DIR="$EXPORT/packages/kafka-python"
if [ -d "$KAFKA_PYPI_DIR" ] && command -v twine >/dev/null 2>&1; then
  (cd "$KAFKA_PYPI_DIR" && rm -rf dist && python3 -m build --outdir dist 2>&1 | tail -2 && twine check dist/*) || true
  if [ -n "${TWINE_PASSWORD:-}" ] || [ -f "$HOME/.pypirc" ]; then
    if (cd "$KAFKA_PYPI_DIR" && twine upload dist/*); then
      echo "pypi: kafka-grpc $VERSION published"
    else
      echo "note: pypi kafka-grpc upload failed (version may already exist); continuing"
    fi
  fi
fi

# PyPI (eventbus-grpc): separate package, same treatment.
EB_PYPI_DIR="$EXPORT/packages/eventbus-python"
if [ -d "$EB_PYPI_DIR" ] && command -v twine >/dev/null 2>&1; then
  (cd "$EB_PYPI_DIR" && rm -rf dist && python3 -m build --outdir dist 2>&1 | tail -2 && twine check dist/*) || true
  if [ -n "${TWINE_PASSWORD:-}" ] || [ -f "$HOME/.pypirc" ]; then
    if (cd "$EB_PYPI_DIR" && twine upload dist/*); then
      echo "pypi: eventbus-grpc $VERSION published"
    else
      echo "note: pypi eventbus-grpc upload failed (version may already exist); continuing"
    fi
  fi
fi

# 3b3. Package registries (NuGet). Publishing needs NUGET_API_KEY
#     in the environment (one-time setup: nuget.org > API Keys,
#     a push-scoped key for the GrpcDc package); without it this
#     step is a loud note, never a silent skip and never a failed
#     publish. The package is always packed first so metadata
#     errors surface even without a key.
NUGET_PROJ="$EXPORT/csharp/grpcdc/Grpcdc.csproj"
if [ -f "$NUGET_PROJ" ] && command -v dotnet >/dev/null 2>&1; then
  NUGET_OUT="$WORK/nuget"
  mkdir -p "$NUGET_OUT"
  dotnet pack "$EXPORT/packages/kafka-csharp/KafkaGrpc.csproj" -c Release -o "$NUGET_OUT" >>"$WORK/nuget-pack.log" 2>&1 || echo "note: KafkaGrpc pack failed; continuing"
  if dotnet pack "$NUGET_PROJ" -c Release -o "$NUGET_OUT" >"$WORK/nuget-pack.log" 2>&1; then
    echo "nuget: packed $(ls "$NUGET_OUT"/*.nupkg | head -1)"
    if [ -n "${NUGET_API_KEY:-}" ]; then
      if dotnet nuget push "$NUGET_OUT"/*.nupkg --api-key "$NUGET_API_KEY" \
           --source https://api.nuget.org/v3/index.json --skip-duplicate; then
        echo "nuget: GrpcDc $VERSION published"
      else
        echo "note: nuget push failed (version may already exist); continuing"
      fi
    else
      echo "note: nuget push skipped (no NUGET_API_KEY env)."
      echo "note: preferred path is Trusted Publishing: dispatch the"
      echo "note:   publish-nuget workflow in browser-grpc/grpc-over-datachannels"
      echo "note:   (OIDC, no stored key). API-key fallback: create a push key"
      echo "note:   at https://www.nuget.org/account/apikeys and store it:"
      echo "note:   printf 'NUGET_API_KEY=<key>\\n' > ~/.config/grpc-dc/nuget.env && chmod 600 ~/.config/grpc-dc/nuget.env"
    fi
  else
    echo "note: nuget pack failed; see $WORK/nuget-pack.log; continuing"
    tail -5 "$WORK/nuget-pack.log" || true
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
# 3d. Kafka proxy container image (ghcr.io): the Rust kafka_proxy
#     (see the export's KAFKA.md). Best-effort like protoc-plugins.
# ------------------------------------------------------------------
if [ -f "$EXPORT/docker/kafka-proxy.Dockerfile" ]; then
  if command -v docker >/dev/null 2>&1; then
    IMAGE="ghcr.io/browser-grpc/kafka-proxy"
    gh auth token 2>/dev/null | docker login ghcr.io -u "$ORG" \
      --password-stdin >/dev/null 2>&1 || true
    if docker build -f "$EXPORT/docker/kafka-proxy.Dockerfile" \
         -t "$IMAGE:$VERSION" -t "$IMAGE:latest" "$EXPORT"; then
      if docker push "$IMAGE:$VERSION" && docker push "$IMAGE:latest"; then
        echo "container: $IMAGE:$VERSION pushed"
        gh api -X PATCH "orgs/$ORG/packages/container/kafka-proxy/visibility" \
          -f visibility=public >/dev/null 2>&1 \
          || echo "note: set the kafka-proxy GHCR package to Public (org > Packages)"
      else
        echo "note: kafka-proxy container push failed (ghcr login?); continuing"
      fi
    else
      echo "note: kafka-proxy container build failed; continuing"
    fi
  else
    echo "note: kafka-proxy container image skipped (docker not available)"
  fi
fi

# ------------------------------------------------------------------
# 3e. EventBus demo image (ghcr.io): runnable Python event bus
#     demo. Source is the eventbus export, not the main export.
#     Best-effort like the other images.
# ------------------------------------------------------------------
if [ -f "$EB_EXPORT/docker/eventbus-demo.Dockerfile" ]; then
  if command -v docker >/dev/null 2>&1; then
    IMAGE="ghcr.io/browser-grpc/eventbus-demo"
    gh auth token 2>/dev/null | docker login ghcr.io -u "$ORG" \
      --password-stdin >/dev/null 2>&1 || true
    if docker build -f "$EB_EXPORT/docker/eventbus-demo.Dockerfile" \
         -t "$IMAGE:$VERSION" -t "$IMAGE:latest" "$EB_EXPORT"; then
      if docker push "$IMAGE:$VERSION" && docker push "$IMAGE:latest"; then
        echo "container: $IMAGE:$VERSION pushed"
        gh api -X PATCH "orgs/$ORG/packages/container/eventbus-demo/visibility" \
          -f visibility=public >/dev/null 2>&1 \
          || echo "note: set the eventbus-demo GHCR package to Public (org > Packages)"
      else
        echo "note: eventbus-demo container push failed (ghcr login?); continuing"
      fi
    else
      echo "note: eventbus-demo container build failed; continuing"
    fi
  else
    echo "note: eventbus-demo image skipped (docker not available)"
  fi
fi

# ------------------------------------------------------------------
# 3f. GitHub Packages mirrors (npm / NuGet / RubyGems — the only
#     registries GitHub hosts; Maven stays on the Pages repo).
#     Both packages (grpc-dc + kafka-grpc) are mirrored. Token:
#     the gh session. Consumers still need a read:packages token
#     even for public packages; see GITHUB-PACKAGES.md in the
#     export. Best-effort: failures are loud notes.
# ------------------------------------------------------------------
GH_TOKEN_VAL="$(gh auth token 2>/dev/null || true)"
if [ -n "$GH_TOKEN_VAL" ]; then
  # npm: scoped staging copies (GitHub requires @org/name).
  for spec in "js:@browser-grpc/grpc-dc" "packages/kafka-js:@browser-grpc/kafka-grpc" "packages/eventbus-js:@browser-grpc/eventbus-grpc"; do
    SRC_DIR="$EXPORT/${spec%%:*}"
    [ -f "$SRC_DIR/package.github.json" ] || continue
    STAGE="$WORK/ghp-npm-$(basename "$SRC_DIR")"
    cp -r "$SRC_DIR" "$STAGE"
    cp "$STAGE/package.github.json" "$STAGE/package.json"
    rm -f "$STAGE/package.github.json"
    printf '@browser-grpc:registry=https://npm.pkg.github.com\n//npm.pkg.github.com/:_authToken=%s\n' "$GH_TOKEN_VAL" > "$STAGE/.npmrc"
    if (cd "$STAGE" && NODE_AUTH_TOKEN="$GH_TOKEN_VAL" npm publish --registry https://npm.pkg.github.com >/dev/null 2>&1); then
      echo "github packages: npm ${spec##*:}@$VERSION published"
    else
      echo "note: github packages npm ${spec##*:} publish failed (exists? token scope?); continuing"
    fi
  done
  # NuGet: push the nupkgs packed in step 3b3 (GrpcDc + KafkaGrpc).
  if command -v dotnet >/dev/null 2>&1 && ls "$WORK/nuget"/*.nupkg >/dev/null 2>&1; then
    for pkg in "$WORK/nuget"/*.nupkg; do
      if dotnet nuget push "$pkg" --api-key "$GH_TOKEN_VAL" --source "https://nuget.pkg.github.com/browser-grpc/index.json" --skip-duplicate >/dev/null 2>&1; then
        echo "github packages: nuget $(basename "$pkg") published"
      else
        echo "note: github packages nuget $(basename "$pkg") push failed; continuing"
      fi
    done
  fi
  # RubyGems: build both gems and push with a temp GEM_HOME.
  if command -v gem >/dev/null 2>&1; then
    GEM_TMP="$WORK/gemhome"; mkdir -p "$GEM_TMP/.gem"
    printf -- '---\n:github: Bearer %s\n' "$GH_TOKEN_VAL" > "$GEM_TMP/.gem/credentials"
    chmod 600 "$GEM_TMP/.gem/credentials"
    for spec in "packages/grpc-ruby/grpc-dc.gemspec" "packages/kafka-ruby/kafka-grpc.gemspec"; do
      [ -f "$EXPORT/$spec" ] || continue
      specdir="$(dirname "$spec")"
      if (cd "$EXPORT/$specdir" && gem build "$(basename "$spec")" >/dev/null 2>&1); then
        GEMFILE="$(ls -t "$EXPORT/$specdir"/*.gem 2>/dev/null | head -1)"
        if [ -n "$GEMFILE" ] && HOME="$GEM_TMP" gem push --key github --host "https://rubygems.pkg.github.com/browser-grpc" "$GEMFILE" >/dev/null 2>&1; then
          echo "github packages: gem $(basename "$GEMFILE") published"
        else
          echo "note: github packages gem push failed for $spec; continuing"
        fi
        rm -f "$GEMFILE"
      else
        echo "note: gem build failed for $spec; continuing"
      fi
    done
  fi
else
  echo "note: github packages mirrors skipped (no gh token)"
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
# 4b. Registry workflows (NuGet / Maven Central): the public
#     repo's Trusted-Publishing / Portal-API workflows are the
#     primary publish path, so dispatch and await them here —
#     a release is not done until they report. Best-effort:
#     failures are loud notes, never a failed release.
# ------------------------------------------------------------------
NPM_OK="${NPM_OK:-0}"; PYPI_OK="${PYPI_OK:-0}"
NUGET_OK=0; MAVEN_OK=0; MAVEN_GH_OK=0; PUBDEV_OK=0; CRATES_OK=0; RUBYGEMS_OK=0; LUAROCKS_OK=0; JSR_OK=0
for wf in publish-npm publish-nuget publish-maven publish-maven-github publish-pubdev publish-crates publish-rubygems publish-luarocks publish-jsr; do
  if [ "$wf" = publish-maven ] && [ "${SKIP_CENTRAL:-}" = 1 ]; then
    echo "note: Maven Central dispatch skipped (SKIP_CENTRAL=1); sync Central in its weekly slot"
    continue
  fi
  # pub.dev automated publishing only accepts OIDC tokens issued
  # for a git tag matching v{{version}}; dispatch from the release
  # tag (created above), not the default branch.
  REF_ARGS=""
  [ "$wf" = publish-pubdev ] && REF_ARGS="--ref $VERSION"
  if gh workflow run "$wf.yml" --repo "$REPO" $REF_ARGS >/dev/null 2>&1; then
    sleep 5
    RUN_ID="$(gh run list --repo "$REPO" --workflow "$wf.yml" --limit 1 --json databaseId -q '.[0].databaseId' 2>/dev/null)"
    if [ -n "$RUN_ID" ] && gh run watch "$RUN_ID" --repo "$REPO" --exit-status >/dev/null 2>&1; then
      echo "registry workflow $wf: succeeded (run $RUN_ID)"
      [ "$wf" = publish-npm ] && NPM_OK=1
      [ "$wf" = publish-nuget ] && NUGET_OK=1
      [ "$wf" = publish-maven ] && MAVEN_OK=1
      [ "$wf" = publish-maven-github ] && MAVEN_GH_OK=1
      [ "$wf" = publish-pubdev ] && PUBDEV_OK=1
      [ "$wf" = publish-crates ] && CRATES_OK=1
      [ "$wf" = publish-rubygems ] && RUBYGEMS_OK=1
      [ "$wf" = publish-luarocks ] && LUAROCKS_OK=1
      [ "$wf" = publish-jsr ] && JSR_OK=1
    else
      echo "note: registry workflow $wf did not succeed (run ${RUN_ID:-unknown}); continuing"
    fi
  else
    echo "note: could not dispatch $wf workflow; continuing"
  fi
done

# ------------------------------------------------------------------
# 4c. Changelog bookkeeping: mark this version published in
#     the private repo (the export already shipped without
#     the note, as before). Best-effort; runs only from a
#     private-repo checkout with the version header present.
# ------------------------------------------------------------------
if [ -f CHANGELOG.md ] && git rev-parse --git-dir >/dev/null 2>&1 \
   && grep -q "^## $VERSION — " CHANGELOG.md \
   && ! grep -q "^## $VERSION — .*published" CHANGELOG.md; then
  CHANNELS="GitHub"
  [ "$NPM_OK" = 1 ] && CHANNELS="$CHANNELS/npm"
  [ "$PYPI_OK" = 1 ] && CHANNELS="$CHANNELS/PyPI"
  CHANNELS="$CHANNELS/GHCR"
  [ "$NUGET_OK" = 1 ] && CHANNELS="$CHANNELS/NuGet"
  [ "$MAVEN_OK" = 1 ] && CHANNELS="$CHANNELS/Maven Central"
  [ "$MAVEN_GH_OK" = 1 ] && CHANNELS="$CHANNELS/GitHub Maven"
  [ "$PUBDEV_OK" = 1 ] && CHANNELS="$CHANNELS/pub.dev"
  [ "$CRATES_OK" = 1 ] && CHANNELS="$CHANNELS/crates.io"
  [ "$RUBYGEMS_OK" = 1 ] && CHANNELS="$CHANNELS/RubyGems"
  [ "$LUAROCKS_OK" = 1 ] && CHANNELS="$CHANNELS/LuaRocks"
  [ "$JSR_OK" = 1 ] && CHANNELS="$CHANNELS/JSR"
  sed -i "s|^## $VERSION — \(.*\)|## $VERSION — \1 (published to $CHANNELS)|" CHANGELOG.md
  git add CHANGELOG.md
  if git -c user.name="John Davis" -c user.email="jdavis@pcprogramming.com" \
       commit -m "CHANGELOG: $VERSION published to $CHANNELS" >/dev/null 2>&1; then
    git push origin HEAD >/dev/null 2>&1 \
      && echo "changelog: $VERSION marked published ($CHANNELS) and pushed" \
      || echo "note: changelog commit made but push failed; push manually"
  else
    echo "note: changelog update skipped (nothing to commit)"
  fi
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
