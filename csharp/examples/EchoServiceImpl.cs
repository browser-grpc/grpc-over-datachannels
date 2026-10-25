using Grpcdc;

namespace Echo;

/// <summary>
/// Reference Echo implementation (mirrors the Rust/JS/Go/Python/Java
/// demos): "fail" is rejected, everything else echoes.
/// </summary>
public sealed class EchoServiceImpl : EchoGrpcDc.EchoServer
{
    public EchoResponse Unary(Endpoint.CallContext ctx, EchoRequest req)
    {
        if (req.Message == "fail")
        {
            throw new StatusException(Wire.CodeInvalidArgument, "asked to fail");
        }
        if (req.DelayMs > 0) {
            System.Threading.Thread.Sleep(req.DelayMs);
        }
        string suffix = "";
        if (ctx.Metadata.TryGetValue("x-echo", out string marker) && !string.IsNullOrEmpty(marker))
        {
            suffix = $" [{marker}]";
        }
        if (ctx.Metadata.TryGetValue("x-echo-trailer", out string trailerMarker)
            && !string.IsNullOrEmpty(trailerMarker))
        {
            ctx.SetTrailers(new Dictionary<string, string> { ["x-echo-trailer"] = trailerMarker });
        }
        return new EchoResponse($"echo: {req.Message}{suffix}", 0);
    }

    public void ServerStream(EchoRequest req, EchoGrpcDc.EchoServerStreamServer stream)
    {
        if (req.Message == "fail")
        {
            throw new StatusException(Wire.CodeInvalidArgument, "asked to fail");
        }
        for (int i = 0; i < Math.Max(0, req.Count); i++)
        {
            stream.Send(new EchoResponse(req.Message, i));
        }
    }

    public void ClientStream(EchoGrpcDc.EchoClientStreamServer stream)
    {
        var parts = new List<string>();
        while (true)
        {
            EchoRequest req;
            try
            {
                req = stream.Recv();
            }
            catch (EndOfStreamException)
            {
                break;
            }
            parts.Add(req.Message);
        }
        stream.SendAndClose(new EchoResponse(string.Join("+", parts), parts.Count));
    }

    public void Bidi(EchoGrpcDc.EchoBidiServer stream)
    {
        int index = 0;
        while (true)
        {
            EchoRequest req;
            try
            {
                req = stream.Recv();
            }
            catch (EndOfStreamException)
            {
                return;
            }
            if (req.Message == "fail")
            {
                throw new StatusException(Wire.CodeInvalidArgument, "asked to fail");
            }
            stream.Send(new EchoResponse(req.Message, index++));
        }
    }
}
