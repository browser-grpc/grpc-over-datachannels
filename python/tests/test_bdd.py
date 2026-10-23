"""BDD: interprets the generated behavior scenarios.

bdd_scenarios_generated.py is generated from the BDD specification; the
prose lives in BDD.md. The scenarios run against a loopback
client+server — they are the executable examples, so documentation
cannot drift from behavior.
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "examples"))

import grpcdc
import echo_grpc_dc
from echo_pb import EchoRequest, EchoResponse
from echo_service import EchoService

from bdd_scenarios_generated import SCENARIOS


def req(message, count=0):
    return EchoRequest(message=message, count=count)


class TestBdd(unittest.TestCase):
    def setUp(self):
        a, b = grpcdc.memory_transport_pair()
        server = grpcdc.Server()
        echo_grpc_dc.register_echo_server(server, EchoService())
        server.serve_transport(b)
        self.channel = grpcdc.Channel(a)
        self.client = echo_grpc_dc.EchoClient(self.channel)

    def test_scenarios(self):
        for (name, kind, messages, count, path, metadata,
             expect_message, expect_num, expect_status) in SCENARIOS:
            with self.subTest(scenario=name):
                self.run_scenario(kind, messages, count, path, metadata,
                                  expect_message, expect_num, expect_status)

    def run_scenario(self, kind, messages, count, path, metadata,
                     expect_message, expect_num, expect_status):
        if kind == "unary":
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
