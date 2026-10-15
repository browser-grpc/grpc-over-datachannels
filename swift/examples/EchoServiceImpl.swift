/// Reference Echo implementation (mirrors the Rust/JS/Go/Python/Java
/// demos): "fail" is rejected, everything else echoes.
final class EchoServiceImpl: EchoGrpcDc.EchoServer {
    func Unary(_ ctx: Endpoint.CallContext, _ req: EchoRequest) throws -> EchoResponse {
        if req.message == "fail" {
            throw StatusException(Wire.CodeInvalidArgument, "asked to fail")
        }
        var suffix = ""
        if let marker = ctx.metadata["x-echo"], !marker.isEmpty {
            suffix = " [\(marker)]"
        }
        return EchoResponse("echo: \(req.message)\(suffix)", 0)
    }

    func ServerStream(_ req: EchoRequest, _ stream: EchoGrpcDc.EchoServerStreamServer) throws {
        var i: Int32 = 0
        while i < max(0, req.count) {
            try stream.Send(EchoResponse(req.message, i))
            i += 1
        }
    }

    func ClientStream(_ stream: EchoGrpcDc.EchoClientStreamServer) throws {
        var parts: [String] = []
        while true {
            do {
                parts.append(try stream.Recv().message)
            } catch is EndOfStreamError {
                break
            }
        }
        stream.SendAndClose(EchoResponse(parts.joined(separator: "+"), Int32(parts.count)))
    }

    func Bidi(_ stream: EchoGrpcDc.EchoBidiServer) throws {
        var index: Int32 = 0
        while true {
            let req: EchoRequest
            do {
                req = try stream.Recv()
            } catch is EndOfStreamError {
                return
            }
            try stream.Send(EchoResponse(req.message, index))
            index += 1
        }
    }
}
