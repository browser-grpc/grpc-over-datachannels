"""Tracing demo: a printing span observer over an in-process call.

Run: python3 python/examples/tracing_demo.py

Registers an observer that prints one line per span start/end.
The client and server spans share one trace id; the server span's
parent is the client span. With no observer registered nothing is
printed and no traceparent header is sent (tracing is dormant).
"""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.dirname(__file__))

import grpcdc
import echo_grpc_dc
from echo_pb import EchoRequest
from echo_service import EchoService


class PrintingTracer:
    """Span observer that prints spans as they start and end."""

    def __init__(self, out=None):
        self.out = out if out is not None else print
        self.events = []

    def on_start(self, kind, method, trace_id, span_id, parent_span_id):
        self.events.append(("start", kind, trace_id, span_id, parent_span_id))
        self.out(
            f"-> {kind} {method} trace={trace_id} span={span_id} "
            f"parent={parent_span_id or '-'}"
        )

    def on_end(self, kind, method, trace_id, span_id, status):
        self.events.append(("end", kind, trace_id, span_id, status))
        self.out(f"<- {kind} {method} trace={trace_id} span={span_id} status={status}")


def run_demo(out=None):
    """Run one traced unary call; return the PrintingTracer used."""
    tracer = PrintingTracer(out)
    grpcdc.set_tracer(tracer)
    try:
        a, b = grpcdc.memory_transport_pair()
        server = grpcdc.Server()
        echo_grpc_dc.register_echo_server(server, EchoService())
        server.serve_transport(b)
        client = echo_grpc_dc.EchoClient(grpcdc.Channel(a))
        resp = client.Unary(EchoRequest(message="hello"))
        assert resp.message == "echo: hello", resp.message
    finally:
        grpcdc.set_tracer(None)
    return tracer


if __name__ == "__main__":
    run_demo()
