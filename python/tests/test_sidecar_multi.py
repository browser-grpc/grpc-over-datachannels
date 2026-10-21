"""Multiple concurrent connections through one pair of sidecars.

One Rust `direct_sidecar listen` and one `direct_sidecar dial`
must carry several simultaneous Direct sessions: the sidecars
spawn a bridge thread per connection, the Python server accepts
a loop of framed TCP connections (one thread each), and three
Python clients call concurrently through the single dial
sidecar's TCP port.
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
from test_sidecar_direct import ROOT, SIDECAR, free_port, read_line


class TestSidecarMulti(unittest.TestCase):
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

    def test_three_concurrent_clients_one_sidecar_pair(self):
        lang_port = free_port()
        listen_sock = socket.socket()
        listen_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listen_sock.bind(("127.0.0.1", lang_port))
        listen_sock.listen(8)

        server = grpcdc.Server()
        echo_grpc_dc.register_echo_server(server, EchoService())

        def serve_loop():
            while True:
                try:
                    conn, _ = listen_sock.accept()
                except OSError:
                    return
                threading.Thread(
                    target=server.serve_transport,
                    args=(grpcdc.SidecarTransport.from_socket(conn),),
                    daemon=True,
                ).start()

        threading.Thread(target=serve_loop, daemon=True).start()

        listen_proc = subprocess.Popen(
            [SIDECAR, "listen", "--udp", "127.0.0.1:0", "--tcp", f"127.0.0.1:{lang_port}"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
        try:
            multiaddr = read_line(listen_proc, "MULTIADDR").split(" ", 1)[1]
            client_port = free_port()
            dial_proc = subprocess.Popen(
                [SIDECAR, "dial", "--multiaddr", multiaddr, "--tcp", f"127.0.0.1:{client_port}"],
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
            )
            try:
                read_line(dial_proc, "TCP")
                results = {}
                errors = {}

                def call(i):
                    try:
                        client = echo_grpc_dc.EchoClient(
                            grpcdc.Channel(
                                grpcdc.SidecarTransport.connect("127.0.0.1", client_port)
                            )
                        )
                        resp = client.Unary(EchoRequest(message=f"hello-{i}", count=0))
                        results[i] = resp.message
                        stream = list(
                            client.ServerStream(EchoRequest(message="tick", count=3))
                        )
                        results[(i, "stream")] = [r.index for r in stream]
                    except Exception as e:  # noqa: BLE001 - reported below
                        errors[i] = e

                threads = [threading.Thread(target=call, args=(i,)) for i in range(3)]
                for t in threads:
                    t.start()
                for t in threads:
                    t.join(timeout=60)
                self.assertEqual(errors, {})
                for i in range(3):
                    self.assertEqual(results[i], f"echo: hello-{i}")
                    self.assertEqual(results[(i, "stream")], [0, 1, 2])
            finally:
                dial_proc.terminate()
        finally:
            listen_proc.terminate()
            listen_sock.close()


if __name__ == "__main__":
    unittest.main()
