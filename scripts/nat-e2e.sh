#!/bin/sh
# Double-NAT end-to-end test: two peers in separate network
# namespaces behind separate full-cone kernel NATs,
# a STUN server on the "WAN" segment, real gRPC traffic (the
# generated JS Echo service: unary, server-stream, client-
# stream, bidi) across the NATs in BOTH directions:
#
#   run 1: A offers + gRPC client  ->  B answers + gRPC server
#   run 2: B offers + gRPC client  ->  A answers + gRPC server
#
# Nothing fakes candidates: each peer's host address lives on a
# private subnet the other side cannot route to (the WAN router
# deliberately has no routes into 192.168.0.0/16), so a working
# connection can only have used the srflx candidate its NAT
# produced. No TURN server exists here; if ICE cannot cross,
# the test fails loudly.
#
# Needs root netns privileges: run via `make test-nat-e2e`,
# which runs this script inside the CI image (root, NET_ADMIN).
# Kept OUT of the default gate for the same reason the live
# STUN test is: the sandbox must stay reproducible.
set -eu

SIG=/tmp/nat-e2e
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
NODE=${NODE:-node}

cleanup() {
  touch "$SIG/stop" "$SIG/stop-stun" 2>/dev/null || true
  sleep 1
  for ns in nsA nsB natA natB wan; do
    ip netns del "$ns" 2>/dev/null || true
  done
  if [ -n "${WORKDIR:-}" ]; then rm -rf "$WORKDIR"; fi
}
WORKDIR=$(mktemp -d /tmp/nat-e2e-procs.XXXXXX)
trap cleanup EXIT INT TERM

rm -rf "$SIG"; mkdir -p "$SIG"

# --- topology -------------------------------------------------
# nsA 192.168.1.10 -- natA (in .1.1, out 10.0.0.2) --+
#                                                    +-- wan 10.0.0.0/24, STUN 10.0.0.1
# nsB 192.168.2.10 -- natB (in .2.1, out 10.0.0.3) --+
for ns in nsA nsB natA natB wan; do ip netns add "$ns"; done
for ns in nsA nsB natA natB wan; do ip -n "$ns" link set lo up; done

link() { # link <nsA> <devA> <nsB> <devB> <addrA> <addrB>
  # Create under scratch names first (the container already
  # owns an eth0), rename as each end lands in its namespace.
  ip link add "zz$2" type veth peer name "zz$4"
  ip link set "zz$2" netns "$1"; ip link set "zz$4" netns "$3"
  ip -n "$1" link set "zz$2" name "$2"; ip -n "$3" link set "zz$4" name "$4"
  ip -n "$1" addr add "$5" dev "$2"; ip -n "$3" addr add "$6" dev "$4"
  ip -n "$1" link set "$2" up; ip -n "$3" link set "$4" up
}
link nsA eth0 natA lanA 192.168.1.10/24 192.168.1.1/24
link nsB eth0 natB lanB 192.168.2.10/24 192.168.2.1/24
# One subnet per WAN link (same address on both would send
# replies out the first link regardless of source).
link natA wanA wan ethA 10.0.0.2/24 10.0.0.1/24
link natB wanB wan ethB 10.1.0.2/24 10.1.0.1/24

ip -n nsA route add default via 192.168.1.1
ip -n nsB route add default via 192.168.2.1
ip -n natA route add default via 10.0.0.1
ip -n natB route add default via 10.1.0.1
# NOTE: wan has NO route into 192.168.0.0/16 -- unreachable
# host candidates on purpose; only srflx (10.0.0.2 / 10.0.0.3)
# can cross.

# Full-cone NATs (endpoint-independent mapping): the peer
# socket's fixed port 50000 is pinned 1:1 to the NAT's public
# address, so the srflx endpoint learned via STUN is exactly
# the endpoint the other peer must use. (Plain MASQUERADE on
# Linux allocates a different external port per destination --
# a symmetric NAT -- under which STUN traversal cannot work
# and TURN is the answer; that shape is covered by the
# direct-over-TURN tests.)
ip netns exec natA sysctl -qw net.ipv4.ip_forward=1
ip netns exec natA iptables -t nat -A POSTROUTING -o wanA -p udp -s 192.168.1.10 --sport 50000 -j SNAT --to-source 10.0.0.2:50000
ip netns exec natA iptables -t nat -A PREROUTING -i wanA -p udp -d 10.0.0.2 --dport 50000 -j DNAT --to-destination 192.168.1.10:50000
ip netns exec natA iptables -t nat -A POSTROUTING -o wanA -j MASQUERADE
ip netns exec natB sysctl -qw net.ipv4.ip_forward=1
ip netns exec natB iptables -t nat -A POSTROUTING -o wanB -p udp -s 192.168.2.10 --sport 50000 -j SNAT --to-source 10.1.0.2:50000
ip netns exec natB iptables -t nat -A PREROUTING -i wanB -p udp -d 10.1.0.2 --dport 50000 -j DNAT --to-destination 192.168.2.10:50000
ip netns exec natB iptables -t nat -A POSTROUTING -o wanB -j MASQUERADE
ip netns exec wan sysctl -qw net.ipv4.ip_forward=1

# --- processes ------------------------------------------------
ip netns exec wan "$NODE" "$ROOT/scripts/nat-peer.mjs" \
  --role stun --addr 10.0.0.1:3478 --signal-dir "$SIG" \
  >"$WORKDIR/stun.log" 2>&1 &
sleep 1

run_pair() { # run_pair <run> <offerNs> <answerNs>
  run=$1; offerNs=$2; answerNs=$3
  rm -f "$SIG"/offer.txt "$SIG"/answer.txt "$SIG"/done-* "$SIG"/result-*
  echo "nat-e2e run $run: $offerNs offers + gRPC client, $answerNs answers + gRPC server"
  ip netns exec "$answerNs" "$NODE" "$ROOT/scripts/nat-peer.mjs" \
    --role answer --grpc server --name "${answerNs}-srv" \
    --stun 10.0.0.1:3478 --signal-dir "$SIG" \
    >"$WORKDIR/$run-server.log" 2>&1 &
  ip netns exec "$offerNs" "$NODE" "$ROOT/scripts/nat-peer.mjs" \
    --role offer --grpc client --name "${offerNs}-cli" \
    --stun 10.0.0.1:3478 --signal-dir "$SIG" \
    >"$WORKDIR/$run-client.log" 2>&1 || true
  touch "$SIG/stop"; sleep 1; rm -f "$SIG/stop"
  for f in "$SIG"/result-*.json; do cat "$f"; echo; done
  grep -q '"ok": true' "$SIG/result-${offerNs}-cli.json" 2>/dev/null || {
    echo "nat-e2e run $run: CLIENT FAILED"
    echo "--- client log"; cat "$WORKDIR/$run-client.log"
    echo "--- server log"; cat "$WORKDIR/$run-server.log"
    echo "--- stun log"; cat "$WORKDIR/stun.log"
    exit 1
  }
  echo "nat-e2e run $run: OK"
}

run_pair 1 nsA nsB
run_pair 2 nsB nsA
echo "nat-e2e PASS: gRPC across two kernel NATs, both directions"
