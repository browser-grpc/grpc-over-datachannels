using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using Echo;
using Grpcdc;

namespace Tests;

/// <summary>
/// gRPC over WebRTC-Direct via the Rust sidecar, C# to C#: two
/// direct_sidecar processes own the WebRTC stack; the C# server
/// and client only speak length-prefixed TCP to their local
/// sidecar (Grpcdc.SidecarTransport).
/// </summary>
public static class TestSidecar
{
    private static string Root()
    {
        foreach (var start in new[] { ".", ".." })
        {
            if (File.Exists(Path.Combine(start, "webrtc/rust/Cargo.toml")))
            {
                return Path.GetFullPath(start);
            }
        }
        throw new Exception("repo root not found");
    }

    private static string Sidecar()
    {
        var root = Root();
        var bin = Path.Combine(root, "webrtc/rust/target/debug/examples/direct_sidecar");
        if (!File.Exists(bin))
        {
            var build = Process.Start(new ProcessStartInfo
            {
                FileName = "cargo",
                Arguments = "build --example direct_sidecar",
                WorkingDirectory = Path.Combine(root, "webrtc/rust"),
            })!;
            build.WaitForExit();
            Program.Check(build.ExitCode == 0, "cargo build direct_sidecar");
        }
        return bin;
    }

    private static int FreePort()
    {
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        int port = ((IPEndPoint)listener.LocalEndpoint).Port;
        listener.Stop();
        return port;
    }

    private static string ReadLine(Process process, string needle)
    {
        var deadline = DateTime.UtcNow.AddSeconds(30);
        while (DateTime.UtcNow < deadline)
        {
            var line = process.StandardOutput.ReadLine();
            if (line == null)
            {
                break;
            }
            if (line.Contains(needle))
            {
                return line.Trim();
            }
        }
        throw new Exception($"sidecar did not print {needle}");
    }

    private static Process StartSidecar(string bin, params string[] args)
    {
        return Process.Start(new ProcessStartInfo
        {
            FileName = bin,
            Arguments = string.Join(" ", args),
            RedirectStandardOutput = true,
            RedirectStandardError = false,
        })!;
    }

    public static void Run()
    {
        var bin = Sidecar();
        var langPort = FreePort();
        var serverSock = new TcpListener(IPAddress.Loopback, langPort);
        serverSock.Start();
        var server = new Server();
        EchoGrpcDc.RegisterEchoServer(server, new EchoServiceImpl());
        var serverThread = new Thread(() =>
        {
            var conn = serverSock.AcceptTcpClient();
            server.ServeTransport(new SidecarTransport(conn));
        });
        serverThread.IsBackground = true;
        serverThread.Start();

        var listen = StartSidecar(bin, "listen", "--udp", "127.0.0.1:0", "--tcp", $"127.0.0.1:{langPort}");
        var multiaddr = ReadLine(listen, "MULTIADDR").Split(' ', 2)[1];
        Program.Check(multiaddr.Contains("/webrtc-direct/certhash/f"), $"multiaddr: {multiaddr}");

        var clientPort = FreePort();
        var dial = StartSidecar(bin, "dial", "--multiaddr", multiaddr, "--tcp", $"127.0.0.1:{clientPort}");
        ReadLine(dial, "TCP");

        try
        {
            var client = new EchoGrpcDc.EchoClient(new Channel(SidecarTransport.Connect("127.0.0.1", clientPort)));
            var unary = client.Unary(new EchoRequest("hello", 0, 0));
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
            Program.Check(indexes.SequenceEqual(new[] { 0, 1, 2 }), $"stream indexes: {string.Join(",", indexes)}");
            Console.WriteLine("TestSidecar OK");
        }
        finally
        {
            dial.Kill();
            listen.Kill();
            serverSock.Stop();
        }
    }
}
