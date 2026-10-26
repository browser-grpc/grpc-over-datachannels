using Echo;
using Grpcdc;

namespace Tests;

/// <summary>BDD: interprets the generated behavior scenarios
/// (BddScenarios, generated from the BDD specification; prose in BDD.md)
/// against a loopback client+server — the executable examples.</summary>
public static class TestBdd
{
    private static EchoRequest Req(string message, int count) => new(message, count, 0);

    /// <summary>Counting service for the stream-break scenario.</summary>
    private sealed class CountingEchoService : EchoGrpcDc.EchoServer
    {
        public int Produced;

        public EchoResponse Unary(Endpoint.CallContext ctx, EchoRequest req)
            => new($"echo: {req.Message}", 0);

        public void ServerStream(EchoRequest req, EchoGrpcDc.EchoServerStreamServer stream)
        {
            for (int i = 0; i < Math.Max(0, req.Count); i++)
            {
                System.Threading.Interlocked.Increment(ref Produced);
                stream.Send(new EchoResponse(req.Message, i));
                System.Threading.Thread.Sleep(10);
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

    public static void Run()
    {
        (ITransport a, ITransport b) = MemoryTransport.Pair();
        var server = new Server();
        EchoGrpcDc.RegisterEchoServer(server, new EchoServiceImpl());
        server.ServeTransport(b);
        var channel = new Channel(a);
        var client = new EchoGrpcDc.EchoClient(channel);

        foreach (object[] row in BddScenarios.Cases)
        {
            string name = (string)row[0];
            string kind = (string)row[1];
            string[] messages = (string[])row[2];
            int count = (int)row[3];
            string path = (string)row[4];
            string metadata = (string)row[5];
            string expectMessage = (string)row[6];
            int expectNum = (int)row[7];
            int expectStatus = (int)row[8];

            switch (kind)
            {
                case "unary-trailer":
                {
                    var stream = channel.ServerStream("/echo.Echo/Unary", Req(messages[0], 0),
                        new Dictionary<string, string> { ["x-echo-trailer"] = metadata });
                    var resp = new EchoResponse();
                    stream.Recv(resp);
                    Program.Check(resp.Message == expectMessage && resp.Index == expectNum,
                        $"{name}: {resp}");
                    try
                    {
                        stream.Recv(new EchoResponse());
                        Program.Check(false, $"{name}: expected EOF");
                    }
                    catch (System.IO.EndOfStreamException)
                    {
                        // expected: trailers end the stream
                    }
                    Program.Check(stream.Trailers != null
                            && stream.Trailers.GetValueOrDefault("x-echo-trailer") == metadata,
                        $"{name}: trailer {(stream.Trailers == null ? "null" : "mismatch")}");
                    break;
                }
                case "unary":
                {
                    var md = metadata.Length == 0
                        ? null
                        : new Dictionary<string, string> { ["x-echo"] = metadata };
                    try
                    {
                        EchoResponse resp = client.Unary(Req(messages[0], 0), md);
                        Program.Check(expectStatus < 0, $"{name}: expected failure, got {resp}");
                        Program.Check(resp.Message == expectMessage && resp.Index == expectNum,
                            $"{name}: {resp}");
                    }
                    catch (StatusException e)
                    {
                        Program.Check(expectStatus >= 0 && e.Code == expectStatus,
                            $"{name}: status {e.Code}, want {expectStatus}");
                    }
                    break;
                }
                case "server-stream":
                {
                    var stream = client.ServerStream(Req(messages[0], count));
                    int got = 0;
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
                        Program.Check(resp.Message == expectMessage && resp.Index == got,
                            $"{name}: {resp} at {got}");
                        got++;
                    }
                    Program.Check(got == expectNum, $"{name}: got {got}, want {expectNum}");
                    break;
                }
                case "client-stream":
                {
                    EchoResponse resp = client.ClientStream(messages.Select(m => Req(m, 0)).ToArray());
                    Program.Check(resp.Message == expectMessage && resp.Index == expectNum,
                        $"{name}: {resp}");
                    break;
                }
                case "bidi":
                {
                    var stream = client.Bidi(messages.Select(m => Req(m, 0)).ToArray());
                    int got = 0;
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
                        Program.Check(got < messages.Length && resp.Message == messages[got]
                                && resp.Index == got,
                            $"{name}: {resp} at {got}");
                        got++;
                    }
                    Program.Check(got == expectNum, $"{name}: got {got}, want {expectNum}");
                    break;
                }
                case "server-stream-fail":
                {
                    var stream = client.ServerStream(Req(messages[0], count));
                    try
                    {
                        while (true) stream.Recv();
                    }
                    catch (StatusException e)
                    {
                        Program.Check(e.Code == expectStatus,
                            $"{name}: status {e.Code}, want {expectStatus}");
                    }
                    catch (EndOfStreamException)
                    {
                        Program.Check(false, $"{name}: expected failure, stream ended OK");
                    }
                    break;
                }
                case "bidi-fail":
                {
                    var stream = client.Bidi(messages.Select(m => Req(m, 0)).ToArray());
                    try
                    {
                        while (true) stream.Recv();
                    }
                    catch (StatusException e)
                    {
                        Program.Check(e.Code == expectStatus,
                            $"{name}: status {e.Code}, want {expectStatus}");
                    }
                    catch (EndOfStreamException)
                    {
                        Program.Check(false, $"{name}: expected failure, stream ended OK");
                    }
                    break;
                }
                case "deadline":
                {
                    try
                    {
                        client.Unary(new EchoRequest(messages[0], 0, count), null,
                            TimeSpan.FromMilliseconds(100));
                        Program.Check(false, $"{name}: expected deadline failure");
                    }
                    catch (StatusException e)
                    {
                        Program.Check(e.Code == expectStatus,
                            $"{name}: status {e.Code}, want {expectStatus}");
                    }
                    break;
                }
                case "cancel":
                {
                    var stream = channel.ServerStream("/echo.Echo/ServerStream",
                        Req(messages[0], count));
                    var first = new EchoResponse();
                    stream.Recv(first);
                    Program.Check(first.Message == messages[0], $"{name}: first {first}");
                    stream.Cancel();
                    bool terminated = false;
                    try
                    {
                        for (int i = 0; i < count + 2 && !terminated; i++)
                        {
                            stream.Recv(new EchoResponse());
                        }
                    }
                    catch (Exception)
                    {
                        terminated = true;
                    }
                    Program.Check(terminated, $"{name}: stream did not terminate after cancel");
                    break;
                }
                case "stream-break":
                {
                    // Dedicated counting server (like the Go BDD
                    // runner): reading one response and then
                    // abandoning the stream by disposing it (no
                    // explicit cancel) must RST the call so the
                    // server stops producing.
                    var service = new CountingEchoService();
                    (ITransport ba, ITransport bb) = MemoryTransport.Pair();
                    var bserver = new Server();
                    EchoGrpcDc.RegisterEchoServer(bserver, service);
                    bserver.ServeTransport(bb);
                    var bclient = new EchoGrpcDc.EchoClient(new Channel(ba));
                    var breakStream = bclient.ServerStream(Req(messages[0], count));
                    EchoResponse first = breakStream.Recv();
                    Program.Check(first.Message == messages[0], $"{name}: first {first}");
                    breakStream.Dispose();
                    System.Threading.Thread.Sleep(150);
                    int settled = System.Threading.Volatile.Read(ref service.Produced);
                    System.Threading.Thread.Sleep(150);
                    Program.Check(System.Threading.Volatile.Read(ref service.Produced) == settled,
                        $"{name}: server kept producing {settled} -> {service.Produced}");
                    Program.Check(settled < 50, $"{name}: server produced too many: {settled}");
                    break;
                }
                case "raw-unary":
                {
                    try
                    {
                        channel.Unary(path, Req(messages[0], 0), new EchoResponse());
                        Program.Check(false, $"{name}: expected failure");
                    }
                    catch (StatusException e)
                    {
                        Program.Check(e.Code == expectStatus,
                            $"{name}: status {e.Code}, want {expectStatus}");
                    }
                    break;
                }
                default:
                    throw new Exception($"unknown bdd kind: {kind}");
            }
        }
        Console.WriteLine("TestBdd OK");
    }
}
