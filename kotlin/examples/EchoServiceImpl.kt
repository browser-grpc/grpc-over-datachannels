package echo

import grpcdc.Endpoint
import grpcdc.StatusException
import grpcdc.Wire
import java.io.EOFException
import kotlin.math.max

/** Reference Echo implementation (mirrors the other language demos):
 * "fail" is rejected, everything else echoes. */
class EchoServiceImpl : EchoGrpcDc.EchoServer {
    override fun Unary(ctx: Endpoint.CallContext, req: EchoRequest): EchoResponse {
        if (req.message == "fail") {
            throw StatusException(Wire.CODE_INVALID_ARGUMENT, "asked to fail")
        }
        if (req.delayMs > 0) {
            Thread.sleep(req.delayMs.toLong())
        }
        val marker = ctx.metadata["x-echo"]
        val suffix = if (marker.isNullOrEmpty()) "" else " [$marker]"
        return EchoResponse("echo: ${req.message}$suffix", 0)
    }

    override fun ServerStream(req: EchoRequest, stream: EchoGrpcDc.EchoServerStreamServer) {
        if (req.message == "fail") {
            throw StatusException(Wire.CODE_INVALID_ARGUMENT, "asked to fail")
        }
        for (i in 0 until max(0, req.count)) {
            stream.send(EchoResponse(req.message, i))
        }
    }

    override fun ClientStream(stream: EchoGrpcDc.EchoClientStreamServer) {
        val parts = ArrayList<String>()
        while (true) {
            try {
                parts.add(stream.recv().message)
            } catch (e: EOFException) {
                break
            }
        }
        stream.sendAndClose(EchoResponse(parts.joinToString("+"), parts.size))
    }

    override fun Bidi(stream: EchoGrpcDc.EchoBidiServer) {
        var index = 0
        while (true) {
            val req: EchoRequest
            try {
                req = stream.recv()
            } catch (e: EOFException) {
                return
            }
            if (req.message == "fail") {
                throw StatusException(Wire.CODE_INVALID_ARGUMENT, "asked to fail")
            }
            stream.send(EchoResponse(req.message, index))
            index++
        }
    }
}
