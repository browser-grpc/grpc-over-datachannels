"""Loopback end-to-end: all four shapes, error status, metadata."""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "examples"))

import grpcdc
import echo_grpc_dc
from echo_pb import EchoRequest
from echo_service import EchoService


def req(message, count=0):
    return EchoRequest(message=message, count=count)


class TestLoopback(unittest.TestCase):
    def setUp(self):
        a, b = grpcdc.memory_transport_pair()
        server = grpcdc.Server()
        echo_grpc_dc.register_echo_server(server, EchoService())
        server.serve_transport(b)
        self.client = echo_grpc_dc.EchoClient(grpcdc.Channel(a))

    def test_unary(self):
        resp = self.client.Unary(req("hello"))
        self.assertEqual(resp.message, "echo: hello")
        self.assertEqual(resp.index, 0)

    def test_server_stream(self):
        responses = list(self.client.ServerStream(req("tick", 3)))
        self.assertEqual([r.index for r in responses], [0, 1, 2])
        self.assertTrue(all(r.message == "tick" for r in responses))

    def test_client_stream(self):
        resp = self.client.ClientStream([req("a"), req("b"), req("c")])
        self.assertEqual(resp.message, "a+b+c")
        self.assertEqual(resp.index, 3)

    def test_bidi(self):
        responses = list(self.client.Bidi([req("x"), req("y")]))
        self.assertEqual([r.message for r in responses], ["x", "y"])
        self.assertEqual([r.index for r in responses], [0, 1])

    def test_error_status(self):
        with self.assertRaises(grpcdc.StatusError) as cm:
            self.client.Unary(req("fail"))
        self.assertEqual(cm.exception.code, 3)  # INVALID-ARGUMENT

    def test_metadata(self):
        resp = self.client.Unary(req("hello"), metadata={"x-echo": "meta"})
        self.assertEqual(resp.message, "echo: hello [meta]")


if __name__ == "__main__":
    unittest.main()
