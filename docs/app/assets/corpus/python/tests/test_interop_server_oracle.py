"""Interop oracle, Direction B: the OFFICIAL interop clients
(grpc-java TestServiceClient, grpc-go interop-client) run the
canonical cases against the generated Python TestService
server (tests/interop_service.py), reached over HTTP/2
through the Node ingress proxy -> WebRTC-Direct -> Rust
sidecar -> Python (the product proxy shape for languages
without a native stack). Skips when an oracle binary, Node,
or the sidecar is unavailable (Dockerfile.ci builds them).

Excluded (oracle/interop/README.md): auth, compression,
soak. cacheable_unary runs only under the Java client
(unsupported by the Go client).
"""

import os
import queue
import socket
import subprocess
import sys
import threading
import time
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "examples"))
sys.path.insert(0, os.path.dirname(__file__))

import grpcdc
import test_grpc_dc
from interop_service import TestServiceImpl

ROOT = os.path.join(os.path.dirname(__file__), "..", "..")
SIDECAR = os.path.join(
    ROOT, "webrtc", "rust", "target", "debug", "examples", "direct_sidecar"
)

CASES = [
    "empty_unary",
    "large_unary",
    "client_streaming",
    "server_streaming",
    "ping_pong",
    "empty_stream",
    "custom_metadata",
    "status_code_and_message",
    "special_status_message",
    "unimplemented_method",
    "unimplemented_service",
    "cancel_after_begin",
    "cancel_after_first_response",
    "timeout_on_sleeping_server",
]

# ORCA cases run only under the Go client: grpc-java's
# TestServiceClient fails them even against the upstream Go
# interop server (its per-RPC report capture comes back null).
GO_ONLY_CASES = ["orca_per_rpc", "orca_oob"]


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def read_line(proc, needle, timeout=60):
    lines = queue.Queue()
    threading.Thread(
        target=lambda: [lines.put(l) for l in proc.stdout], daemon=True
    ).start()
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            line = lines.get(timeout=max(0.1, deadline - time.time()))
        except queue.Empty:
            break
        if needle in line:
            return line.strip()
    raise AssertionError(f"process did not print {needle!r}")


def wait_for_port(port, timeout=60):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=1):
                return True
        except OSError:
            time.sleep(0.1)
    return False


def java_classpath(test):
    target = os.path.join(ROOT, "oracle", "java", "target")
    cp_file = os.path.join(target, "cp.txt")
    if not os.path.exists(cp_file) or not os.path.isdir(
        os.path.join(target, "classes")
    ):
        test.skipTest("java oracle not built (cd oracle/java && mvn package)")
    with open(cp_file) as f:
        return os.path.join(target, "classes") + ":" + f.read().strip()


class TestInteropServerOracle(unittest.TestCase):
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
        # Python TestService server behind the sidecar listener.
        cls.lang_port = free_port()
        cls.listen_sock = socket.socket()
        cls.listen_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        cls.listen_sock.bind(("127.0.0.1", cls.lang_port))
        cls.listen_sock.listen(1)
        server = grpcdc.Server()
        test_grpc_dc.register_test_service_server(server, TestServiceImpl())

        def serve():
            conn, _ = cls.listen_sock.accept()
            server.serve_transport(grpcdc.SidecarTransport.from_socket(conn))

        cls.server_thread = threading.Thread(target=serve, daemon=True)
        cls.server_thread.start()

        cls.sidecar = subprocess.Popen(
            [
                SIDECAR, "listen", "--udp", "127.0.0.1:0",
                "--tcp", f"127.0.0.1:{cls.lang_port}",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
        multiaddr = read_line(cls.sidecar, "MULTIADDR").split(" ", 1)[1]

        cls.http2_port = free_port()
        cls.proxy = subprocess.Popen(
            [
                "node", os.path.join(ROOT, "proxy", "grpc-dc-proxy.mjs"),
                "--dc-dial", multiaddr, "--http2", str(cls.http2_port),
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        if not wait_for_port(cls.http2_port):
            raise unittest.SkipTest("ingress proxy did not start")

    @classmethod
    def tearDownClass(cls):
        cls.proxy.terminate()
        cls.sidecar.terminate()
        cls.listen_sock.close()

    def run_java_client(self, test_case):
        cp = java_classpath(self)
        proc = subprocess.run(
            [
                "java", "-cp", cp,
                "io.grpc.testing.integration.TestServiceClient",
                "--server_host=127.0.0.1",
                f"--server_port={self.http2_port}",
                f"--test_case={test_case}",
                "--use_tls=false",
            ],
            capture_output=True,
            text=True,
            timeout=120,
        )
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("Test completed.", proc.stdout)

    def run_go_client(self, test_case):
        binary = os.path.join(ROOT, "oracle", "go-interop", "interop-client")
        if not os.path.exists(binary):
            self.skipTest("go interop client not built")
        args = [
            binary,
            "-server_host", "127.0.0.1",
            "-server_port", str(self.http2_port),
            "-test_case", test_case,
        ]
        if test_case.startswith("orca"):
            # ORCA cases run through the upstream test LB policy
            # that surfaces per-RPC load reports (interop_test.sh).
            args += [
                "-service_config_json",
                '{ "loadBalancingConfig": '
                '[{ "test_backend_metrics_load_balancer": {} }]}',
            ]
        proc = subprocess.run(
            args,
            capture_output=True,
            text=True,
            timeout=120,
        )
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)

    def test_java_client_cases(self):
        for test_case in CASES + ["cacheable_unary"]:
            with self.subTest(client="java", case=test_case):
                self.run_java_client(test_case)

    def test_go_client_cases(self):
        for test_case in CASES + GO_ONLY_CASES:
            with self.subTest(client="go", case=test_case):
                self.run_go_client(test_case)


if __name__ == "__main__":
    unittest.main()
