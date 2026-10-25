"""TestService implementation (grpc.testing) over the generated
Python Server, mirroring the reference TestServiceImpl
semantics the interop cases grade: payload sizes answered
with zero bodies of the requested size, response_parameters
drive streamed responses (interval_us honored),
response_status fails the call, streaming input aggregated
by byte count. Used by test_interop_server_oracle.py.
"""

import base64
import threading
import time

import grpcdc
from grpcdc.wire_gen import CODE_INVALID_ARGUMENT, CODE_UNIMPLEMENTED
from messages_pb import (
    Payload,
    SimpleResponse,
    StreamingInputCallResponse,
    StreamingOutputCallResponse,
)
from orca_load_report_pb import OrcaLoadReport
from test_pb import Empty


def _zeros(n):
    return b"\x00" * n


def _maybe_fail(req):
    status = req.response_status
    if status is not None and (status.code != 0 or status.message != ""):
        raise grpcdc.StatusError(status.code, status.message)


def _echo_metadata(ctx):
    """Reference echo (custom_metadata case): the echo-initial
    request value returns as initial metadata, the
    echo-trailing-bin value (base64 on our wire) as trailers."""
    if ctx is None:
        return
    initial = ctx.metadata.get("x-grpc-test-echo-initial")
    if initial is not None:
        ctx.set_headers({"x-grpc-test-echo-initial": initial})
    trailing = ctx.metadata.get("x-grpc-test-echo-trailing-bin")
    if trailing is not None:
        ctx.set_trailers({"x-grpc-test-echo-trailing-bin": trailing})


# ORCA load reporting (orca_per_rpc / orca_oob): a per-request
# TestOrcaReport rides back as the serialized OrcaLoadReport in
# the endpoint-load-metrics-bin trailer (base64, as -bin values
# travel); OOB reports carried by FullDuplexCall requests update
# shared state that later UnaryCalls report.
_orca_lock = threading.Lock()
_orca_oob_report = None


def _set_orca_trailer(ctx, report):
    if ctx is None or report is None:
        return
    ctx.set_trailers({
        "endpoint-load-metrics-bin":
            base64.b64encode(report.marshal_dc()).decode("ascii"),
    })


def _compression_checks(ctx, req):
    # Compression interop (server direction): the proxy
    # terminates gzip at the HTTP/2 hop and surfaces the
    # declared encoding as ordinary metadata, so the reference
    # checks map onto it -- expect_compressed fails when the
    # request did not arrive compressed; response_compressed
    # declares grpc-encoding: gzip in the initial metadata and
    # the proxy gzips the response messages.
    if ctx is None:
        return
    if (req.expect_compressed is not None and req.expect_compressed.value
            and ctx.metadata.get("grpc-encoding") != "gzip"):
        raise grpcdc.StatusError(
            CODE_INVALID_ARGUMENT,
            "expected compressed request, got uncompressed")
    if (req.response_compressed is not None
            and req.response_compressed.value):
        ctx.set_headers({"grpc-encoding": "gzip"})


def _unary_response(req):
    _maybe_fail(req)
    return SimpleResponse(
        payload=Payload(type=req.response_type, body=_zeros(req.response_size))
    )


def _send_responses(req, send):
    _maybe_fail(req)
    for i, param in enumerate(req.response_parameters):
        if i > 0 and param.interval_us > 0:
            time.sleep(param.interval_us / 1_000_000)
        send(
            StreamingOutputCallResponse(
                payload=Payload(type=req.response_type, body=_zeros(param.size))
            )
        )


class OpenRcaServiceImpl:
    """ORCA out-of-band: stream the current OOB report on an
    interval until the client goes away."""

    def StreamCoreMetrics(self, req, stream):
        while True:
            with _orca_lock:
                report = _orca_oob_report
            stream.send(report if report is not None else OrcaLoadReport())
            time.sleep(0.2)


class TestServiceImpl:
    def EmptyCall(self, ctx, req):
        _echo_metadata(ctx)
        return Empty()

    def UnaryCall(self, ctx, req):
        _echo_metadata(ctx)
        _compression_checks(ctx, req)
        if req.orca_per_query_report is not None:
            r = req.orca_per_query_report
            _set_orca_trailer(ctx, OrcaLoadReport(
                cpu_utilization=r.cpu_utilization,
                mem_utilization=r.memory_utilization,
                request_cost=dict(r.request_cost),
                utilization=dict(r.utilization),
            ))
        else:
            global _orca_oob_report
            with _orca_lock:
                oob = _orca_oob_report
            _set_orca_trailer(ctx, oob)
        return _unary_response(req)

    def CacheableUnaryCall(self, ctx, req):
        _echo_metadata(ctx)
        # Reference semantics: echo the request payload.
        _maybe_fail(req)
        return SimpleResponse(payload=req.payload)

    def StreamingOutputCall(self, req, stream):
        _echo_metadata(stream.context)
        _send_responses(req, stream.send)

    def StreamingInputCall(self, stream):
        _echo_metadata(stream.context)
        total = 0
        while True:
            try:
                req = stream.recv()
            except EOFError:
                break
            # Per-message expect_compressed, graded against
            # the stream's declared encoding (surfaced by the
            # proxy from the first message's compressed flag).
            if (req.expect_compressed is not None
                    and req.expect_compressed.value
                    and stream.context.metadata.get("grpc-encoding") != "gzip"):
                raise grpcdc.StatusError(
                    CODE_INVALID_ARGUMENT,
                    "expected compressed request, got uncompressed")
            if req.payload is not None:
                total += len(req.payload.body)
        stream.send_and_close(
            StreamingInputCallResponse(aggregated_payload_size=total)
        )

    def FullDuplexCall(self, stream):
        _echo_metadata(stream.context)
        while True:
            try:
                req = stream.recv()
            except EOFError:
                return
            if req.orca_oob_report is not None:
                global _orca_oob_report
                r = req.orca_oob_report
                with _orca_lock:
                    _orca_oob_report = OrcaLoadReport(
                        cpu_utilization=r.cpu_utilization,
                        mem_utilization=r.memory_utilization,
                        utilization=dict(r.utilization),
                    )
            _send_responses(req, stream.send)

    def HalfDuplexCall(self, stream):
        _echo_metadata(stream.context)
        reqs = []
        while True:
            try:
                reqs.append(stream.recv())
            except EOFError:
                break
        for req in reqs:
            _send_responses(req, stream.send)

    def UnimplementedCall(self, ctx, req):
        raise grpcdc.StatusError(CODE_UNIMPLEMENTED, "not implemented")
