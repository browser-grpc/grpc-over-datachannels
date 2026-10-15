"""Dynamic Echo implementation: the reference Echo semantics built
purely on the descriptor-driven runtime (no generated stubs).
Field numbers come from proto/echo.proto: EchoRequest{message=1,
count=2}, EchoResponse{message=1, index=2}.
"""

import grpcdc
from grpcdc import GenericMessage, StatusError
from grpcdc.wire_gen import CODE_INVALID_ARGUMENT


def _response(method, message, index):
    return GenericMessage(method.output).set(1, message).set(2, index)


class DynamicEchoService:
    """Handler protocol for grpcdc.register_dynamic_service."""

    def unary(self, ctx, method, request):
        message = request.get_string(1)
        if message == "fail":
            raise StatusError(CODE_INVALID_ARGUMENT, "asked to fail")
        suffix = ""
        if ctx.metadata.get("x-echo"):
            suffix = " [" + ctx.metadata["x-echo"] + "]"
        return _response(method, f"echo: {message}{suffix}", 0)

    def server_stream(self, ctx, method, request, send):
        for i in range(max(0, request.get_int(2))):
            send(_response(method, request.get_string(1), i))

    def client_stream(self, ctx, method, requests):
        parts = [req.get_string(1) for req in requests]
        return _response(method, "+".join(parts), len(parts))

    def bidi(self, ctx, method, requests, send):
        for index, req in enumerate(requests):
            send(_response(method, req.get_string(1), index))
