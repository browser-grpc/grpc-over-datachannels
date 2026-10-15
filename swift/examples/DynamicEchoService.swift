/// Dynamic Echo implementation: the reference Echo semantics built
/// purely on the descriptor-driven runtime (no generated stubs).
/// Field numbers come from proto/echo.proto: EchoRequest{message=1,
/// count=2}, EchoResponse{message=1, index=2}.
final class DynamicEchoService: Dynamic.DynamicHandler {
    private func Response(_ method: Dynamic.MethodModel, _ message: String, _ index: Int64) -> Dynamic.GenericMessage {
        Dynamic.GenericMessage(method.output).Set(1, .string(message)).Set(2, .int64(index))
    }

    func Unary(_ ctx: Endpoint.CallContext, _ method: Dynamic.MethodModel, _ req: Dynamic.GenericMessage) throws -> Dynamic.GenericMessage {
        let message = req.GetString(1)
        if message == "fail" {
            throw StatusException(Wire.CodeInvalidArgument, "asked to fail")
        }
        var suffix = ""
        if let marker = ctx.metadata["x-echo"], !marker.isEmpty {
            suffix = " [\(marker)]"
        }
        return Response(method, "echo: \(message)\(suffix)", 0)
    }

    func ServerStream(_ ctx: Endpoint.CallContext, _ method: Dynamic.MethodModel, _ req: Dynamic.GenericMessage, _ send: Dynamic.SendFn) throws {
        let count = req.GetInt(2)
        var i: Int64 = 0
        while i < count {
            try send(Response(method, req.GetString(1), i))
            i += 1
        }
    }

    func ClientStream(_ ctx: Endpoint.CallContext, _ method: Dynamic.MethodModel, _ recv: Dynamic.RecvFn) throws -> Dynamic.GenericMessage {
        var parts: [String] = []
        while true {
            do {
                parts.append(try recv().GetString(1))
            } catch is EndOfStreamError {
                break
            }
        }
        return Response(method, parts.joined(separator: "+"), Int64(parts.count))
    }

    func Bidi(_ ctx: Endpoint.CallContext, _ method: Dynamic.MethodModel, _ recv: Dynamic.RecvFn, _ send: Dynamic.SendFn) throws {
        var index: Int64 = 0
        while true {
            let req: Dynamic.GenericMessage
            do {
                req = try recv()
            } catch is EndOfStreamError {
                return
            }
            try send(Response(method, req.GetString(1), index))
            index += 1
        }
    }
}
