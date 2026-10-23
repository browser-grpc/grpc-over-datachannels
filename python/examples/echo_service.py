"""Reference Echo implementation (mirrors the Rust/JS/Go demos):
"fail" is rejected in every method, everything else echoes."""

import time

import grpcdc
from grpcdc import StatusError
from grpcdc.wire_gen import CODE_INVALID_ARGUMENT

from echo_pb import EchoRequest, EchoResponse


class EchoService:
    def Unary(self, ctx, req):
        if req.message == "fail":
            raise StatusError(CODE_INVALID_ARGUMENT, "asked to fail")
        if req.delay_ms > 0:
            time.sleep(req.delay_ms / 1000.0)
        suffix = ""
        if ctx.metadata.get("x-echo"):
            suffix = " [" + ctx.metadata["x-echo"] + "]"
        return EchoResponse(message=f"echo: {req.message}{suffix}", index=0)

    def ServerStream(self, req, stream):
        if req.message == "fail":
            raise StatusError(CODE_INVALID_ARGUMENT, "asked to fail")
        for i in range(max(0, req.count)):
            stream.send(EchoResponse(message=req.message, index=i))

    def ClientStream(self, stream):
        parts = []
        while True:
            try:
                req = stream.recv()
            except EOFError:
                break
            parts.append(req.message)
        stream.send_and_close(
            EchoResponse(message="+".join(parts), index=len(parts))
        )

    def Bidi(self, stream):
        index = 0
        while True:
            try:
                req = stream.recv()
            except EOFError:
                return
            if req.message == "fail":
                raise StatusError(CODE_INVALID_ARGUMENT, "asked to fail")
            stream.send(EchoResponse(message=req.message, index=index))
            index += 1
