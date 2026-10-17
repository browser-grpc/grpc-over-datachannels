#!/bin/sh
# build-racket-wasm.sh — reproducible build of the Racket/Wasm
# runtime the web app uses to run the real protoc plugins
# in-browser (see docs in webapp/racket/). This is the scripted
# form of a spike-validated manual setup; every stage is skipped
# when its output already exists, so warm re-runs are fast and a
# cold run takes ~45 minutes (host Chez + host Racket bootstrap,
# then the Emscripten cross-build).
#
#   scripts/build-racket-wasm.sh [output-dir]
#
# Output (default webapp/assets/racket): racket-web.js,
# racket-web.wasm, racket-web.data, share.data, share.data.js,
# shell-worker.js. The tree is a build artifact -- never commit it.
#
# Toolchain facts that are load-bearing (all spike-measured):
#   * Emscripten must be 5.0.7. 6.0.12 links fine but the runtime
#     dies in ffi_call_js ("Cannot convert N to a BigInt").
#   * Host Chez and host Racket are built from the backend's
#     pinned upstream tree; a release Racket (e.g. distro 9.2)
#     cannot read the version-stamped xpatch boot files.
#   * Chez pb boot files are not in git; the matching set ships in
#     the Racket 9.3 source tarball (Chez 0a050001) and the Racket
#     build additionally fetches per-machine boots from racket/pb.
#   * Chez's kernel wants ncurses + X11 headers/libs at build
#     time. In Docker, apt provides them; on a bare host this
#     script extracts .debs into the work dir instead of sudo.
set -eu

BACKEND_REPO=https://github.com/bradlord/racket-wasm-backend.git
BACKEND_SHA=411393882a1e9d726edc5dbc230b24f96d335398
EMSDK_VERSION=5.0.7
PB_BRANCH=v10.5.0-pre-release.1-1
RACKET_SRC_URL=https://download.racket-lang.org/installers/9.3/racket-9.3-src.tgz

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK=${RACKET_WASM_WORK:-/tmp/grpc-dc-racket-wasm}
OUT=${1:-"$REPO_ROOT/webapp/assets/racket"}
APP_DIR="$REPO_ROOT/webapp/racket"
JOBS=${JOBS:-8}

mkdir -p "$WORK" "$OUT"
say() { printf '==> %s\n' "$*"; }

# --- 0. host tools ---------------------------------------------------
command -v git >/dev/null || { echo "git required" >&2; exit 1; }
command -v cc >/dev/null || { echo "cc required" >&2; exit 1; }
command -v racket >/dev/null || { echo "racket (any recent) required on PATH to drive the orchestrator" >&2; exit 1; }

# --- 1. emsdk ---------------------------------------------------------
if [ -z "${EMSDK:-}" ]; then
  if [ ! -d "$WORK/emsdk" ]; then
    say "cloning emsdk"
    git clone --quiet --depth 1 https://github.com/emscripten-core/emsdk.git "$WORK/emsdk"
  fi
  if [ ! -x "$WORK/emsdk/upstream/emscripten/emcc" ]; then
    say "installing emscripten $EMSDK_VERSION (large download)"
    (cd "$WORK/emsdk" && ./emsdk install "$EMSDK_VERSION" >/dev/null)
  fi
  (cd "$WORK/emsdk" && ./emsdk activate "$EMSDK_VERSION" >/dev/null)
  EMSDK="$WORK/emsdk"
  EM_CONFIG="$WORK/emsdk/.emscripten"
  export EMSDK EM_CONFIG
fi
PATH="$EMSDK:$EMSDK/upstream/emscripten:$PATH"
export PATH
emcc --version | head -1 | grep -q "$EMSDK_VERSION" \
  || { echo "emscripten $EMSDK_VERSION required (found: $(emcc --version | head -1))" >&2; exit 1; }

# --- 2. backend clone + upstream sync --------------------------------
BACKEND="$WORK/backend"
if [ ! -d "$BACKEND/.git" ]; then
  say "cloning racket-wasm-backend@$BACKEND_SHA"
  git clone --quiet "$BACKEND_REPO" "$BACKEND"
  (cd "$BACKEND" && git checkout --quiet "$BACKEND_SHA")
fi
CLONE="$BACKEND/.work/racket"
if [ ! -d "$CLONE/racket/src/ChezScheme" ]; then
  say "syncing pinned upstream racket tree"
  (cd "$BACKEND" && racket build/main.rkt sync && racket build/main.rkt apply)
fi
CHEZ="$CLONE/racket/src/ChezScheme"

# --- 3. Chez pb boot files -------------------------------------------
if [ ! -f "$CHEZ/boot/pb/scheme.boot" ]; then
  say "seeding Chez pb boot files from Racket 9.3 source tarball"
  if [ ! -f "$WORK/racket-9.3-src.tgz" ]; then
    curl -sL -o "$WORK/racket-9.3-src.tgz" "$RACKET_SRC_URL"
  fi
  tar -xzf "$WORK/racket-9.3-src.tgz" -C "$WORK" racket-9.3/src/ChezScheme/boot
  mkdir -p "$CHEZ/boot"
  cp -r "$WORK/racket-9.3/src/ChezScheme/boot/pb" "$CHEZ/boot/pb"
fi

# --- 4. ncurses/X11 headers + libs (no sudo) --------------------------
HDR="$WORK/headers"
LIB="$WORK/stublib"
mkdir -p "$HDR" "$LIB"
if [ ! -f /usr/include/curses.h ] && [ ! -f "$HDR/curses.h" ]; then
  say "extracting ncurses/X11 dev packages (no sudo)"
  (cd "$WORK" && apt-get download libncurses-dev libx11-dev x11proto-dev >/dev/null 2>&1) \
    || { echo "apt-get download failed; install libncurses-dev libx11-dev x11proto-dev" >&2; exit 1; }
  for deb in "$WORK"/*.deb; do dpkg-deb -x "$deb" "$WORK/debroot"; done
  cp -r "$WORK/debroot/usr/include/." "$HDR/"
fi
if [ ! -e /usr/lib/x86_64-linux-gnu/libncurses.so ] && [ ! -e /usr/lib/aarch64-linux-gnu/libncurses.so ]; then
  # Runtime .so.6 exists without the dev symlink; give the linker
  # a script that pulls in tinfo (setupterm lives there).
  NC6=$(ls /usr/lib/*/libncurses.so.6 2>/dev/null | head -1)
  TI6=$(ls /usr/lib/*/libtinfo.so.6 2>/dev/null | head -1)
  [ -n "$NC6" ] && printf 'INPUT(%s %s)\n' "$NC6" "$TI6" > "$LIB/libncurses.so"
fi
export LIBRARY_PATH="$LIB${LIBRARY_PATH:+:$LIBRARY_PATH}"

# --- 5. host Chez ------------------------------------------------------
SCHEME_BIN="$CHEZ/tarm64le/bin/tarm64le/scheme"
if [ "$(uname -m)" != "aarch64" ] && [ "$(uname -m)" != "arm64" ]; then
  SCHEME_BIN=$(ls "$CHEZ"/t*/bin/*/scheme 2>/dev/null | head -1 || true)
fi
if [ -z "${SCHEME_BIN:-}" ] || [ ! -x "$SCHEME_BIN" ]; then
  say "building host Chez (stage 0)"
  (cd "$CHEZ" && ./configure --threads >/dev/null)
  for cfg in "$CHEZ"/*/Mf-config; do
    [ -f "$cfg" ] || continue
    if [ -d "$HDR" ]; then
      sed -i "s|^CPPFLAGS=.*|CPPFLAGS=-I$HDR -I$HDR/ncursesw|" "$cfg"
    fi
  done
  (cd "$CHEZ" && make -j"$JOBS" >/dev/null)
  SCHEME_BIN=$(ls "$CHEZ"/t*/bin/*/scheme | head -1)
fi
"$SCHEME_BIN" --version >/dev/null
say "host Chez: $SCHEME_BIN"

# pb boots as a git checkout (the Racket build fetches from it)
if [ ! -d "$CHEZ/boot/pb/.git" ]; then
  say "cloning racket/pb boot files"
  rm -rf "$CHEZ/boot/pb"
  git clone --quiet --depth 1 -b "$PB_BRANCH" https://github.com/racket/pb "$CHEZ/boot/pb"
fi

# --- 6. host Racket (pinned tree) -------------------------------------
HOST_RACKET="$CLONE/racket/bin/racket"
if [ ! -x "$HOST_RACKET" ]; then
  say "building host Racket from pinned tree (long)"
  # The final package-install stage can fail against a moved-on
  # package catalog; the racket binary is what we need.
  (cd "$CLONE" && make -j"$JOBS" >/dev/null) || true
fi
[ -x "$HOST_RACKET" ] || { echo "host Racket build failed" >&2; exit 1; }
say "host Racket: $("$HOST_RACKET" --version)"

# --- 7. build the webapp runtime --------------------------------------
say "building webapp runtime (app $APP_DIR)"
(cd "$BACKEND" && racket build/main.rkt app "$APP_DIR")
cp "$APP_DIR/dist/racket-web.js" "$APP_DIR/dist/racket-web.wasm" \
   "$APP_DIR/dist/racket-web.data" "$APP_DIR/dist/share.data" \
   "$APP_DIR/dist/share.data.js" "$APP_DIR/dist/shell-worker.js" "$OUT/"
say "runtime assets in $OUT:"
du -sh "$OUT"
