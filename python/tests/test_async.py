"""Asyncio surface: AsyncChannel + generated EchoClientAsync over loopback.

Covers all four call shapes with async/await and async-for, error
status propagation, concurrent calls on one channel, and task
cancellation aborting a stream (RST) without poisoning the channel.
"""

import asyncio
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "examples"))

import grpcdc
import echo_grpc_dc
from echo_pb import EchoRequest
from echo_service import EchoService
from echo_pb import EchoResponse
import time


def req(message, count=0, delay_ms=0):
    return EchoRequest(message=message, count=count, delay_ms=delay_ms)


class TestAsyncLoopback(unittest.TestCase):
    def setUp(self):
        a, b = grpcdc.memory_transport_pair()
        server = grpcdc.Server()
        echo_grpc_dc.register_echo_server(server, EchoService())
        server.serve_transport(b)
        self.client = echo_grpc_dc.EchoClientAsync(grpcdc.AsyncChannel(a))

    def test_unary(self):
        async def go():
            resp = await self.client.Unary(req("hello"))
            self.assertEqual(resp.message, "echo: hello")
            self.assertEqual(resp.index, 0)

        asyncio.run(go())

    def test_server_stream_async_for(self):
        async def go():
            stream = await self.client.ServerStream(req("tick", 3))
            seen = [resp async for resp in stream]
            self.assertEqual([r.index for r in seen], [0, 1, 2])
            self.assertTrue(all(r.message == "tick" for r in seen))

        asyncio.run(go())

    def test_client_stream_and_bidi(self):
        async def go():
            resp = await self.client.ClientStream([req("a"), req("b"), req("c")])
            self.assertEqual(resp.message, "a+b+c")
            stream = await self.client.Bidi([req("x"), req("y")])
            seen = [resp.message async for resp in stream]
            self.assertEqual(seen, ["x", "y"])

        asyncio.run(go())

    def test_error_status(self):
        async def go():
            with self.assertRaises(grpcdc.StatusError) as ctx:
                await self.client.Unary(req("fail"))
            self.assertEqual(ctx.exception.code, 3)

        asyncio.run(go())

    def test_concurrent_unary_calls(self):
        async def go():
            resps = await asyncio.gather(
                *(self.client.Unary(req(f"m{i}")) for i in range(8)))
            self.assertEqual([r.message for r in resps],
                             [f"echo: m{i}" for i in range(8)])

        asyncio.run(go())

    def test_wrap_sync_channel(self):
        a, b = grpcdc.memory_transport_pair()
        server = grpcdc.Server()
        echo_grpc_dc.register_echo_server(server, EchoService())
        server.serve_transport(b)
        client = echo_grpc_dc.EchoClientAsync(grpcdc.Channel(a))

        async def go():
            resp = await client.Unary(req("wrapped"))
            self.assertEqual(resp.message, "echo: wrapped")

        asyncio.run(go())

    def test_cancel_stream_task_then_channel_still_works(self):
        class SlowService(EchoService):
            def ServerStream(self, request, stream):
                for i in range(max(0, request.count)):
                    if i:
                        time.sleep(0.3)
                    stream.send(EchoResponse(message=request.message, index=i))

        a, b = grpcdc.memory_transport_pair()
        server = grpcdc.Server()
        echo_grpc_dc.register_echo_server(server, SlowService())
        server.serve_transport(b)
        self.client = echo_grpc_dc.EchoClientAsync(grpcdc.AsyncChannel(a))

        async def go():
            stream = await self.client.ServerStream(req("slow", 5))
            first = await stream.recv()
            self.assertEqual(first.index, 0)

            async def drain():
                return [resp async for resp in stream]

            task = asyncio.ensure_future(drain())
            await asyncio.sleep(0.05)
            task.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await task
            resp = await self.client.Unary(req("after"))
            self.assertEqual(resp.message, "echo: after")

        asyncio.run(go())


if __name__ == "__main__":
    unittest.main()
