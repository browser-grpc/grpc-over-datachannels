using System.Diagnostics;
using System.Net.Sockets;
using System.Security.Cryptography.X509Certificates;
using Echo;
using Grpcdc;

namespace Tests;

/// <summary>
/// HTTP/2 oracle: the generated Grpcdc.Http2Transport dials the
/// official grpc-java OracleServer directly over TCP (no bridge) —
/// the C# end of the generated HTTP/2 client support. Plus a TLS
/// leg against the Node fixture (js/test/http2_tls_fixture.mjs,
/// ALPN h2). Skips when the oracle or fixtures are unavailable.
/// Mirrors go/http2_oracle_test.go.
/// </summary>
public static class TestHttp2Oracle
{
    public static void Run()
    {
        string root = TestOracle.Root;
        string cp = TestOracle.JavaClasspath();
        if (cp == null)
        {
            Console.WriteLine("TestHttp2Oracle SKIP (oracle not built)");
            return;
        }
        int port = TestOracle.FreePort();
        var serverStart = new ProcessStartInfo
        {
            FileName = "java",
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
        };
        serverStart.ArgumentList.Add("-cp");
        serverStart.ArgumentList.Add(cp);
        serverStart.ArgumentList.Add("dc.oracle.OracleServer");
        serverStart.ArgumentList.Add(port.ToString());
        using Process server = Process.Start(serverStart);
        try
        {
            string ready = null;
            while (ready == null)
            {
                string line = server.StandardError.ReadLine();
                Program.Check(line != null, "java oracle exited before READY");
                if (line.Contains("READY"))
                {
                    ready = line;
                }
            }
            var drain = new Thread(() =>
            {
                try
                {
                    while (server.StandardError.ReadLine() != null)
                    {
                    }
                }
                catch (Exception)
                {
                    // process gone
                }
            })
            { IsBackground = true };
            drain.Start();
            Http2Transport transport = Http2Transport.Dial($"127.0.0.1:{port}");

            var client = new EchoGrpcDc.EchoClient(new Channel(transport));
            TestOracle.RunScenarios(client);
            // Echoed initial metadata proves HEADERS metadata
            // made the round trip.
            EchoResponse md = client.Unary(new EchoRequest("hello", 0, 0),
                new Dictionary<string, string> { ["x-echo"] = "mval" });
            Program.Check(md.Message == "echo: hello [mval]", $"metadata echo: {md.Message}");
            // 200 responses x 1500-byte payloads: comfortably past
            // several 64KiB flow-control windows, so the call only
            // completes if stream/connection WINDOW_UPDATE
            // accounting replenishes.
            string big = new('y', 1500);
            var stream = client.ServerStream(new EchoRequest(big, 200, 0));
            int got = 0;
            try
            {
                while (true)
                {
                    EchoResponse resp = stream.Recv();
                    Program.Check(resp.Message == big && resp.Index == got, $"flow: {got}");
                    got++;
                }
            }
            catch (EndOfStreamException)
            {
                // end of stream
            }
            Program.Check(got == 200, $"flow: got {got}, want 200");
            transport.Close();
        }
        finally
        {
            server.Kill();
        }
        TlsLeg(root);
        Console.WriteLine("TestHttp2Oracle OK");
    }

    private static void TlsLeg(string root)
    {
        string fixture = Path.Combine(root, "js", "test", "http2_tls_fixture.mjs");
        if (!File.Exists(fixture))
        {
            Console.WriteLine("TestHttp2Oracle TLS SKIP (fixture missing)");
            return;
        }
        var start = new ProcessStartInfo
        {
            FileName = "node",
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
        };
        start.ArgumentList.Add(fixture);
        using Process proc = Process.Start(start);
        proc.ErrorDataReceived += (_, _) => { };
        proc.BeginErrorReadLine();
        try
        {
            string line = proc.StandardOutput.ReadLine();
            if (line == null || !line.StartsWith("READY"))
            {
                Console.WriteLine("TestHttp2Oracle TLS SKIP (fixture did not start)");
                return;
            }
            string[] fields = line.Split((char[])null, StringSplitOptions.RemoveEmptyEntries);
            int port = int.Parse(fields[1]);
            var cert = X509Certificate2.CreateFromPem(File.ReadAllText(fields[2]));
            Http2Transport transport = Http2Transport.DialTls(
                $"localhost:{port}", new X509Certificate2[] { cert }, "localhost");
            var client = new EchoGrpcDc.EchoClient(new Channel(transport));
            EchoResponse resp = client.Unary(new EchoRequest("hello", 0, 0));
            Program.Check(resp.Message == "echo: hello", $"tls unary: {resp.Message}");
            transport.Close();
        }
        finally
        {
            proc.Kill();
        }
    }
}
