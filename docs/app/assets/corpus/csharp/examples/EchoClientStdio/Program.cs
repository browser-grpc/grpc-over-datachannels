using Echo;
using Grpcdc;

// Interop harness: the C# echo client over stdio. Prints one line
// per call shape to stderr (stdout carries frames) and exits non-zero
// on any failure. Mirrors go/examples/echo_client_stdio.
var transport = new StdioTransport(Console.OpenStandardOutput(), Console.OpenStandardInput());
var client = new EchoGrpcDc.EchoClient(new Channel(transport));

EchoRequest Req(string message, int count) => new(message, count, 0);

EchoResponse unary = client.Unary(Req("hello", 0));
Console.Error.WriteLine($"unary={unary.Message}");

var stream = client.ServerStream(Req("tick", 3));
var ticks = new List<string>();
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
    ticks.Add($"{resp.Message}#{resp.Index}");
}
Console.Error.WriteLine($"server_stream={string.Join(",", ticks)}");

EchoResponse joined = client.ClientStream(new[] { Req("a", 0), Req("b", 0), Req("c", 0) });
Console.Error.WriteLine($"client_stream={joined.Message}");

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
Console.Error.WriteLine($"bidi={string.Join(",", echoed)}");

var mdResp = client.Unary(Req("hello", 0), new Dictionary<string, string> { ["x-echo"] = "meta" });
Console.Error.WriteLine($"metadata={mdResp.Message}");

try
{
    var slow = Req("slow", 0);
    slow.DelayMs = 400;
    client.Unary(slow, null, TimeSpan.FromMilliseconds(50));
    Console.Error.WriteLine("deadline=no error");
}
catch (StatusException se)
{
    Console.Error.WriteLine($"deadline={(int)se.Code}");
}

try
{
    client.Unary(Req("fail", 0));
    Console.Error.WriteLine("error_case=no error");
    Environment.Exit(1);
}
catch (StatusException e)
{
    Console.Error.WriteLine($"error_case={e}");
}
