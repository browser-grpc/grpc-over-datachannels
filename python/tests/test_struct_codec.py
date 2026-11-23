"""Struct-codec negotiation: struct<->struct roundtrip, mismatch rejected, plain still works."""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "examples"))

import grpcdc
import echo_grpc_dc
from echo_pb import EchoRequest, EchoResponse
from echo_service import EchoService


def req(message, count=0):
    return EchoRequest(message=message, count=count)


def setup(client_struct, server_struct):
    a, b = grpcdc.memory_transport_pair()
    server = grpcdc.Server()
    server.set_struct_codec(server_struct)
    echo_grpc_dc.register_echo_server(server, EchoService())
    server.serve_transport(b)
    channel = grpcdc.Channel(a)
    channel.set_struct_codec(client_struct)
    return echo_grpc_dc.EchoClient(channel)


class TestStructCodec(unittest.TestCase):
    def test_struct_all_shapes(self):
        client = setup(True, True)
        resp = client.Unary(req("hello"))
        self.assertEqual(resp.message, "echo: hello")

        responses = list(client.ServerStream(req("tick", 3)))
        self.assertEqual([r.index for r in responses], [0, 1, 2])

        joined = client.ClientStream([req("a"), req("b")])
        self.assertEqual(joined.message, "a+b")

        echoed = list(client.Bidi([req("x"), req("y")]))
        self.assertEqual([r.message for r in echoed], ["x", "y"])

    def test_struct_magic_and_roundtrip(self):
        data = req("hello").marshal_struct()
        self.assertEqual(data[0:4], b"DCS1")
        back = EchoRequest()
        back.unmarshal_struct(data)
        self.assertEqual(back.message, "hello")

    def test_struct_client_vs_plain_server_unimplemented(self):
        client = setup(True, False)
        with self.assertRaises(grpcdc.StatusError) as cm:
            client.Unary(req("hello"))
        self.assertEqual(cm.exception.code, 12)  # UNIMPLEMENTED

    def test_plain_client_vs_struct_server(self):
        client = setup(False, True)
        resp = client.Unary(req("hello"))
        self.assertEqual(resp.message, "echo: hello")


if __name__ == "__main__":
    unittest.main()
