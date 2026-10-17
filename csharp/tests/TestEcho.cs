using Echo;
using Grpcdc;

namespace Tests;

/// <summary>Loopback end-to-end: all four shapes, error status, metadata.</summary>
public static class TestEcho
{
    private static EchoGrpcDc.EchoClient Setup()
    {
        (ITransport a, ITransport b) = MemoryTransport.Pair();
        var server = new Server();
        EchoGrpcDc.RegisterEchoServer(server, new EchoServiceImpl());
        server.ServeTransport(b);
        return new EchoGrpcDc.EchoClient(new Channel(a));
    }

    private static EchoRequest Req(string message, int count) => new(message, count, 0);

    public static void Run()
    {
        EchoGrpcDc.EchoClient client = Setup();

        EchoResponse unary = client.Unary(Req("hello", 0));
        Program.Check(unary.Message == "echo: hello" && unary.Index == 0, $"unary: {unary}");

        var stream = client.ServerStream(Req("tick", 3));
        var indexes = new List<int>();
        while (true)
        {
            EchoResponse resp;
            try
            {
                resp = stream.Recv();
            }
            catch (EndOfStreamException)
            {
                break;
            }
            Program.Check(resp.Message == "tick", $"stream message: {resp}");
            indexes.Add(resp.Index);
        }
        Program.Check(indexes.SequenceEqual(new[] { 0, 1, 2 }), $"stream indexes: {string.Join(",", indexes)}");

        EchoResponse joined = client.ClientStream(new[] { Req("a", 0), Req("b", 0), Req("c", 0) });
        Program.Check(joined.Message == "a+b+c" && joined.Index == 3, $"client stream: {joined}");

        var bidi = client.Bidi(new[] { Req("x", 0), Req("y", 0) });
        var echoed = new List<string>();
        while (true)
        {
            EchoResponse resp;
            try
            {
                resp = bidi.Recv();
            }
            catch (EndOfStreamException)
            {
                break;
            }
            echoed.Add(resp.Message);
        }
        Program.Check(echoed.SequenceEqual(new[] { "x", "y" }), $"bidi: {string.Join(",", echoed)}");

        try
        {
            client.Unary(Req("fail", 0));
            Program.Check(false, "fail call should throw");
        }
        catch (StatusException e)
        {
            Program.Check(e.Code == 3, $"fail status: {e}");
        }

        EchoResponse withMd = client.Unary(Req("hello", 0),
            new Dictionary<string, string> { ["x-echo"] = "meta" });
        Program.Check(withMd.Message == "echo: hello [meta]", $"metadata: {withMd}");

        RunAsync().GetAwaiter().GetResult();

        Console.WriteLine("TestEcho OK");
    }

    /// <summary>Async implementation used to test RegisterEchoServerAsync.</summary>
    private sealed class AsyncEchoService : EchoGrpcDc.EchoServerAsync
    {
        private readonly EchoServiceImpl _inner = new();

        public async Task<EchoResponse> UnaryAsync(Endpoint.CallContext ctx, EchoRequest req)
        {
            await Task.Delay(1);
            return _inner.Unary(ctx, req);
        }

        public async Task ServerStreamAsync(EchoRequest req, EchoGrpcDc.EchoServerStreamServer stream)
        {
            await Task.Delay(1);
            _inner.ServerStream(req, stream);
        }

        public async Task ClientStreamAsync(EchoGrpcDc.EchoClientStreamServer stream)
        {
            await Task.Delay(1);
            _inner.ClientStream(stream);
        }

        public async Task BidiAsync(EchoGrpcDc.EchoBidiServer stream)
        {
            await Task.Delay(1);
            _inner.Bidi(stream);
        }
    }

    private static async Task RunAsync()
    {
        // Async client surface against the sync loopback server.
        EchoGrpcDc.EchoClient client = Setup();

        EchoResponse unary = await client.UnaryAsync(Req("hello", 0));
        Program.Check(unary.Message == "echo: hello", $"async unary: {unary}");

        var indexes = new List<int>();
        await foreach (EchoResponse resp in client.ServerStreamAsync(Req("tick", 3)))
        {
            indexes.Add(resp.Index);
        }
        Program.Check(indexes.SequenceEqual(new[] { 0, 1, 2 }), $"async stream: {string.Join(",", indexes)}");

        EchoResponse joined = await client.ClientStreamAsync(new[] { Req("a", 0), Req("b", 0) });
        Program.Check(joined.Message == "a+b", $"async client stream: {joined}");

        var echoed = new List<string>();
        await foreach (EchoResponse resp in client.BidiAsync(new[] { Req("x", 0), Req("y", 0) }))
        {
            echoed.Add(resp.Message);
        }
        Program.Check(echoed.SequenceEqual(new[] { "x", "y" }), $"async bidi: {string.Join(",", echoed)}");

        // Status errors propagate through the Task surface.
        try
        {
            await client.UnaryAsync(Req("fail", 0));
            Program.Check(false, "async fail should throw");
        }
        catch (StatusException e)
        {
            Program.Check(e.Code == 3, $"async fail status: {e}");
        }

        // Cancellation is honored at the Task layer.
        using var cts = new CancellationTokenSource();
        cts.Cancel();
        try
        {
            await client.UnaryAsync(Req("hello", 0), null, cancellationToken: cts.Token);
            Program.Check(false, "cancelled call should throw");
        }
        catch (OperationCanceledException)
        {
            // expected (TaskCanceledException derives from it)
        }

        // Async server surface against the sync client.
        (ITransport a, ITransport b) = MemoryTransport.Pair();
        var server = new Server();
        EchoGrpcDc.RegisterEchoServerAsync(server, new AsyncEchoService());
        server.ServeTransport(b);
        var syncClient = new EchoGrpcDc.EchoClient(new Channel(a));
        EchoResponse viaAsync = syncClient.Unary(Req("hello", 0));
        Program.Check(viaAsync.Message == "echo: hello", $"async server unary: {viaAsync}");
    }
}
