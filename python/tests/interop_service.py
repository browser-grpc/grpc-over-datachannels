"""TestService implementation (grpc.testing) over the generated
Python Server, mirroring the reference TestServiceImpl
semantics the interop cases grade: payload sizes answered
with zero bodies of the requested size, response_parameters
drive streamed responses (interval_us honored),
response_status fails the call, streaming input aggregated
by byte count. Used by test_interop_server_oracle.py.
"""

import time

import grpcdc
from grpcdc.wire_gen import CODE_UNIMPLEMENTED
from messages_pb import (
    Payload,
    SimpleResponse,
    StreamingInputCallResponse,
    StreamingOutputCallResponse,
)
from test_pb import Empty


def _zeros(n):
    return b"\x00" * n


def _maybe_fail(req):
    status = req.response_status
    if status is not None and (status.code != 0 or status.message != ""):
        raise grpcdc.StatusError(status.code, status.message)


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


class TestServiceImpl:
    def EmptyCall(self, ctx, req):
        return Empty()

    def UnaryCall(self, ctx, req):
        return _unary_response(req)

    def CacheableUnaryCall(self, ctx, req):
        # Reference semantics: echo the request payload.
        _maybe_fail(req)
        return SimpleResponse(payload=req.payload)

    def StreamingOutputCall(self, req, stream):
        _send_responses(req, stream.send)

    def StreamingInputCall(self, stream):
        total = 0
        while True:
            try:
                req = stream.recv()
            except EOFError:
                break
            if req.payload is not None:
                total += len(req.payload.body)
        stream.send_and_close(
            StreamingInputCallResponse(aggregated_payload_size=total)
        )

    def FullDuplexCall(self, stream):
        while True:
            try:
                req = stream.recv()
            except EOFError:
                return
            _send_responses(req, stream.send)

    def HalfDuplexCall(self, stream):
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
