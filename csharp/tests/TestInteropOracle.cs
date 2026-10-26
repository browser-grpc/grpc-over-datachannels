using System.Diagnostics;
using System.Net.Sockets;
using Echo;
using Grpc.testing;
using Grpcdc;

namespace Tests;

/// <summary>
/// Interop client grading: the generated C# TestService client
/// runs the canonical grpc interop cases (generated table:
/// InteropCases) against the official grpc-go TestServiceServer,
/// through the bridge (dc-to-http2, stdio = DataChannel). Mirrors
/// the Java/JS/Python/Go/Rust interop oracle suites. Skips when
/// the oracle server binary is not built (Dockerfile.ci builds it).
/// </summary>
public static class TestInteropOracle
{
    private static readonly string Root = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", ".."));

    private static Payload PayloadOf(int size) => new Payload(PayloadType.COMPRESSABLE, new byte[size]);

    private static StreamingOutputCallRequest StreamRequest(int[] respSizes, int payloadSize)
    {
        var req = new StreamingOutputCallRequest { Payload = PayloadOf(payloadSize) };
        foreach (int size in respSizes)
        {
            req.ResponseParameters.Add(new ResponseParameters { Size = size });
        }
        return req;
    }

    private static void ExpectStatus(int code, string message, string what, Action call)
    {
        try
        {
            call();
        }
        catch (StatusException e)
        {
            Program.Check(e.Code == code, $"{what}: code {e.Code} != {code}");
            if (message.Length > 0)
            {
                Program.Check(e.Message == message, $"{what}: message '{e.Message}' != '{message}'");
            }
            return;
        }
        throw new InvalidOperationException($"{what}: expected status {code}, call succeeded");
    }

    private static void RunCases(TestGrpcDc.TestServiceClient client, TestGrpcDc.UnimplementedServiceClient unimpl)
    {
        foreach (object[] row in InteropCases.Cases)
        {
            string name = (string)row[0];
            string kind = (string)row[1];
            int[] reqSizes = (int[])row[2];
            int[] respSizes = (int[])row[3];
            int statusCode = (int)row[4];
            string statusMessage = (string)row[5];
            switch (kind)
            {
                case "EMPTY":
                    client.EmptyCall(new Empty());
                    break;
                case "LARGE_UNARY":
                {
                    var req = new SimpleRequest { ResponseSize = respSizes[0], Payload = PayloadOf(reqSizes[0]) };
                    SimpleResponse resp = client.UnaryCall(req);
                    Program.Check(resp.Payload.Body.Length == respSizes[0], $"{name}: body {resp.Payload.Body.Length}");
                    break;
                }
                case "CLIENT_STREAMING":
                {
                    var reqs = reqSizes.Select(s => new StreamingInputCallRequest { Payload = PayloadOf(s) }).ToList();
                    StreamingInputCallResponse resp = client.StreamingInputCall(reqs);
                    Program.Check(resp.AggregatedPayloadSize == reqSizes.Sum(),
                        $"{name}: aggregated {resp.AggregatedPayloadSize} != {reqSizes.Sum()}");
                    break;
                }
                case "SERVER_STREAMING":
                {
                    using var stream = client.StreamingOutputCall(StreamRequest(respSizes, 0));
                    foreach (int size in respSizes)
                    {
                        StreamingOutputCallResponse resp = stream.Recv();
                        Program.Check(resp.Payload.Body.Length == size, $"{name}: body {resp.Payload.Body.Length} != {size}");
                    }
                    try
                    {
                        stream.Recv();
                        throw new InvalidOperationException($"{name}: expected EOF");
                    }
                    catch (EndOfStreamException)
                    {
                        // end of stream
                    }
                    break;
                }
                case "PING_PONG":
                {
                    var reqs = respSizes.Select((size, i) => StreamRequest(new[] { size }, reqSizes[i])).ToList();
                    using var stream = client.FullDuplexCall(reqs);
                    foreach (int size in respSizes)
                    {
                        StreamingOutputCallResponse resp = stream.Recv();
                        Program.Check(resp.Payload.Body.Length == size, $"{name}: body {resp.Payload.Body.Length} != {size}");
                    }
                    break;
                }
                case "EMPTY_STREAM":
                {
                    using var stream = client.FullDuplexCall(new List<StreamingOutputCallRequest>());
                    try
                    {
                        stream.Recv();
                        throw new InvalidOperationException($"{name}: expected EOF");
                    }
                    catch (EndOfStreamException)
                    {
                        // end of stream
                    }
                    break;
                }
                case "CUSTOM_METADATA":
                {
                    // Upstream custom_metadata, duplex leg (mirrors the Java runner).
                    string trailingBin = Convert.ToBase64String(new byte[] { 0x0a, 0x0b, 0x0a, 0x0b, 0x0a, 0x0b });
                    var md = new Dictionary<string, string>
                    {
                        ["x-grpc-test-echo-initial"] = "test_initial_metadata_value",
                        ["x-grpc-test-echo-trailing-bin"] = trailingBin,
                    };
                    using var stream = client.FullDuplexCall(new[] { StreamRequest(new[] { 1 }, 1) }, md);
                    StreamingOutputCallResponse resp = stream.Recv();
                    Program.Check(resp.Payload.Body.Length == 1, $"{name}: body");
                    try
                    {
                        stream.Recv();
                        throw new InvalidOperationException($"{name}: expected EOF");
                    }
                    catch (EndOfStreamException)
                    {
                        // end of stream: trailers now readable
                    }
                    Program.Check(stream.Headers != null
                        && stream.Headers.TryGetValue("x-grpc-test-echo-initial", out string initial)
                        && initial == "test_initial_metadata_value", $"{name}: initial metadata");
                    Program.Check(stream.Trailers != null
                        && stream.Trailers.TryGetValue("x-grpc-test-echo-trailing-bin", out string trailing)
                        && trailing == trailingBin, $"{name}: trailing metadata");
                    break;
                }
                case "STATUS_UNARY":
                {
                    var req = new SimpleRequest { ResponseStatus = new EchoStatus(statusCode, statusMessage) };
                    ExpectStatus(statusCode, statusMessage, name, () => client.UnaryCall(req));
                    break;
                }
                case "STATUS_DUPLEX":
                {
                    StreamingOutputCallRequest req = StreamRequest(new[] { 0 }, 0);
                    req.ResponseStatus = new EchoStatus(statusCode, statusMessage);
                    ExpectStatus(statusCode, statusMessage, name, () =>
                    {
                        using var stream = client.FullDuplexCall(new[] { req });
                        stream.Recv();
                    });
                    break;
                }
                case "UNIMPLEMENTED_METHOD":
                    ExpectStatus(statusCode, "", name, () => client.UnimplementedCall(new Empty()));
                    break;
                case "UNIMPLEMENTED_SERVICE":
                    ExpectStatus(statusCode, "", name, () => unimpl.UnimplementedCall(new Empty()));
                    break;
                default:
                    throw new InvalidOperationException("unknown interop kind " + kind);
            }
            Console.WriteLine("interop case ok: " + name);
        }
    }

    public static void Run()
    {
        string serverBin = Path.Combine(Root, "oracle", "go-interop", "interop-server");
        if (!File.Exists(serverBin))
        {
            Console.WriteLine("TestInteropOracle SKIP (go interop server not built)");
            return;
        }
        int port;
        using (var listener = new TcpListener(System.Net.IPAddress.Loopback, 0))
        {
            listener.Start();
            port = ((System.Net.IPEndPoint)listener.LocalEndpoint).Port;
        }
        var serverStart = new ProcessStartInfo(serverBin) { RedirectStandardOutput = true, RedirectStandardError = true };
        serverStart.ArgumentList.Add("-port");
        serverStart.ArgumentList.Add(port.ToString());
        using Process server = Process.Start(serverStart);
        server.StandardOutput.ReadToEndAsync();
        server.StandardError.ReadToEndAsync();
        try
        {
            // The Go server prints no readiness line; poll the port.
            long deadline = Environment.TickCount64 + 30000;
            bool ready = false;
            while (Environment.TickCount64 < deadline)
            {
                try
                {
                    using var sock = new TcpClient();
                    sock.Connect("127.0.0.1", port);
                    ready = true;
                    break;
                }
                catch (SocketException)
                {
                    Thread.Sleep(100);
                }
            }
            Program.Check(ready, "go interop server did not start");

            var bridgeStart = new ProcessStartInfo("node")
            {
                RedirectStandardInput = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            };
            bridgeStart.ArgumentList.Add(Path.Combine(Root, "oracle", "bridge.mjs"));
            bridgeStart.ArgumentList.Add("dc-to-http2");
            bridgeStart.ArgumentList.Add("--grpc");
            bridgeStart.ArgumentList.Add($"127.0.0.1:{port}");
            using Process bridge = Process.Start(bridgeStart);
            bridge.StandardError.ReadToEndAsync();
            try
            {
                var transport = new StdioTransport(bridge.StandardInput.BaseStream, bridge.StandardOutput.BaseStream);
                var channel = new Channel(transport);
                RunCases(new TestGrpcDc.TestServiceClient(channel), new TestGrpcDc.UnimplementedServiceClient(channel));
            }
            finally
            {
                bridge.Kill();
            }
        }
        finally
        {
            server.Kill();
        }
        Console.WriteLine("TestInteropOracle OK");
    }
}
