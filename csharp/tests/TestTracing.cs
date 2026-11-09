using Echo;
using Grpcdc;

namespace Tests;

/// <summary>Tracing: nested callee call joins the trace via the bound channel.</summary>
public static class TestTracing
{
    private sealed record Start(string Kind, string Method, string TraceId, string SpanId, string ParentSpanId);

    private sealed class Recorder : Tracing.ITracer
    {
        public readonly List<Start> Starts = new();
        public readonly List<double> EndDurations = new();

        public void OnStart(string kind, string method, string traceId, string spanId, string parentSpanId)
        {
            lock (Starts) Starts.Add(new Start(kind, method, traceId, spanId, parentSpanId));
        }

        public void OnEnd(string kind, string method, string traceId, string spanId, string status, double durationMs)
        {
            lock (EndDurations) EndDurations.Add(durationMs);
        }
    }

    private sealed class Front : EchoGrpcDc.EchoServer
    {
        private readonly EchoServiceImpl _inner = new();
        private readonly Channel _downstreamChannel;
        public string SeenSpan;

        public Front(Channel downstreamChannel) => _downstreamChannel = downstreamChannel;

        public EchoResponse Unary(Endpoint.CallContext ctx, EchoRequest req)
        {
            SeenSpan = ctx.TraceContext?.SpanId;
            var bound = new EchoGrpcDc.EchoClient(_downstreamChannel.WithTraceContext(ctx.TraceContext));
            return bound.Unary(new EchoRequest("nested", 0, 0));
        }

        public void ServerStream(EchoRequest req, EchoGrpcDc.EchoServerStreamServer stream) =>
            _inner.ServerStream(req, stream);

        public void ClientStream(EchoGrpcDc.EchoClientStreamServer stream) => _inner.ClientStream(stream);

        public void Bidi(EchoGrpcDc.EchoBidiServer stream) => _inner.Bidi(stream);
    }

    public static void Run()
    {
        var rec = new Recorder();
        Tracing.SetTracer(rec);
        try
        {
            (ITransport a2, ITransport b2) = MemoryTransport.Pair();
            var back = new Server();
            EchoGrpcDc.RegisterEchoServer(back, new EchoServiceImpl());
            back.ServeTransport(b2);
            var downstreamChannel = new Channel(a2);

            var front = new Front(downstreamChannel);
            (ITransport a, ITransport b) = MemoryTransport.Pair();
            var frontServer = new Server();
            EchoGrpcDc.RegisterEchoServer(frontServer, front);
            frontServer.ServeTransport(b);
            var client = new EchoGrpcDc.EchoClient(new Channel(a));

            EchoResponse resp = client.Unary(new EchoRequest("hello", 0, 0));
            Program.Check(resp.Message == "echo: nested", "resp " + resp.Message);

            List<Start> starts;
            lock (rec.Starts) starts = new List<Start>(rec.Starts);
            Program.Check(starts.Count == 4, "starts " + starts.Count);
            Program.Check(starts[0].Kind == "client" && starts[1].Kind == "server"
                && starts[2].Kind == "client" && starts[3].Kind == "server", "kinds");
            Program.Check(starts.All(s => s.TraceId == starts[0].TraceId), "trace ids");
            Program.Check(starts[1].ParentSpanId == starts[0].SpanId, "server parent");
            Program.Check(starts[2].ParentSpanId == starts[1].SpanId, "inner client parent");
            Program.Check(starts[3].ParentSpanId == starts[2].SpanId, "inner server parent");
            Program.Check(front.SeenSpan == starts[1].SpanId, "ctx span");
            lock (rec.EndDurations)
            {
                Program.Check(rec.EndDurations.Count == 4 && rec.EndDurations.All(d => d >= 0), "durations");
            }
            Console.WriteLine("TestTracing OK");
        }
        finally
        {
            Tracing.SetTracer(null);
        }
    }
}
