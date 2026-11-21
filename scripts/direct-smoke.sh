#!/bin/sh
# Smoke gate for the generated WebRTC-Direct examples
# (racket/direct-examples-gen.rkt): the Go example runs a real
# serve/dial roundtrip on localhost (unary + server-streaming,
# prints "direct-echo OK"); the other languages' examples are
# compile/syntax gated here and roundtrip in their suites and
# the WebRTC matrix. Zig's direct_echo is already compiled by
# `zig build` in test-zig (build.zig lists it as a target).
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "== direct examples: go serve/dial smoke"
cd go && go build -o build/direct_echo ./examples/direct_echo && cd ..
LOG="$(mktemp)"
go/build/direct_echo serve >"$LOG" 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null || true; rm -f "$LOG"' EXIT
ADDR=""
for _ in $(seq 1 75); do
  ADDR="$(sed -n 's/^MULTIADDR //p' "$LOG" | head -1)"
  [ -n "$ADDR" ] && break
  sleep 0.2
done
if [ -z "$ADDR" ]; then
  echo "direct smoke: server printed no MULTIADDR" >&2
  cat "$LOG" >&2
  exit 1
fi
go/build/direct_echo dial "$ADDR" | grep -q "direct-echo OK"
echo "direct-echo smoke OK"

echo "== direct examples: compile/syntax gates"
cd rust && cargo build --locked --features webrtc --example direct_echo 2>&1 | tail -1
cd "$ROOT"
(cd rust && cargo build --release)
cc -Ic -Ic/examples c/grpcdc/grpcdc.c c/grpcdc/memory_transport.c \
   c/grpcdc/sidecar_transport.c c/grpcdc/dynamic.c \
   c/examples/direct_echo.c -L rust/target/release -lgrpc_dc \
   -Wl,-rpath,"$ROOT/rust/target/release" -o c/build/direct_echo
cd cpp && g++ -std=c++17 -I. examples/direct_echo.cpp \
   -L ../rust/target/release -lgrpc_dc \
   -Wl,-rpath,"$ROOT/rust/target/release" -o build/direct_echo -pthread && cd ..
LUA_BIN="${LUA:-lua5.4}"
"$LUA_BIN" -e "assert(loadfile('lua/examples/direct_echo.lua'))"
php -l php/examples/direct_echo.php >/dev/null
ruby -c ruby/examples/direct_echo.rb >/dev/null
echo "direct examples: all gates OK"
