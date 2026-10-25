"""BDD scenarios over the WebRTC-Direct sidecar transport.

Same generated scenario table as test_bdd.py, but the Python
client+server run over the real WebRTC stack: two `direct_sidecar`
processes (Rust) own DTLS/SCTP, one listening, one dialing by
multiaddr; Python only speaks length-prefixed TCP to its local
sidecar (`grpcdc.SidecarTransport`). This is the user-visible
transport-swap claim: one table, every transport.
"""

import os
import socket
import subprocess
import sys
import threading
import unittest

sys.path.insert(0, os.path.dirname(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "examples"))

import grpcdc
import echo_grpc_dc
from echo_pb import EchoRequest, EchoResponse
from echo_service import EchoService

from bdd_scenarios_generated import SCENARIOS
from test_sidecar_direct import SIDECAR, free_port, read_line


def req(message, count=0):
    return EchoRequest(message=message, count=count)


class TestBddSidecar(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not os.path.exists(SIDECAR):
            subprocess.run(
                ["cargo", "build", "--example", "direct_sidecar"],
                cwd=os.path.join(os.path.dirname(__file__), "..", "..", "webrtc", "rust"),
                check=True,
                capture_output=True,
                timeout=600,
            )

    def setUp(self):
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

        threading.Thread(target=serve, daemon=True).start()

        self.listen_proc = subprocess.Popen(
            [SIDECAR, "listen", "--udp", "127.0.0.1:0", "--tcp", f"127.0.0.1:{lang_port}"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
        multiaddr = read_line(self.listen_proc, "MULTIADDR").split(" ", 1)[1]

        # Python client behind sidecar `dial`.
        client_port = free_port()
        self.dial_proc = subprocess.Popen(
            [SIDECAR, "dial", "--multiaddr", multiaddr, "--tcp", f"127.0.0.1:{client_port}"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
        read_line(self.dial_proc, "TCP")
        self.channel = grpcdc.Channel(
            grpcdc.SidecarTransport.connect("127.0.0.1", client_port)
        )
        self.client = echo_grpc_dc.EchoClient(self.channel)
        self.listen_sock = listen_sock

    def tearDown(self):
        self.dial_proc.terminate()
        self.listen_proc.terminate()
        self.listen_sock.close()

    def test_scenarios(self):
        for (name, kind, messages, count, path, metadata,
             expect_message, expect_num, expect_status) in SCENARIOS:
            with self.subTest(scenario=name):
                self.run_scenario(kind, messages, count, path, metadata,
                                  expect_message, expect_num, expect_status)

    def run_scenario(self, kind, messages, count, path, metadata,
                     expect_message, expect_num, expect_status):
        if kind == "unary-trailer":
            stream = self.channel.unary_stream(
                "/echo.Echo/Unary", req(messages[0]),
                {"x-echo-trailer": metadata})
            resp = stream.recv(EchoResponse())
            self.assertEqual(resp.message, expect_message)
            self.assertEqual(resp.index, expect_num)
            with self.assertRaises(EOFError):
                stream.recv(EchoResponse())
            self.assertEqual(
                stream.trailers.get("x-echo-trailer"), metadata)
        elif kind == "unary":
            md = {"x-echo": metadata} if metadata else None
            if expect_status >= 0:
                with self.assertRaises(grpcdc.StatusError) as cm:
                    self.client.Unary(req(messages[0]), metadata=md)
                self.assertEqual(cm.exception.code, expect_status)
            else:
                resp = self.client.Unary(req(messages[0]), metadata=md)
                self.assertEqual(resp.message, expect_message)
                self.assertEqual(resp.index, expect_num)
        elif kind == "server-stream":
            responses = list(self.client.ServerStream(req(messages[0], count)))
            self.assertEqual(len(responses), expect_num)
            for i, resp in enumerate(responses):
                self.assertEqual(resp.message, expect_message)
                self.assertEqual(resp.index, i)
        elif kind == "client-stream":
            resp = self.client.ClientStream([req(m) for m in messages])
            self.assertEqual(resp.message, expect_message)
            self.assertEqual(resp.index, expect_num)
        elif kind == "bidi":
            responses = list(self.client.Bidi([req(m) for m in messages]))
            self.assertEqual(len(responses), expect_num)
            for i, resp in enumerate(responses):
                self.assertEqual(resp.message, messages[i])
                self.assertEqual(resp.index, i)
        elif kind == "server-stream-fail":
            with self.assertRaises(grpcdc.StatusError) as cm:
                list(self.client.ServerStream(req(messages[0], count)))
            self.assertEqual(cm.exception.code, expect_status)
        elif kind == "bidi-fail":
            with self.assertRaises(grpcdc.StatusError) as cm:
                list(self.client.Bidi([req(m) for m in messages]))
            self.assertEqual(cm.exception.code, expect_status)
        elif kind == "deadline":
            delayed = EchoRequest(message=messages[0], count=0, delay_ms=count)
            with self.assertRaises(grpcdc.StatusError) as cm:
                self.client.Unary(delayed, timeout=0.1)
            self.assertEqual(cm.exception.code, expect_status)
        elif kind == "cancel":
            stream = self.channel.server_stream(
                "/echo.Echo/ServerStream", req(messages[0], count), None, None)
            first = EchoResponse()
            stream.recv(first)
            self.assertEqual(first.message, expect_message or messages[0])
            self.channel.cancel(stream)
            terminated = False
            for _ in range(count + 2):
                try:
                    stream.recv(EchoResponse())
                except (EOFError, grpcdc.StatusError):
                    terminated = True
                    break
            self.assertTrue(terminated, "stream did not terminate after cancel")
        elif kind == "raw-unary":
            with self.assertRaises(grpcdc.StatusError) as cm:
                self.channel.unary(path, req(messages[0]), EchoResponse())
            self.assertEqual(cm.exception.code, expect_status)
        else:
            self.fail(f"unknown bdd kind: {kind}")


if __name__ == "__main__":
    unittest.main()
