using System.Diagnostics;
using Echo;
using Grpcdc;

namespace Tests;

/// <summary>
/// Interop: the C# runtime against the Go stdio harnesses (cross-
/// language wire compatibility). Skips when Go is unavailable.
/// Mirrors python/tests/test_interop.py.
/// </summary>
public static class TestInterop
{
    private static readonly string Root = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", ".."));

    private static bool BuildGo(string output, string pkg)
    {
        var start = new ProcessStartInfo("go", $"build -o \"{output}\" {pkg}")
        {
            WorkingDirectory = Path.Combine(Root, "go"),
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        try
        {
            using Process proc = Process.Start(start);
            string stderr = proc.StandardError.ReadToEnd();
            proc.WaitForExit(120_000);
            if (proc.ExitCode != 0)
            {
                Console.WriteLine($"SKIP go build {pkg}: {stderr}");
                return false;
            }
            return true;
        }
        catch (Exception e)
        {
            Console.WriteLine($"SKIP go build {pkg}: {e.Message}");
            return false;
        }
    }

    public static void Run()
    {
        string tmp = Path.Combine(Path.GetTempPath(), Path.GetRandomFileName());
        Directory.CreateDirectory(tmp);
        string serverBin = Path.Combine(tmp, "echo_server_stdio");
        if (!BuildGo(serverBin, "./examples/echo_server_stdio"))
        {
            Console.WriteLine("TestInterop SKIP (no go)");
            return;
        }

        using (Process server = Process.Start(new ProcessStartInfo(serverBin)
        {
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
        }))
        {
            var transport = new StdioTransport(server.StandardInput.BaseStream, server.StandardOutput.BaseStream);
            var client = new EchoGrpcDc.EchoClient(new Channel(transport));

            EchoResponse unary = client.Unary(new EchoRequest("hello", 0, 0));
            Program.Check(unary.Message == "echo: hello", $"unary: {unary}");

            var stream = client.ServerStream(new EchoRequest("tick", 3, 0));
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
                indexes.Add(resp.Index);
            }
            Program.Check(indexes.SequenceEqual(new[] { 0, 1, 2 }), $"server stream: {string.Join(",", indexes)}");

            EchoResponse joined = client.ClientStream(new[] { new EchoRequest("a", 0, 0), new EchoRequest("b", 0, 0), new EchoRequest("c", 0, 0) });
            Program.Check(joined.Message == "a+b+c", $"client stream: {joined}");

            var bidi = client.Bidi(new[] { new EchoRequest("x", 0, 0), new EchoRequest("y", 0, 0) });
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
                client.Unary(new EchoRequest("fail", 0, 0));
                Program.Check(false, "fail should throw");
            }
            catch (StatusException e)
            {
                Program.Check(e.Code == 3, $"fail status: {e}");
            }
            server.Kill();
        }

        // Reverse: Go client harness against the C# stdio server.
        string clientBin = Path.Combine(tmp, "echo_client_stdio");
        if (!BuildGo(clientBin, "./examples/echo_client_stdio"))
        {
            Console.WriteLine("TestInterop partial SKIP (client build)");
            return;
        }
        // Launch the C# server from its built dll (built by Makefile).
        string dotnet = "dotnet";
        string csharpDir = Path.Combine(Root, "csharp");
        string serverDllPath = Path.GetFullPath(Path.Combine(csharpDir,
            "examples", "EchoServerStdio", "bin", "Debug", "net8.0", "EchoServerStdio.dll"));
        if (!File.Exists(serverDllPath))
        {
            Console.WriteLine("TestInterop partial SKIP (csharp server not built)");
            return;
        }
        using Process csServer = Process.Start(new ProcessStartInfo(dotnet, $"\"{serverDllPath}\"")
        {
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
        });
        using Process goClient = Process.Start(new ProcessStartInfo(clientBin)
        {
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        });
        Thread pumpA = Pump(goClient, csServer);
        Thread pumpB = Pump(csServer, goClient);
        pumpA.Start();
        pumpB.Start();
        if (!goClient.WaitForExit(60_000))
        {
            throw new Exception("go client harness timed out");
        }
        string stderr = goClient.StandardError.ReadToEnd();
        goClient.Kill();
        csServer.Kill();
        Program.Check(stderr.Contains("unary=echo: hello"), $"go client unary: {stderr}");
        Program.Check(stderr.Contains("server_stream=tick#0,tick#1,tick#2"), $"go client stream: {stderr}");
        Program.Check(stderr.Contains("client_stream=a+b+c"), $"go client client-stream: {stderr}");
        Program.Check(stderr.Contains("bidi=x,y"), $"go client bidi: {stderr}");

        Console.WriteLine("TestInterop OK");
    }

    private static Thread Pump(Process from, Process to)
    {
        return new Thread(() =>
        {
            try
            {
                byte[] buffer = new byte[65536];
                int read;
                Stream input = from.StandardOutput.BaseStream;
                Stream output = to.StandardInput.BaseStream;
                while ((read = input.Read(buffer, 0, buffer.Length)) > 0)
                {
                    // Explicit flush after every chunk: Process stdin
                    // streams are buffered, and whole grpc-dc frames
                    // must not sit in the buffer.
                    output.Write(buffer, 0, read);
                    output.Flush();
                }
                output.Close();
            }
            catch (Exception)
            {
                // peer died; teardown handles it
            }
        })
        { IsBackground = true };
    }
}
