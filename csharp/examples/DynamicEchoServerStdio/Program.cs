using Echo;
using Grpcdc;

// Interop harness: the dynamic (descriptor-driven) C# echo server
// over stdio. Loads fixtures/echo_descriptor_set.bin at runtime —
// no generated stubs involved. Used by the oracle tests.
static string LocateFixtures()
{
    var dir = new DirectoryInfo(Directory.GetCurrentDirectory());
    for (int i = 0; i < 8 && dir != null; i++)
    {
        string candidate = Path.Combine(dir.FullName, "fixtures", "echo_descriptor_set.bin");
        if (File.Exists(candidate))
        {
            return candidate;
        }
        candidate = Path.Combine(dir.FullName, "grpc-over-datachannels", "fixtures", "echo_descriptor_set.bin");
        if (File.Exists(candidate))
        {
            return candidate;
        }
        dir = dir.Parent;
    }
    throw new InvalidOperationException("fixtures/echo_descriptor_set.bin not found");
}

Dynamic.FileModel model = Dynamic.ParseDescriptorSet(File.ReadAllBytes(LocateFixtures()));
var transport = new StdioTransport(Console.OpenStandardOutput(), Console.OpenStandardInput());
transport.OnEof = () => Environment.Exit(0);
var server = new Server();
Dynamic.RegisterDynamicService(server, model, "echo.Echo", new DynamicEchoService());
server.ServeTransport(transport);
Thread.Sleep(Timeout.Infinite);
