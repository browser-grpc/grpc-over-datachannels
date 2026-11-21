#!/bin/sh
# Local pre-publish e2e for the `make release-public` exports.
#
# Before v0.44.0, exported-tree breakage (Dockerfiles missing
# the Rust core builds, Maven pins) was only discovered by the
# public repos' GitHub CI after the push — three fixup rounds.
# This gate runs each exported tree's own CI entry locally, in
# Docker, before scripts/release-push.sh may publish:
#
#   browser-grpc   docker/{rust,go,js,interop}.Dockerfile
#                  (subset: the language stacks whose export
#                  Dockerfiles broke in the v0.44 fixups; the
#                  full 16-language matrix still runs on
#                  GitHub post-push, watched by `make ci-status`)
#   kafka-proxy    docker/kafka-proxy-ci.Dockerfile
#   kafka-native   docker/kafka-native-ci.Dockerfile
#   eventbus       docker/eventbus-ci.Dockerfile
#   grpc-php, kafka-php, eventbus-php
#                  php -l over lib/ (their repos ship no tests)
#   examples       RELEASE.json sanity (docs-only tree; its
#                  link check needs the public site, post-push)
#
# Usage: scripts/release-e2e.sh [VERSION]
# (runs on the host: needs docker; php lint falls back to the
# CI image when the host has no php).
# On success writes release/.e2e-ok-<VERSION> with the export
# tree hash; release-push.sh refuses to publish without a
# stamp matching the current trees.
set -eu

VERSION="${1:-$(git describe --tags --abbrev=0 2>/dev/null || echo dev)}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

tree_hash() {
  # World-readable contents plus name+size for the 0600 test
  # key fixtures, so the hash is identical for any user.
  { find release/browser-grpc release/kafka-proxy release/kafka-native \
       release/eventbus release/grpc-php release/kafka-php \
       release/eventbus-php release/examples -type f -readable -print0 \
      | LC_ALL=C sort -z | xargs -0 sha256sum;
    find release/browser-grpc release/kafka-proxy release/kafka-native \
       release/eventbus release/grpc-php release/kafka-php \
       release/eventbus-php release/examples -type f ! -readable \
       -exec stat -c '%n %s' {} + | LC_ALL=C sort; } | sha256sum | cut -d' ' -f1
}

for tree in browser-grpc kafka-proxy kafka-native eventbus \
            grpc-php kafka-php eventbus-php examples; do
  [ -d "release/$tree" ] || {
    echo "release-e2e: no export at release/$tree; run: make release-public VERSION=$VERSION" >&2
    exit 1
  }
  # PHP trees carry no RELEASE.json (composer packages); the
  # browser-grpc stamp above covers their content via the tree
  # hash, so only RELEASE.json trees get a version check.
  if [ -f "release/$tree/RELEASE.json" ]; then
    grep -q "\"version\": \"$VERSION\"" "release/$tree/RELEASE.json" || {
      echo "release-e2e: release/$tree is not $VERSION; regenerate first" >&2
      exit 1
    }
  fi
done

run_lang_image() {
  tree="$1"; dockerfile="$2"; tag="$3"
  echo "== release-e2e: $tree ($dockerfile)"
  docker build -q -f "release/$tree/$dockerfile" -t "$tag" "release/$tree" >/dev/null
  docker run --rm "$tag"
}

# browser-grpc: the stacks that broke during the v0.44 publish.
for lang in rust go js; do
  run_lang_image browser-grpc "docker/$lang.Dockerfile" "grpc-dc-e2e-$lang"
done
run_lang_image browser-grpc docker/interop.Dockerfile grpc-dc-e2e-interop

# Satellite repos: their own CI Dockerfiles end to end.
run_lang_image kafka-proxy docker/kafka-proxy-ci.Dockerfile grpc-dc-e2e-kafka-proxy
run_lang_image kafka-native docker/kafka-native-ci.Dockerfile grpc-dc-e2e-kafka-native
run_lang_image eventbus docker/eventbus-ci.Dockerfile grpc-dc-e2e-eventbus

# PHP trees ship lib/ only: syntax-lint every file (host php,
# or the CI image's php when the host has none).
for tree in grpc-php kafka-php eventbus-php; do
  echo "== release-e2e: $tree (php -l)"
  if command -v php >/dev/null; then
    find "release/$tree/lib" -name '*.php' -print0 \
      | xargs -0 -n 1 php -l >/dev/null
  else
    docker run --rm -v "$ROOT":/work -w /work grpc-dc-ci sh -c \
      "find release/$tree/lib -name '*.php' -print0 | xargs -0 -n 1 php -l >/dev/null"
  fi
done

# examples is docs-only: RELEASE.json/version sanity above is
# its local gate (link check runs against the live site).
STAMP="release/.e2e-ok-$VERSION"
{
  echo "version: $VERSION"
  echo "tree-hash: $(tree_hash)"
  echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$STAMP"
echo "release-e2e: PASS ($STAMP)"
