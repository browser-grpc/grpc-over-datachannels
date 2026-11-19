#!/bin/sh
# Run a command in the CI image with the workspace
# bind-mounted, WITHOUT creating root-owned files on the
# host: docker's default root user is what kept stamping
# release/webapp/target outputs root-owned after mounted
# runs. Always go through this wrapper for mounted runs:
#
#   scripts/ci-run.sh make release-public VERSION=v0.44.0
#   scripts/ci-run.sh bash -c 'cd go && go test .'
#
# - --user pins host uid/gid for everything the container
#   writes into the mount.
# - HOME=/tmp gives Go/dotnet writable homes (their first
#   runs otherwise fail on /.cache).
# - --ipc=host gives .NET its /dev/shm named mutexes.
# - GOFLAGS/safe.directory keep Go VCS stamping and git
#   commands working on the mounted tree.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec docker run --rm --ipc=host \
  --user "$(id -u):$(id -g)" \
  -e HOME=/tmp \
  -e GOFLAGS=-buildvcs=false \
  -e GIT_CONFIG_COUNT=1 \
  -e GIT_CONFIG_KEY_0=safe.directory \
  -e GIT_CONFIG_VALUE_0=/work \
  -v "$ROOT":/work -w /work \
  grpc-dc-ci "$@"
