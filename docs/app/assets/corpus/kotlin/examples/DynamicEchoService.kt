package echo

import grpcdc.Dynamic
import grpcdc.Endpoint
import grpcdc.StatusException
import grpcdc.Wire
import java.io.EOFException

/// Dynamic Echo implementation: the reference Echo semantics built
/// purely on the descriptor-driven runtime (no generated stubs).
/// Field numbers come from proto/echo.proto: EchoRequest{message=1,
/// count=2}, EchoResponse{message=1, index=2}.
class DynamicEchoService : Dynamic.DynamicHandler {
    private fun response(method: Dynamic.MethodModel, message: String, index: Long): Dynamic.GenericMessage {
        return Dynamic.GenericMessage(method.output).set(1, message).set(2, index)
    }

    override fun unary(ctx: Endpoint.CallContext, method: Dynamic.MethodModel, req: Dynamic.GenericMessage): Dynamic.GenericMessage {
        val message = req.getString(1)
        if (message == "fail") {
            throw StatusException(Wire.CODE_INVALID_ARGUMENT, "asked to fail")
        }
        val marker = ctx.metadata["x-echo"]
        val suffix = if (marker.isNullOrEmpty()) "" else " [$marker]"
        return response(method, "echo: $message$suffix", 0)
    }

    override fun serverStream(ctx: Endpoint.CallContext, method: Dynamic.MethodModel, req: Dynamic.GenericMessage, send: Dynamic.SendFn) {
        val count = req.getInt(2)
        var i = 0L
        while (i < count) {
            send.send(response(method, req.getString(1), i))
            i++
        }
    }

    override fun clientStream(ctx: Endpoint.CallContext, method: Dynamic.MethodModel, recv: Dynamic.RecvFn): Dynamic.GenericMessage {
        val parts = ArrayList<String>()
        while (true) {
            try {
                parts.add(recv.recv().getString(1))
            } catch (e: EOFException) {
                break
            }
        }
        return response(method, parts.joinToString("+"), parts.size.toLong())
    }

    override fun bidi(ctx: Endpoint.CallContext, method: Dynamic.MethodModel, recv: Dynamic.RecvFn, send: Dynamic.SendFn) {
        var index = 0L
        while (true) {
            val req: Dynamic.GenericMessage
            try {
                req = recv.recv()
            } catch (e: EOFException) {
                return
            }
            send.send(response(method, req.getString(1), index))
            index++
        }
    }
}
