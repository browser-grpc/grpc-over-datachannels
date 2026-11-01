#!/usr/bin/env python3
"""WebRTC-Direct Echo client in Python via the Rust sidecar.

Python (like every non-stack language here) reaches WebRTC through the
generated SidecarTransport: the Rust `direct_sidecar` owns the WebRTC
stack and bridges a local TCP socket to the DataChannel. Python code
only sees the generated gRPC runtime.

One-time setup (from the repo root):

    cargo build --manifest-path webrtc/rust/Cargo.toml --example direct_sidecar

Run the server (any language; Node shown), copy its MULTIADDR line,
then:

    webrtc/rust/target/debug/examples/direct_sidecar dial \\
        --multiaddr '/ip4/.../webrtc-direct/certhash/f...' --tcp 127.0.0.1:50061
    python3 examples/direct/python_client.py 127.0.0.1:50061

With TURN, add `--turn host:port --turn-user USER --turn-pass PASS` to
the sidecar dial command; the Python code does not change.
"""

import sys

sys.path.insert(0, "python")
sys.path.insert(0, "python/examples")

import grpcdc  # noqa: E402
import echo_grpc_dc  # noqa: E402
import echo_pb  # noqa: E402


def main() -> int:
    addr = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1:50061"
    host, _, port = addr.rpartition(":")
    channel = grpcdc.Channel(grpcdc.SidecarTransport.connect(host, int(port)))
    client = echo_grpc_dc.EchoClient(channel)

    unary = client.Unary(echo_pb.EchoRequest(message="hello direct"))
    print(f"unary -> {unary.message}")
    parts = [
        f"{resp.message}#{resp.index}"
        for resp in client.ServerStream(echo_pb.EchoRequest(message="tick", count=3))
    ]
    print(f"serverStream -> {' '.join(parts)}")
    print("direct-echo OK (python via sidecar)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
