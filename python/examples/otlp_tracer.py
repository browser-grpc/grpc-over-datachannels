"""OTLP/JSON exporter as an example span observer (not in the runtime).

The generated runtimes stay dependency-free and SDK-free; this
example shows the hooks are sufficient for a real backend. Ended
spans are buffered and POSTed as OTLP/JSON to an OpenTelemetry
collector (default http://localhost:4318/v1/traces) using only the
standard library. Export failures are swallowed: tracing must
never break the call.

Usage:
    grpcdc.set_tracer(OtlpTracer(service_name="echo-client"))
    ... make calls ...
    tracer.flush()
"""

import json
import os
import sys
import time
import urllib.request

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

_KIND = {"client": 3, "server": 2}  # OTLP SpanKind CLIENT / SERVER


class OtlpTracer:
    def __init__(self, endpoint="http://localhost:4318/v1/traces",
                 service_name="grpcdc", batch_size=32, sender=None):
        self.endpoint = endpoint
        self.service_name = service_name
        self.batch_size = batch_size
        self.sender = sender or self._post
        self._open = {}
        self._ended = []

    # -- observer interface -------------------------------------------------
    def on_start(self, kind, method, trace_id, span_id, parent_span_id):
        self._open[span_id] = {
            "traceId": trace_id,
            "spanId": span_id,
            "parentSpanId": parent_span_id,
            "name": method,
            "kind": _KIND.get(kind, 1),
            "startTimeUnixNano": str(time.time_ns()),
            "attributes": [{"key": "grpcdc.kind", "value": {"stringValue": kind}}],
        }

    def on_end(self, kind, method, trace_id, span_id, status):
        span = self._open.pop(span_id, None)
        if span is None:
            return
        span["endTimeUnixNano"] = str(time.time_ns())
        span["status"] = (
            {"code": 1} if status == "OK" else {"code": 2, "message": status}
        )
        self._ended.append(span)
        if len(self._ended) >= self.batch_size:
            self.flush()

    # -- export ---------------------------------------------------------------
    def payload(self, spans):
        return {
            "resourceSpans": [{
                "resource": {
                    "attributes": [{
                        "key": "service.name",
                        "value": {"stringValue": self.service_name},
                    }],
                },
                "scopeSpans": [{
                    "scope": {"name": "grpcdc"},
                    "spans": spans,
                }],
            }],
        }

    def flush(self):
        if not self._ended:
            return
        spans, self._ended = self._ended, []
        try:
            self.sender(self.payload(spans))
        except Exception:
            pass  # tracing must never break the call

    def _post(self, payload):
        req = urllib.request.Request(
            self.endpoint,
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=2):
            pass
