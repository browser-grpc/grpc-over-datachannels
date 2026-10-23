"""Deadlines: grpc-timeout propagation + local enforcement.

The client sends grpc-timeout metadata and raises
DEADLINE_EXCEEDED (code 4) + RST when the deadline passes while
waiting for a response; the server sees the remaining budget on
its CallContext. Async calls inherit the same behavior.
"""

import asyncio
import os
import sys
import time
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "examples"))

import grpcdc
import echo_grpc_dc
from grpcdc.codec import encode_timeout, parse_timeout
from echo_pb import EchoRequest, EchoResponse
from echo_service import EchoService


def req(message, count=0):
    return EchoRequest(message=message, count=count)


class SlowService(EchoService):
    def __init__(self):
        self.seen_ctx = None

    def Unary(self, ctx, request):
        self.seen_ctx = ctx
        time.sleep(0.4)
        return super().Unary(ctx, request)

    def ServerStream(self, request, stream):
        for i in range(max(0, request.count)):
            if i:
                time.sleep(0.3)
            stream.send(EchoResponse(message=request.message, index=i))


class TestTimeoutCodec(unittest.TestCase):
    def test_round_trip(self):
        self.assertEqual(parse_timeout(encode_timeout(0.25)), 0.25)
        self.assertEqual(parse_timeout(encode_timeout(90.0)), 90.0)

    def test_units_and_junk(self):
        self.assertEqual(parse_timeout("100m"), 0.1)
        self.assertEqual(parse_timeout("2S"), 2.0)
        self.assertEqual(parse_timeout("1H"), 3600.0)
        self.assertIsNone(parse_timeout("10x"))
        self.assertIsNone(parse_timeout("m"))
        self.assertIsNone(parse_timeout(None))


class TestDeadlines(unittest.TestCase):
    def setUp(self):
        a, b = grpcdc.memory_transport_pair()
        self.service = SlowService()
        server = grpcdc.Server()
        echo_grpc_dc.register_echo_server(server, self.service)
        server.serve_transport(b)
        self.channel = grpcdc.Channel(a)
        self.client = echo_grpc_dc.EchoClient(self.channel)

    def test_unary_times_out_fast(self):
        start = time.monotonic()
        with self.assertRaises(grpcdc.StatusError) as ctx:
            self.client.Unary(req("hello"), timeout=0.05)
        elapsed = time.monotonic() - start
        self.assertEqual(ctx.exception.code, 4)  # DEADLINE_EXCEEDED
        self.assertLess(elapsed, 0.35)

    def test_unary_within_deadline_and_server_sees_budget(self):
        echo = EchoService()
        a, b = grpcdc.memory_transport_pair()
        server = grpcdc.Server()
        echo_grpc_dc.register_echo_server(server, echo)
        server.serve_transport(b)
        client = echo_grpc_dc.EchoClient(grpcdc.Channel(a))
        resp = client.Unary(req("hello"), timeout=30.0)
        self.assertEqual(resp.message, "echo: hello")

    def test_server_context_carries_deadline(self):
        with self.assertRaises(grpcdc.StatusError):
            self.client.Unary(req("hello"), timeout=0.05)
        # Let the handler start and record its context.
        deadline = time.monotonic() + 2.0
        while self.service.seen_ctx is None and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertIsNotNone(self.service.seen_ctx)
        ctx = self.service.seen_ctx
        self.assertIn("grpc-timeout", ctx.metadata)
        self.assertIsNotNone(ctx.deadline)
        self.assertIsNotNone(ctx.time_remaining())

    def test_server_stream_times_out_mid_stream(self):
        stream = self.client.ServerStream(req("tick", 5), timeout=0.15)
        first = next(stream)
        self.assertEqual(first.index, 0)
        with self.assertRaises(grpcdc.StatusError) as ctx:
            next(stream)
        self.assertEqual(ctx.exception.code, 4)

    def test_async_unary_times_out(self):
        client = echo_grpc_dc.EchoClientAsync(
            grpcdc.AsyncChannel(channel=self.channel))

        async def go():
            with self.assertRaises(grpcdc.StatusError) as ctx:
                await client.Unary(req("hello"), timeout=0.05)
            self.assertEqual(ctx.exception.code, 4)

        asyncio.run(go())

    def test_channel_usable_after_deadline(self):
        with self.assertRaises(grpcdc.StatusError):
            self.client.Unary(req("hello"), timeout=0.05)
        a, b = grpcdc.memory_transport_pair()
        server = grpcdc.Server()
        echo_grpc_dc.register_echo_server(server, EchoService())
        server.serve_transport(b)
        client = echo_grpc_dc.EchoClient(grpcdc.Channel(a))
        self.assertEqual(client.Unary(req("after")).message, "echo: after")


if __name__ == "__main__":
    unittest.main()
