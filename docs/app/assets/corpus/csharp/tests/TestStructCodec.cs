using Echo;
using Grpcdc;

namespace Tests;

/// <summary>Struct-codec negotiation: struct&lt;-&gt;struct roundtrip, mismatch rejected, plain still works.</summary>
public static class TestStructCodec
{
    private static EchoGrpcDc.EchoClient Setup(bool clientStruct, bool serverStruct)
    {
        (ITransport a, ITransport b) = MemoryTransport.Pair();
        var server = new Server();
        server.SetStructCodec(serverStruct);
        EchoGrpcDc.RegisterEchoServer(server, new EchoServiceImpl());
        server.ServeTransport(b);
        var channel = new Channel(a);
        channel.SetStructCodec(clientStruct);
        return new EchoGrpcDc.EchoClient(channel);
    }

    private static EchoRequest Req(string message, int count) => new(message, count, 0);

    public static void Run()
    {
        EchoGrpcDc.EchoClient client = Setup(true, true);

        EchoResponse unary = client.Unary(Req("hello", 0));
        Program.Check(unary.Message == "echo: hello", $"struct unary: {unary}");

        var stream = client.ServerStream(Req("tick", 3));
        int n = 0;
        while (true)
        {
            try
            {
                stream.Recv();
            }
            catch (EndOfStreamException)
            {
                break;
            }
            n++;
        }
        Program.Check(n == 3, $"struct server-stream count: {n}");

        EchoResponse joined = client.ClientStream(new[] { Req("a", 0), Req("b", 0) });
        Program.Check(joined.Message == "a+b", $"struct client-stream: {joined}");

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
        Program.Check(echoed.SequenceEqual(new[] { "x", "y" }), $"struct bidi: {string.Join(",", echoed)}");

        byte[] structBytes = Req("hello", 0).MarshalStruct();
        Program.Check(structBytes.Length > 4
            && structBytes[0] == (byte)'D' && structBytes[1] == (byte)'C'
            && structBytes[2] == (byte)'S' && structBytes[3] == (byte)'1',
            "struct magic missing");
        var back = new EchoRequest();
        back.UnmarshalStruct(structBytes);
        Program.Check(back.Message == "hello", $"struct roundtrip: {back.Message}");

        EchoGrpcDc.EchoClient mismatch = Setup(true, false);
        try
        {
            mismatch.Unary(Req("hello", 0));
            Program.Check(false, "struct client vs plain server should fail");
        }
        catch (StatusException e)
        {
            Program.Check(e.Code == Wire.CodeUnimplemented, $"mismatch status: {e}");
        }

        EchoGrpcDc.EchoClient plain = Setup(false, true);
        EchoResponse plainResp = plain.Unary(Req("hello", 0));
        Program.Check(plainResp.Message == "echo: hello", $"plain vs struct server: {plainResp}");

        Console.WriteLine("TestStructCodec OK");
    }
}
