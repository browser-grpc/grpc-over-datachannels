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

        await RunBreakStreamCancelsServer();
    }

    /// <summary>Counting service for the stream-break regression test.</summary>
    private sealed class CountingEchoService : EchoGrpcDc.EchoServer
    {
        public int Produced;

        public EchoResponse Unary(Endpoint.CallContext ctx, EchoRequest req)
            => new($"echo: {req.Message}", 0);

        public void ServerStream(EchoRequest req, EchoGrpcDc.EchoServerStreamServer stream)
        {
            for (int i = 0; i < Math.Max(0, req.Count); i++)
            {
                Interlocked.Increment(ref Produced);
                stream.Send(new EchoResponse(req.Message, i));
                Thread.Sleep(10);
            }
        }

        public void ClientStream(EchoGrpcDc.EchoClientStreamServer stream)
        {
            var parts = new List<string>();
            while (true)
            {
                try
                {
                    parts.Add(stream.Recv().Message);
                }
                catch (EndOfStreamException)
                {
                    break;
                }
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
                stream.Send(new EchoResponse(req.Message, index++));
            }
        }
    }

    // Breaking out of await foreach after one response must RST
    // the call: the producing handler's next send fails with
    // CANCELLED and production settles well below the total.
    private static async Task RunBreakStreamCancelsServer()
    {
        var service = new CountingEchoService();
        (ITransport a, ITransport b) = MemoryTransport.Pair();
        var server = new Server();
        EchoGrpcDc.RegisterEchoServer(server, service);
        server.ServeTransport(b);
        var client = new EchoGrpcDc.EchoClient(new Channel(a));

        int seen = 0;
        await foreach (EchoResponse resp in client.ServerStreamAsync(Req("tick", 1000)))
        {
            Program.Check(resp.Index == 0, $"break stream first response: {resp}");
            seen++;
            break;
        }
        Program.Check(seen == 1, $"break stream seen: {seen}");

        await Task.Delay(100);
        int settled = Volatile.Read(ref service.Produced);
        await Task.Delay(100);
        Program.Check(Volatile.Read(ref service.Produced) == settled,
            $"server kept producing after break: {settled} -> {service.Produced}");
        Program.Check(settled < 100, $"server produced too many responses: {settled}");
    }
}
