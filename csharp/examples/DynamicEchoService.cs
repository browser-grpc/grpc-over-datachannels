using Grpcdc;

namespace Echo;

/// <summary>
/// Dynamic Echo implementation: the reference Echo semantics built
/// purely on the descriptor-driven runtime (no generated stubs).
/// Field numbers come from proto/echo.proto: EchoRequest{message=1,
/// count=2}, EchoResponse{message=1, index=2}.
/// </summary>
public sealed class DynamicEchoService : Dynamic.IDynamicHandler
{
    private static Dynamic.GenericMessage Response(Dynamic.MethodModel method, string message, long index)
    {
        return new Dynamic.GenericMessage(method.Output).Set(1, message).Set(2, index);
    }

    public Dynamic.GenericMessage Unary(Endpoint.CallContext ctx, Dynamic.MethodModel method, Dynamic.GenericMessage req)
    {
        string message = req.GetString(1);
        if (message == "fail")
        {
            throw new StatusException(Wire.CodeInvalidArgument, "asked to fail");
        }
        string suffix = "";
        if (ctx.Metadata.TryGetValue("x-echo", out string marker) && !string.IsNullOrEmpty(marker))
        {
            suffix = $" [{marker}]";
        }
        return Response(method, $"echo: {message}{suffix}", 0);
    }

    public void ServerStream(Endpoint.CallContext ctx, Dynamic.MethodModel method, Dynamic.GenericMessage req, Dynamic.SendFn send)
    {
        long count = req.GetInt(2);
        for (long i = 0; i < count; i++)
        {
            send(Response(method, req.GetString(1), i));
        }
    }

    public Dynamic.GenericMessage ClientStream(Endpoint.CallContext ctx, Dynamic.MethodModel method, Dynamic.RecvFn recv)
    {
        var parts = new List<string>();
        while (true)
        {
            Dynamic.GenericMessage req;
            try
            {
                req = recv();
            }
            catch (EndOfStreamException)
            {
                break;
            }
            parts.Add(req.GetString(1));
        }
        return Response(method, string.Join("+", parts), parts.Count);
    }

    public void Bidi(Endpoint.CallContext ctx, Dynamic.MethodModel method, Dynamic.RecvFn recv, Dynamic.SendFn send)
    {
        long index = 0;
        while (true)
        {
            Dynamic.GenericMessage req;
            try
            {
                req = recv();
            }
            catch (EndOfStreamException)
            {
                return;
            }
            send(Response(method, req.GetString(1), index++));
        }
    }
}
