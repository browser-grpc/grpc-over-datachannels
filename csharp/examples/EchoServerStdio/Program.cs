using Echo;
using Grpcdc;

// Interop harness: the C# echo server over stdio. Other languages'
// tests spawn this and drive it with their client.
var transport = new StdioTransport(Console.OpenStandardOutput(), Console.OpenStandardInput());
// Exit when the driver closes our stdin.
transport.OnEof = () => Environment.Exit(0);
var server = new Server();
EchoGrpcDc.RegisterEchoServer(server, new EchoServiceImpl());
server.ServeTransport(transport);
Thread.Sleep(Timeout.Infinite);
