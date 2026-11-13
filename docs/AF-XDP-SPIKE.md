# AF_XDP spike: rendezvous/Direct listener datagram path

Status: **spike only — opt-in, never default.** The portable
UDP socket remains the listener's default and fallback. This
document records what was built, what was measured, and what
remains unproven.

## Question

The rendezvous/Direct listener owns one UDP socket and demuxes
peers by ICE ufrag / source address. Would an AF_XDP socket
(XSK: UMEM frames fed straight into the same demux) move
packet rates enough to matter at gRPC message rates, where
DTLS/SCTP crypto and copying dominate?

Working hypothesis (unproven): no material gain below roughly
100k pps.

## What exists

[webrtc/rust/examples/af_xdp_spike.rs](../webrtc/rust/examples/af_xdp_spike.rs)
(zero new dependencies — the syscalls are `extern "C"`
declarations against the libc every std binary links):

1. **UDP baseline** — loopback datagram throughput using the
   same `recvmsg`-style socket calls the listener uses.
2. **XDP probe** — `socket(AF_XDP)` → `XDP_UMEM_REG` (one
   anonymous mmap arena, 4096 × 2048 B frames) → ring mmaps
   (`XDP_MMAP_OFFSETS`) → `bind(iface, queue)`, reporting the
   stage and errno where it stops.

## Measured (2026-11-12, CI container, loopback, 200 B datagrams)

- UDP baseline: ~759k datagrams/s sent, ~758k/s received over
  2 s. Even the portable path's loopback ceiling is far above
  gRPC message rates, which supports (does not prove) the
  hypothesis.
- XDP probe: stops at `socket(AF_XDP): Socket type not
  supported (os error 94)` in the CI container kernel.
  AF_XDP requires a kernel with `CONFIG_XDP_SOCKETS`, plus
  `CAP_NET_ADMIN`-class privileges and a real driver queue to
  bind — none of which a default container provides.

## What a real measurement needs

Run the spike on a host (or a privileged, host-network
container) with a real NIC queue:

```sh
cd webrtc/rust
cargo build --example af_xdp_spike
./target/debug/examples/af_xdp_spike eth0 0 5
```

Only after the probe binds does packet-path integration make
sense: NIC queue → UMEM frames → the existing ufrag/source
demux → ICE/DTLS/SCTP unchanged, behind a feature flag, with
the UDP path kept as fallback. If host numbers still show
DTLS/SCTP dominating, the correct outcome is to delete the
spike and keep the portable socket — that result is a valid
spike conclusion, not a failure.

## Integration point (if ever)

`dc_webrtc::rendezvous::RendezvousListener` socket ownership
(the Rust stack only). No other stack, and no default
configuration, changes.
