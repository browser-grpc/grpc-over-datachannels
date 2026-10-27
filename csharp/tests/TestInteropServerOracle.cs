using System.Diagnostics;

namespace Tests;

/// <summary>
/// Interop oracle, Direction B: the OFFICIAL interop clients
/// (grpc-java TestServiceClient, grpc-go interop-client) run the
/// canonical cases against the generated C# TestService server
/// (examples/InteropServerStdio), reached over HTTP/2 through
/// oracle/bridge.mjs http2-to-dc. Skips when an oracle binary or
/// Node is unavailable. Mirrors
/// java/tests/TestInteropServerOracle.java.
/// </summary>
public static class TestInteropServerOracle
{
    private static readonly string[] Cases =
    {
        "empty_unary",
        "large_unary",
        "client_streaming",
        "server_streaming",
        "ping_pong",
        "empty_stream",
        "custom_metadata",
        "status_code_and_message",
        "special_status_message",
        "unimplemented_method",
        "unimplemented_service",
        "cancel_after_begin",
        "cancel_after_first_response",
        "timeout_on_sleeping_server",
    };

    private static readonly string[] JavaOnlyCases =
    {
        "cacheable_unary",
        "client_compressed_unary",
        "client_compressed_streaming",
        "server_compressed_unary",
        "server_compressed_streaming",
    };

    private static readonly string[] GoOnlyCases = { "orca_per_rpc", "orca_oob" };

    private static string RunClient(List<string> argv)
    {
        var start = new ProcessStartInfo
        {
            FileName = argv[0],
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
        };
        foreach (string arg in argv.Skip(1))
        {
            start.ArgumentList.Add(arg);
        }
        using var proc = Process.Start(start);
        var stdout = proc.StandardOutput.ReadToEndAsync();
        var stderr = proc.StandardError.ReadToEndAsync();
        if (!proc.WaitForExit(120000))
        {
            try { proc.Kill(true); } catch { /* already gone */ }
            throw new Exception($"client timed out: {string.Join(' ', argv)}");
        }
        string outText = stdout.GetAwaiter().GetResult() + stderr.GetAwaiter().GetResult();
        Program.Check(proc.ExitCode == 0, $"client exit {proc.ExitCode}: {string.Join(' ', argv)}\n{outText}");
        return outText;
    }

    public static void Run()
    {
        string root = TestOracle.Root;
        string cp = TestOracle.JavaClasspath();
        if (cp == null)
        {
            Console.WriteLine("TestInteropServerOracle SKIP (oracle not built)");
            return;
        }
        string serverBin = Path.Combine(root,
            "csharp/examples/InteropServerStdio/bin/Debug/net8.0/InteropServerStdio");
        if (!File.Exists(serverBin))
        {
            Console.WriteLine("TestInteropServerOracle SKIP (csharp server not built)");
            return;
        }
        int port = TestOracle.FreePort();
        var bridgeStart = new ProcessStartInfo
        {
            FileName = "node",
            RedirectStandardError = true,
            UseShellExecute = false,
        };
        bridgeStart.ArgumentList.Add(Path.Combine(root, "oracle/bridge.mjs"));
        bridgeStart.ArgumentList.Add("http2-to-dc");
        bridgeStart.ArgumentList.Add("--port");
        bridgeStart.ArgumentList.Add(port.ToString());
        bridgeStart.ArgumentList.Add("--target-cmd");
        bridgeStart.ArgumentList.Add(serverBin);
        using var bridge = Process.Start(bridgeStart);
        try
        {
            bool ready = false;
            var deadline = DateTime.UtcNow.AddSeconds(30);
            while (DateTime.UtcNow < deadline)
            {
                string line = bridge.StandardError.ReadLine();
                if (line == null)
                {
                    break;
                }
                if (line.Contains("listening"))
                {
                    ready = true;
                    break;
                }
            }
            if (!ready)
            {
                Console.WriteLine("TestInteropServerOracle SKIP (bridge did not start)");
                return;
            }
            // Drain remaining stderr so the pipe never blocks.
            _ = bridge.StandardError.ReadToEndAsync();
            foreach (string testCase in Cases.Concat(JavaOnlyCases))
            {
                string outText = RunClient(new List<string>
                {
                    "java", "-cp", cp, "io.grpc.testing.integration.TestServiceClient",
                    "--server_host=127.0.0.1", $"--server_port={port}",
                    $"--test_case={testCase}", "--use_tls=false",
                });
                Program.Check(outText.Contains("Test completed."),
                    $"java case {testCase}: unexpected output: {outText}");
                Console.WriteLine($"interop B case ok: {testCase} (java client)");
            }
            string goClient = Path.Combine(root, "oracle/go-interop/interop-client");
            if (!File.Exists(goClient))
            {
                Console.WriteLine("TestInteropServerOracle GO SKIP (go client not built)");
            }
            else
            {
                foreach (string testCase in Cases.Concat(GoOnlyCases))
                {
                    var argv = new List<string>
                    {
                        goClient,
                        "-server_host", "127.0.0.1",
                        "-server_port", port.ToString(),
                        "-test_case", testCase,
                    };
                    if (testCase.StartsWith("orca"))
                    {
                        argv.Add("-service_config_json");
                        argv.Add("{ \"loadBalancingConfig\": [{ \"test_backend_metrics_load_balancer\": {} }]}");
                    }
                    RunClient(argv);
                    Console.WriteLine($"interop B case ok: {testCase} (go client)");
                }
            }
        }
        finally
        {
            try { bridge.Kill(true); } catch { /* already gone */ }
        }
        Console.WriteLine("TestInteropServerOracle OK");
    }
}
