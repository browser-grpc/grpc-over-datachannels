"""gRPC over WebRTC-Direct via the Rust sidecar, Python to Python.

Two `direct_sidecar` processes own the whole WebRTC stack: one
listens (Direct), one dials by multiaddr. The Python server and
client only speak length-prefixed TCP to their local sidecar
(`grpcdc.SidecarTransport`) -- this is the path every generated
language without a native stack uses to call the Rust impl.
"""

import os
import socket
import subprocess
import sys
import threading
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "examples"))

import grpcdc
import echo_grpc_dc
from echo_pb import EchoRequest
from echo_service import EchoService

ROOT = os.path.join(os.path.dirname(__file__), "..", "..")
SIDECAR = os.path.join(ROOT, "webrtc", "rust", "target", "debug", "examples", "direct_sidecar")


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def read_line(proc, needle, timeout=30):
    import queue

    lines = queue.Queue()
    threading.Thread(target=lambda: [lines.put(l) for l in proc.stdout], daemon=True).start()
    import time

    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            line = lines.get(timeout=max(0.1, deadline - time.time()))
        except queue.Empty:
            break
        if needle in line:
            return line.strip()
    raise AssertionError(f"sidecar did not print {needle!r}")


class TestSidecarDirect(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not os.path.exists(SIDECAR):
            subprocess.run(
                ["cargo", "build", "--example", "direct_sidecar"],
                cwd=os.path.join(ROOT, "webrtc", "rust"),
                check=True,
                capture_output=True,
                timeout=600,
            )

    def test_python_grpc_over_rust_webrtc_direct(self):
        # Python server behind sidecar `listen`.
        lang_port = free_port()
        listen_sock = socket.socket()
        listen_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listen_sock.bind(("127.0.0.1", lang_port))
        listen_sock.listen(1)

        server = grpcdc.Server()
        echo_grpc_dc.register_echo_server(server, EchoService())

        def serve():
            conn, _ = listen_sock.accept()
            server.serve_transport(grpcdc.SidecarTransport.from_socket(conn))

        server_thread = threading.Thread(target=serve, daemon=True)
        server_thread.start()

        listen_proc = subprocess.Popen(
            [SIDECAR, "listen", "--udp", "127.0.0.1:0", "--tcp", f"127.0.0.1:{lang_port}"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
        try:
            multiaddr = read_line(listen_proc, "MULTIADDR").split(" ", 1)[1]
            self.assertIn("/webrtc-direct/certhash/f", multiaddr)

            # Python client behind sidecar `dial`.
            client_port = free_port()
            dial_proc = subprocess.Popen(
                [SIDECAR, "dial", "--multiaddr", multiaddr, "--tcp", f"127.0.0.1:{client_port}"],
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
            )
            try:
                read_line(dial_proc, "TCP")
                client = echo_grpc_dc.EchoClient(
                    grpcdc.Channel(grpcdc.SidecarTransport.connect("127.0.0.1", client_port))
                )
                resp = client.Unary(EchoRequest(message="hello", count=0))
                self.assertEqual(resp.message, "echo: hello")
                responses = list(client.ServerStream(EchoRequest(message="tick", count=3)))
                self.assertEqual([r.index for r in responses], [0, 1, 2])
            finally:
                dial_proc.terminate()
        finally:
            listen_proc.terminate()
            listen_sock.close()


if __name__ == "__main__":
    unittest.main()
