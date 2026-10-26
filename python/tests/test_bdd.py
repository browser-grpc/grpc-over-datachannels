"""BDD: interprets the generated behavior scenarios.

bdd_scenarios_generated.py is generated from the BDD specification; the
prose lives in BDD.md. The scenarios run against a loopback
client+server — they are the executable examples, so documentation
cannot drift from behavior.
"""

import os
import sys
import time
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
        elif kind == "stream-break":
            # Dedicated counting server: abandoning the stream
            # (iterator close + drop, no explicit cancel) must
            # RST the call so the server stops producing.
            produced = []

            class CountingService(EchoService):
                def ServerStream(self, req_, stream):
                    for i in range(req_.count):
                        produced.append(i)
                        stream.send(
                            EchoResponse(message=req_.message, index=i))
                        time.sleep(0.01)

            a, b = grpcdc.memory_transport_pair()
            break_server = grpcdc.Server()
            echo_grpc_dc.register_echo_server(break_server, CountingService())
            break_server.serve_transport(b)
            break_client = echo_grpc_dc.EchoClient(grpcdc.Channel(a))
            stream = break_client.ServerStream(req(messages[0], count))
            first = next(stream)
            self.assertEqual(first.message, messages[0])
            # Natural abandonment: close the iterator and drop
            # it (no channel.cancel) so the call is RST.
            stream.close()
            del stream
            time.sleep(0.15)
            settled = len(produced)
            time.sleep(0.15)
            self.assertEqual(len(produced), settled)
            self.assertLess(settled, 50)
        elif kind == "raw-unary":
            with self.assertRaises(grpcdc.StatusError) as cm:
                self.channel.unary(path, req(messages[0]), EchoResponse())
            self.assertEqual(cm.exception.code, expect_status)
        else:
            self.fail(f"unknown bdd kind: {kind}")


if __name__ == "__main__":
    unittest.main()
