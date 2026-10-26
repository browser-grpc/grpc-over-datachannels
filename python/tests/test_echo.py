"""Loopback end-to-end: all four shapes, error status, metadata."""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "examples"))

import time

import grpcdc
import echo_grpc_dc
from echo_pb import EchoRequest, EchoResponse
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

    def test_breaking_server_stream_stops_server(self):
        produced = []

        class CountingService(EchoService):
            def ServerStream(self, req, stream):
                for i in range(req.count):
                    produced.append(i)
                    stream.send(EchoResponse(message=req.message, index=i))
                    time.sleep(0.01)

        a, b = grpcdc.memory_transport_pair()
        server = grpcdc.Server()
        echo_grpc_dc.register_echo_server(server, CountingService())
        server.serve_transport(b)
        client = echo_grpc_dc.EchoClient(grpcdc.Channel(a))

        stream = client.ServerStream(req("tick", 1000))
        self.assertEqual(next(stream).index, 0)
        # Breaking iteration + dropping the stream must RST the
        # call so the server stops producing.
        stream.close()
        del stream
        time.sleep(0.15)
        settled = len(produced)
        time.sleep(0.15)
        self.assertEqual(len(produced), settled)
        self.assertLess(settled, 100)


if __name__ == "__main__":
    unittest.main()
