using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using Echo;
using Grpcdc;

namespace Tests;

/// <summary>
/// Dynamic (descriptor-driven) runtime: schemas consumed as data at
/// runtime, no generated stubs. Loopback plus the official grpc-java
/// oracle in both directions (the oracle is the runtime test bed).
/// </summary>
public static class TestDynamic
{
    private static readonly string Root = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", ".."));
    private const string Service = "echo.Echo";

    private static Dynamic.FileModel LoadModel()
    {
        string path = Path.Combine(Root, "fixtures", "echo_descriptor_set.bin");
        if (!File.Exists(path))
        {
            return null;
        }
        return Dynamic.ParseDescriptorSet(File.ReadAllBytes(path));
    }

    private static Dynamic.GenericMessage Req(Dynamic.FileModel model, string message, long count)
    {
        return new Dynamic.GenericMessage(model.Messages[".echo.EchoRequest"])
            .Set(1, message).Set(2, count);
    }

    private static List<Dynamic.GenericMessage> Reqs(Dynamic.FileModel model, List<string> messages)
    {
        return messages.Select(m => Req(model, m, 0)).ToList();
    }

    private static string Unmsg(string token) => token == "-" ? "" : token;

    private static void RunScenarios(Dynamic.DynamicClient client, Dynamic.FileModel model)
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
                    try
                    {
                        Dynamic.GenericMessage resp = client.Unary(Service, "Unary", Req(model, messages[0], 0));
                        Program.Check(expectStatus < 0, $"{line}: expected failure, got {resp}");
                        Program.Check(resp.GetString(1) == "echo: " + messages[0] && resp.GetInt(2) == 0,
                            $"{line}: {resp}");
                    }
                    catch (StatusException e)
                    {
                        Program.Check(expectStatus >= 0 && e.Code == expectStatus,
                            $"{line}: status {e}, want {expectStatus}");
                    }
                    break;
                case "SERVER_STREAM":
                {
                    var stream = client.ServerStream(Service, "ServerStream", Req(model, messages[0], count));
                    int got = 0;
                    while (true)
                    {
                        Dynamic.GenericMessage resp;
                        try
                        {
                            resp = stream.Recv();
                        }
                        catch (EndOfStreamException)
                        {
                            break;
                        }
                        Program.Check(resp.GetString(1) == messages[0] && resp.GetInt(2) == got,
                            $"{line}: {resp} at {got}");
                        got++;
                    }
                    Program.Check(got == count, $"{line}: got {got}, want {count}");
                    break;
                }
                case "CLIENT_STREAM":
                {
                    Dynamic.GenericMessage resp = client.ClientStream(Service, "ClientStream", Reqs(model, messages));
                    Program.Check(resp.GetString(1) == string.Join("+", messages) && resp.GetInt(2) == messages.Count,
                        $"{line}: {resp}");
                    break;
                }
                case "BIDI":
                {
                    var stream = client.Bidi(Service, "Bidi", Reqs(model, messages));
                    int got = 0;
                    while (true)
                    {
                        Dynamic.GenericMessage resp;
                        try
                        {
                            resp = stream.Recv();
                        }
                        catch (EndOfStreamException)
                        {
                            break;
                        }
                        Program.Check(got < messages.Count && resp.GetString(1) == messages[got] && resp.GetInt(2) == got,
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

    public static void Run()
    {
        Dynamic.FileModel model = LoadModel();
        if (model == null)
        {
            Console.WriteLine("TestDynamic SKIP (descriptor fixture missing)");
            return;
        }

        // Generic codec + unknown-field retention round trip.
        Dynamic.MessageModel requestType = model.Messages[".echo.EchoRequest"];
        byte[] payload =
        {
            0x0a, 0x02, (byte)'h', (byte)'i', 0x10, 0x02,
            0x98, 0x06, 0x2a, 0xa2, 0x06, 0x01, (byte)'x',
        };
        Dynamic.GenericMessage decoded = Dynamic.DecodeGeneric(requestType, payload, model);
        Program.Check(decoded.Unknown.Count == 2, $"unknown retained: {decoded.Unknown.Count}");
        Program.Check(Dynamic.EncodeGeneric(requestType, decoded, model).SequenceEqual(payload),
            "unknown round trip");

        // Loopback: dynamic client against dynamic server.
        (ITransport a, ITransport b) = MemoryTransport.Pair();
        var loopbackServer = new Server();
        Dynamic.RegisterDynamicService(loopbackServer, model, Service, new DynamicEchoService());
        loopbackServer.ServeTransport(b);
        RunScenarios(new Dynamic.DynamicClient(new Channel(a), model), model);

        string cp = JavaClasspath();
        if (cp == null)
        {
            Console.WriteLine("TestDynamic partial SKIP (java oracle not built)");
            Console.WriteLine("TestDynamic OK (loopback)");
            return;
        }
        string javaBin = "java";

        // Direction A: dynamic client -> bridge -> official server.
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
                Console.WriteLine("TestDynamic SKIP (oracle server did not start)");
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
                RunScenarios(new Dynamic.DynamicClient(new Channel(transport), model), model);
            }
            finally
            {
                bridge.Kill();
            }
            server.Kill();
        }

        // Direction B: official client -> bridge -> dynamic server.
        int portB = FreePort();
        string serverDllPath = Path.GetFullPath(Path.Combine(Root, "csharp",
            "examples", "DynamicEchoServerStdio", "bin", "Debug", "net8.0", "DynamicEchoServerStdio.dll"));
        if (!File.Exists(serverDllPath))
        {
            Console.WriteLine("TestDynamic SKIP (csharp dynamic server not built)");
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
                Console.WriteLine($"TestDynamic SKIP (bridge did not start): {firstLine}");
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

        Console.WriteLine("TestDynamic OK");
    }
}
