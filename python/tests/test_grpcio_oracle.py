"""Third Google reference implementation: the official Python
gRPC (grpcio) client runs canonical interop cases against the
generated Python TestService server, reached over HTTP/2
through the Node ingress proxy -> WebRTC-Direct -> Rust
sidecar (the same product proxy shape as
test_interop_server_oracle.py, whose official clients are
grpc-java and grpc-go).

grpcio stubs for the vendored grpc.testing protos are
generated with grpc_tools.protoc at setup (grpcio is a test
oracle only, never a runtime dependency; the CI image installs
it). Skips when a prerequisite is unavailable; hard-fails
instead when GRPC_DC_REQUIRE_ORACLE is set.
"""

import os
import socket
import subprocess
import sys
import tempfile
import threading
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "examples"))
sys.path.insert(0, os.path.dirname(__file__))

import grpcdc
import test_grpc_dc
import test_interop_server_oracle as _server_oracle
from interop_service import TestServiceImpl

ROOT = _server_oracle.ROOT
SIDECAR = _server_oracle.SIDECAR
free_port = _server_oracle.free_port
read_line = _server_oracle.read_line
wait_for_port = _server_oracle.wait_for_port


def _require_or_skip(reason):
    if os.environ.get("GRPC_DC_REQUIRE_ORACLE"):
        raise AssertionError(f"oracle required but unavailable: {reason}")
    raise unittest.SkipTest(reason)


def _gen_grpcio_stubs():
    from grpc_tools import protoc

    out = tempfile.mkdtemp(prefix="grpcio-stubs-")
    rc = protoc.main(
        [
            "grpc_tools.protoc",
            f"-I{os.path.join(ROOT, 'oracle', 'interop')}",
            f"--python_out={out}",
            f"--grpc_python_out={out}",
            "grpc/testing/test.proto",
            "grpc/testing/messages.proto",
            "grpc/testing/empty.proto",
        ]
    )
    if rc != 0:
        raise RuntimeError(f"grpc_tools.protoc failed: {rc}")
    # grpcio's `grpc` is a regular package, so the generated
    # grpc/testing tree cannot be found through it; register the
    # generated package in sys.modules explicitly.
    import types

    pkg = types.ModuleType("grpc.testing")
    pkg.__path__ = [os.path.join(out, "grpc", "testing")]
    sys.modules.setdefault("grpc.testing", pkg)
    sys.path.insert(0, out)
    from grpc.testing import empty_pb2, messages_pb2, test_pb2_grpc

    return empty_pb2, messages_pb2, test_pb2_grpc


class TestGrpcioOracle(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        try:
            import grpc  # noqa: F401
        except ImportError:
            _require_or_skip("grpcio not installed (CI image installs it)")
        try:
            cls.empty_pb2, cls.messages_pb2, cls.test_pb2_grpc = _gen_grpcio_stubs()
        except ImportError:
            _require_or_skip("grpcio-tools not installed (CI image installs it)")
        if not os.path.exists(SIDECAR):
            subprocess.run(
                ["cargo", "build", "--example", "direct_sidecar"],
                cwd=os.path.join(ROOT, "webrtc", "rust"),
                check=True,
                capture_output=True,
                timeout=600,
            )

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

        import grpc

        cls.channel = grpc.insecure_channel(f"127.0.0.1:{cls.http2_port}")
        grpc.channel_ready_future(cls.channel).result(timeout=30)
        cls.stub = cls.test_pb2_grpc.TestServiceStub(cls.channel)

    @classmethod
    def tearDownClass(cls):
        cls.channel.close()
        cls.proxy.terminate()
        cls.sidecar.terminate()
        cls.listen_sock.close()

    def test_empty_unary(self):
        resp = self.stub.EmptyCall(self.empty_pb2.Empty())
        self.assertIsInstance(resp, self.empty_pb2.Empty)

    def test_large_unary(self):
        m = self.messages_pb2
        req = m.SimpleRequest(
            response_size=314159,
            payload=m.Payload(body=b"\x00" * 271828),
        )
        resp = self.stub.UnaryCall(req)
        self.assertEqual(len(resp.payload.body), 314159)

    def test_client_streaming(self):
        m = self.messages_pb2
        reqs = (
            m.StreamingInputCallRequest(payload=m.Payload(body=b"\x00" * n))
            for n in (27182, 8, 1828, 45904)
        )
        resp = self.stub.StreamingInputCall(reqs)
        self.assertEqual(resp.aggregated_payload_size, 27182 + 8 + 1828 + 45904)

    def test_server_streaming(self):
        m = self.messages_pb2
        req = m.StreamingOutputCallRequest(
            response_parameters=[
                m.ResponseParameters(size=31415),
                m.ResponseParameters(size=9),
                m.ResponseParameters(size=2653),
            ]
        )
        sizes = [len(r.payload.body) for r in self.stub.StreamingOutputCall(req)]
        self.assertEqual(sizes, [31415, 9, 2653])

    def test_ping_pong(self):
        m = self.messages_pb2

        def gen():
            for size in (31415, 9, 2653, 58979):
                yield m.StreamingOutputCallRequest(
                    response_parameters=[m.ResponseParameters(size=size)]
                )

        sizes = [len(r.payload.body) for r in self.stub.FullDuplexCall(gen())]
        self.assertEqual(sizes, [31415, 9, 2653, 58979])

    def test_empty_stream(self):
        resps = list(self.stub.FullDuplexCall(iter([])))
        self.assertEqual(resps, [])

    def test_status_code_and_message(self):
        import grpc

        m = self.messages_pb2
        req = m.SimpleRequest(
            response_status=m.EchoStatus(code=2, message="test status message")
        )
        with self.assertRaises(grpc.RpcError) as ctx:
            self.stub.UnaryCall(req)
        self.assertEqual(ctx.exception.code(), grpc.StatusCode.UNKNOWN)
        self.assertIn("test status message", ctx.exception.details())

    def test_unimplemented_method(self):
        import grpc

        with self.assertRaises(grpc.RpcError) as ctx:
            self.stub.UnimplementedCall(self.empty_pb2.Empty())
        self.assertEqual(ctx.exception.code(), grpc.StatusCode.UNIMPLEMENTED)


if __name__ == "__main__":
    unittest.main()
