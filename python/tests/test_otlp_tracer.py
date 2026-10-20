"""The OTLP example observer exports well-formed OTLP/JSON."""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "examples"))

import grpcdc
import echo_grpc_dc
from echo_pb import EchoRequest
from echo_service import EchoService
from otlp_tracer import OtlpTracer


class TestOtlpTracer(unittest.TestCase):
    def test_traced_call_exports_parented_spans(self):
        sent = []
        tracer = OtlpTracer(service_name="echo-test", sender=sent.append)
        grpcdc.set_tracer(tracer)
        try:
            a, b = grpcdc.memory_transport_pair()
            server = grpcdc.Server()
            echo_grpc_dc.register_echo_server(server, EchoService())
            server.serve_transport(b)
            client = echo_grpc_dc.EchoClient(grpcdc.Channel(a))
            client.Unary(EchoRequest(message="hello"))
            tracer.flush()
        finally:
            grpcdc.set_tracer(None)
        self.assertEqual(len(sent), 1)
        resource = sent[0]["resourceSpans"][0]
        attrs = resource["resource"]["attributes"]
        self.assertEqual(attrs[0]["value"]["stringValue"], "echo-test")
        spans = resource["scopeSpans"][0]["spans"]
        self.assertEqual(len(spans), 2)
        by_kind = {s["kind"]: s for s in spans}
        client, server = by_kind[3], by_kind[2]
        self.assertEqual(client["traceId"], server["traceId"])
        self.assertEqual(len(client["traceId"]), 32)
        self.assertEqual(server["parentSpanId"], client["spanId"])
        self.assertEqual(client["parentSpanId"], "")
        self.assertEqual(client["name"], "/echo.Echo/Unary")
        self.assertEqual(client["status"], {"code": 1})
        self.assertTrue(all("startTimeUnixNano" in s for s in spans))

    def test_export_failure_never_breaks_the_call(self):
        def boom(payload):
            raise RuntimeError("collector down")

        tracer = OtlpTracer(sender=boom, batch_size=1)
        grpcdc.set_tracer(tracer)
        try:
            a, b = grpcdc.memory_transport_pair()
            server = grpcdc.Server()
            echo_grpc_dc.register_echo_server(server, EchoService())
            server.serve_transport(b)
            client = echo_grpc_dc.EchoClient(grpcdc.Channel(a))
            resp = client.Unary(EchoRequest(message="hello"))
            self.assertEqual(resp.message, "echo: hello")
        finally:
            grpcdc.set_tracer(None)


if __name__ == "__main__":
    unittest.main()
