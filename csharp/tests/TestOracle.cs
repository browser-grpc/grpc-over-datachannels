using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using Echo;
using Grpcdc;

namespace Tests;

/// <summary>
/// Oracle tests: the official grpc-java implementation, bridged over
/// TCP&lt;-&gt;DataChannel by ../../oracle/bridge.mjs, must agree with
/// this (generated) C# runtime on every case of the generated
/// scenario table (OracleScenarios, stamped from
/// racket/oracle-spec.rkt). Skips when the oracle or bridge are
/// unavailable (Dockerfile.ci provides both). Mirrors go/oracle_test.go.
/// </summary>
public static class TestOracle
{
    private static readonly string Root = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", ".."));

    private static string JavaClasspath()
    {
        string target = Path.Combine(Root, "oracle", "java", "target");
        string cpFile = Path.Combine(target, "cp.txt");
        if (!File.Exists(cpFile) || !Directory.Exists(Path.Combine(target, "classes")))
        {
            return null;
        }
        return Path.Combine(target, "classes") + ":" + File.ReadAllText(cpFile).Trim();
    }

    private static int FreePort()
    {
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        int port = ((IPEndPoint)listener.LocalEndpoint).Port;
        listener.Stop();
        return port;
    }

    private static string Unmsg(string token) => token == "-" ? "" : token;

    private static void RunScenarios(EchoGrpcDc.EchoClient client)
    {
        foreach (object[] row in OracleScenarios.Cases)
        {
            string kind = (string)row[0];
            string[] rawMessages = (string[])row[1];
            int count = (int)row[2];
            int expectStatus = (int)row[3];
            var messages = rawMessages.Select(Unmsg).ToList();
            string line = kind + " " + string.Join(" ", rawMessages);
            switch (kind)
            {
                case "UNARY":
                {
                    string message = messages[0];
                    try
                    {
                        EchoResponse resp = client.Unary(new EchoRequest(message, 0, 0));
                        Program.Check(expectStatus < 0, $"{line}: expected failure, got {resp}");
                        Program.Check(resp.Message == "echo: " + message && resp.Index == 0, $"{line}: {resp}");
                    }
                    catch (StatusException e)
                    {
                        Program.Check(expectStatus >= 0 && e.Code == expectStatus,
                            $"{line}: status {e}, want {expectStatus}");
                    }
                    break;
                }
                case "SERVER_STREAM":
                {
                    string message = messages[0];
                    var stream = client.ServerStream(new EchoRequest(message, count, 0));
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
                        Program.Check(resp.Message == message && resp.Index == got, $"{line}: {resp} at {got}");
                        got++;
                    }
                    Program.Check(got == count, $"{line}: got {got}, want {count}");
                    break;
                }
                case "CLIENT_STREAM":
                {
                    EchoResponse resp = client.ClientStream(messages.Select(m => new EchoRequest(m, 0, 0)).ToList());
                    Program.Check(resp.Message == string.Join("+", messages) && resp.Index == messages.Count,
                        $"{line}: {resp}");
                    break;
                }
                case "BIDI":
                {
                    var stream = client.Bidi(messages.Select(m => new EchoRequest(m, 0, 0)).ToList());
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
                        Program.Check(got < messages.Count && resp.Message == messages[got] && resp.Index == got,
                            $"{line}: {resp} at {got}");
                        got++;
                    }
                    Program.Check(got == messages.Count, $"{line}: got {got}");
                    break;
                }
                default:
                    throw new Exception($"unknown scenario kind: {kind}");
            }
        }
    }

    public static void Run()
    {
        string cp = JavaClasspath();
        if (cp == null)
        {
            Console.WriteLine("TestOracle SKIP (java oracle not built)");
            return;
        }
        string javaBin = "java";

        // Direction A: this runtime's client -> bridge -> official server.
        int port = FreePort();
        var serverStart = new ProcessStartInfo(javaBin) { RedirectStandardError = true };
        serverStart.ArgumentList.Add("-cp");
        serverStart.ArgumentList.Add(cp);
        serverStart.ArgumentList.Add("dc.oracle.OracleServer");
        serverStart.ArgumentList.Add(port.ToString());
        using (Process server = Process.Start(serverStart))
        {
            bool ready = false;
            while (server.StandardError.ReadLine() is { } line)
            {
                if (line.Contains("READY"))
                {
                    ready = true;
                    break;
                }
            }
            if (!ready)
            {
                Console.WriteLine("TestOracle SKIP (oracle server did not start)");
                return;
            }
            var bridgeStart = new ProcessStartInfo("node")
            { RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true };
            bridgeStart.ArgumentList.Add(Path.Combine(Root, "oracle", "bridge.mjs"));
            bridgeStart.ArgumentList.Add("dc-to-http2");
            bridgeStart.ArgumentList.Add("--grpc");
            bridgeStart.ArgumentList.Add($"127.0.0.1:{port}");
            using Process bridge = Process.Start(bridgeStart);
            try
            {
                var transport = new StdioTransport(bridge.StandardInput.BaseStream, bridge.StandardOutput.BaseStream);
                var client = new EchoGrpcDc.EchoClient(new Channel(transport));
                RunScenarios(client);
            }
            finally
            {
                bridge.Kill();
            }
            server.Kill();
        }

        // Direction B: official client -> bridge -> this runtime's server.
        int portB = FreePort();
        string csharpDir = Path.Combine(Root, "csharp");
        string serverDllPath = Path.GetFullPath(Path.Combine(csharpDir,
            "examples", "EchoServerStdio", "bin", "Debug", "net8.0", "EchoServerStdio.dll"));
        if (!File.Exists(serverDllPath))
        {
            Console.WriteLine("TestOracle SKIP (csharp server not built)");
            return;
        }
        string serverCmd = $"dotnet \"{serverDllPath}\"";
        var bridgeStartB = new ProcessStartInfo("node") { RedirectStandardError = true };
        bridgeStartB.ArgumentList.Add(Path.Combine(Root, "oracle", "bridge.mjs"));
        bridgeStartB.ArgumentList.Add("http2-to-dc");
        bridgeStartB.ArgumentList.Add("--port");
        bridgeStartB.ArgumentList.Add(portB.ToString());
        bridgeStartB.ArgumentList.Add("--target-cmd");
        bridgeStartB.ArgumentList.Add(serverCmd);
        using (Process bridge = Process.Start(bridgeStartB))
        {
            string firstLine = bridge.StandardError.ReadLine();
            if (firstLine == null || !firstLine.Contains("listening"))
            {
                Console.WriteLine($"TestOracle SKIP (bridge did not start): {firstLine}");
                return;
            }
            var clientStart = new ProcessStartInfo(javaBin)
            { RedirectStandardOutput = true, RedirectStandardError = true };
            clientStart.ArgumentList.Add("-cp");
            clientStart.ArgumentList.Add(cp);
            clientStart.ArgumentList.Add("dc.oracle.OracleClient");
            clientStart.ArgumentList.Add(portB.ToString());
            clientStart.ArgumentList.Add(Path.Combine(Root, "fixtures", "oracle_scenarios.txt"));
            using Process client = Process.Start(clientStart);
            string output = client.StandardOutput.ReadToEnd() + client.StandardError.ReadToEnd();
            if (!client.WaitForExit(120_000))
            {
                throw new Exception("oracle client timed out");
            }
            Program.Check(client.ExitCode == 0, $"oracle client failed:\n{output}");
            Program.Check(output.Contains("ORACLE CLIENT: ALL OK"), $"oracle client output:\n{output}");
            bridge.Kill();
        }

        Console.WriteLine("TestOracle OK");
    }
}
