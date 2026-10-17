using Echo;
using Grpcdc;

namespace Tests;

/// <summary>Deadlines: grpc-timeout propagation + DEADLINE_EXCEEDED enforcement.</summary>
public static class TestDeadline
{
    private sealed class SlowEcho : EchoGrpcDc.EchoServer
    {
        private readonly EchoServiceImpl _inner = new();
        public Endpoint.CallContext SeenCtx;

        public EchoResponse Unary(Endpoint.CallContext ctx, EchoRequest req)
        {
            SeenCtx = ctx;
            Thread.Sleep(400);
            return _inner.Unary(ctx, req);
        }

        public void ServerStream(EchoRequest req, EchoGrpcDc.EchoServerStreamServer stream)
        {
            for (int i = 0; i < Math.Max(0, req.Count); i++)
            {
                if (i > 0)
                {
                    Thread.Sleep(300);
                }
                stream.Send(new EchoResponse(req.Message, i));
            }
        }

        public void ClientStream(EchoGrpcDc.EchoClientStreamServer stream) => _inner.ClientStream(stream);

        public void Bidi(EchoGrpcDc.EchoBidiServer stream) => _inner.Bidi(stream);
    }

    private static EchoRequest Req(string message, int count) => new(message, count, 0);

    public static void Run()
    {
        Program.Check(
            Codec.ParseTimeout(Codec.EncodeTimeout(TimeSpan.FromMilliseconds(250)))
                == TimeSpan.FromMilliseconds(250),
            "timeout round trip");
        Program.Check(Codec.ParseTimeout("10x") == null, "junk timeout");

        (ITransport a, ITransport b) = MemoryTransport.Pair();
        var server = new Server();
        var slow = new SlowEcho();
        EchoGrpcDc.RegisterEchoServer(server, slow);
        server.ServeTransport(b);
        var client = new EchoGrpcDc.EchoClient(new Channel(a));

        long start = System.Diagnostics.Stopwatch.GetTimestamp();
        try
        {
            client.Unary(Req("hello", 0), null, TimeSpan.FromMilliseconds(50));
            throw new Exception("expected deadline");
        }
        catch (StatusException e)
        {
            Program.Check(e.Code == Wire.CodeDeadlineExceeded, "code " + e.Code);
        }
        double elapsedMs = (System.Diagnostics.Stopwatch.GetTimestamp() - start) * 1000.0
            / System.Diagnostics.Stopwatch.Frequency;
        Program.Check(elapsedMs < 350, $"deadline fast ({elapsedMs}ms)");

        Program.Check(slow.SeenCtx != null, "handler ran");
        Program.Check(slow.SeenCtx.Metadata.ContainsKey("grpc-timeout"), "grpc-timeout metadata");
        Program.Check(slow.SeenCtx.Deadline != null, "ctx deadline");
        Program.Check(slow.SeenCtx.TimeRemaining() != null, "ctx remaining");

        var stream = client.ServerStream(Req("tick", 5), null, TimeSpan.FromMilliseconds(150));
        Program.Check(stream.Recv().Index == 0, "stream first");
        try
        {
            stream.Recv();
            throw new Exception("expected stream deadline");
        }
        catch (StatusException e)
        {
            Program.Check(e.Code == Wire.CodeDeadlineExceeded, "stream code " + e.Code);
        }

        EchoResponse joined = client.ClientStream(
            new[] { Req("a", 0), Req("b", 0) }, null, TimeSpan.FromSeconds(5));
        Program.Check(joined.Message == "a+b", "generous timeout: " + joined);
    }
}
