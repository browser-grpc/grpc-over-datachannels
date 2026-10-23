"""Homegrown tracing: traceparent propagation + span observer.

Client and server hooks must observe one shared trace id with
server parented to the client span; with no tracer registered
nothing is emitted (dormant by default).
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "examples"))

import grpcdc
import echo_grpc_dc
from echo_pb import EchoRequest
from echo_service import EchoService


class Recorder:
    def __init__(self):
        self.starts = []
        self.ends = []

    def on_start(self, kind, method, trace_id, span_id, parent_span_id):
        self.starts.append((kind, method, trace_id, span_id, parent_span_id))

    def on_end(self, kind, method, trace_id, span_id, status):
        self.ends.append((kind, method, trace_id, span_id, status))


class TestTracing(unittest.TestCase):
    def setUp(self):
        self.recorder = Recorder()
        grpcdc.set_tracer(self.recorder)
        a, b = grpcdc.memory_transport_pair()
        server = grpcdc.Server()
        echo_grpc_dc.register_echo_server(server, EchoService())
        server.serve_transport(b)
        self.client = echo_grpc_dc.EchoClient(grpcdc.Channel(a))

    def tearDown(self):
        grpcdc.set_tracer(None)
        grpcdc.set_trace_filter("")

    def test_unary_propagates_one_trace(self):
        resp = self.client.Unary(EchoRequest(message="hello"))
        self.assertEqual(resp.message, "echo: hello")
        starts = self.recorder.starts
        ends = self.recorder.ends
        self.assertEqual([s[0] for s in starts], ["client", "server"])
        client, server = starts
        self.assertEqual(client[1], "/echo.Echo/Unary")
        self.assertEqual(server[1], "/echo.Echo/Unary")
        # One trace; server span parented to the client span.
        self.assertEqual(client[2], server[2])
        self.assertEqual(len(client[2]), 32)
        self.assertEqual(server[4], client[3])
        self.assertEqual(client[4], "")
        # Server dispatch ends before the client observes trailers.
        self.assertEqual([e[0] for e in ends], ["server", "client"])
        self.assertTrue(all(e[4] == "OK" for e in ends))
        # End hooks carry the same span ids as start hooks.
        self.assertEqual(ends[0][3], server[3])
        self.assertEqual(ends[1][3], client[3])

    def test_server_stream_spans_once_each(self):
        responses = list(self.client.ServerStream(EchoRequest(message="tick", count=3)))
        self.assertEqual(len(responses), 3)
        self.assertEqual(len(self.recorder.starts), 2)
        self.assertEqual(len(self.recorder.ends), 2)
        self.assertTrue(all(e[4] == "OK" for e in self.recorder.ends))

    def test_error_status_on_both_ends(self):
        with self.assertRaises(grpcdc.StatusError):
            self.client.Unary(EchoRequest(message="fail"))
        ends = {e[0]: e[4] for e in self.recorder.ends}
        self.assertEqual(ends.get("client"), "INVALID-ARGUMENT")
        self.assertEqual(ends.get("server"), "INVALID-ARGUMENT")

    def test_incoming_traceparent_is_continued(self):
        trace_id = "a" * 32
        span_id = "b" * 16
        self.client.Unary(
            EchoRequest(message="hello"),
            metadata={"traceparent": f"00-{trace_id}-{span_id}-01"},
        )
        client = self.recorder.starts[0]
        self.assertEqual(client[2], trace_id)
        self.assertEqual(client[4], span_id)

    def test_filter_restricts_methods(self):
        grpcdc.set_trace_filter("/echo.Echo/ServerStream")
        self.client.Unary(EchoRequest(message="hello"))
        self.assertEqual(self.recorder.starts, [])
        list(self.client.ServerStream(EchoRequest(message="tick", count=1)))
        self.assertEqual([s[1] for s in self.recorder.starts],
                         ["/echo.Echo/ServerStream"] * 2)
        self.recorder.starts.clear()
        grpcdc.set_trace_filter("/echo.Echo/*")
        self.client.Unary(EchoRequest(message="hello"))
        self.assertEqual(len(self.recorder.starts), 2)
        self.recorder.starts.clear()
        grpcdc.set_trace_filter("/other.Service/Method")
        self.client.Unary(EchoRequest(message="hello"))
        self.assertEqual(self.recorder.starts, [])

    def test_dormant_without_tracer(self):
        grpcdc.set_tracer(None)
        resp = self.client.Unary(EchoRequest(message="hello"))
        self.assertEqual(resp.message, "echo: hello")
        self.assertEqual(self.recorder.starts, [])
        self.assertEqual(self.recorder.ends, [])


class TestTracingDemo(unittest.TestCase):
    def test_demo_prints_one_parented_trace(self):
        import tracing_demo

        lines = []
        tracer = tracing_demo.run_demo(out=lines.append)
        self.assertEqual(len(lines), 4)
        starts = [e for e in tracer.events if e[0] == "start"]
        self.assertEqual([s[1] for s in starts], ["client", "server"])
        self.assertEqual(starts[0][2], starts[1][2])
        self.assertEqual(starts[1][4], starts[0][3])
        joined = "\n".join(lines)
        self.assertIn("/echo.Echo/Unary", joined)
        self.assertIn("status=OK", joined)


if __name__ == "__main__":
    unittest.main()
