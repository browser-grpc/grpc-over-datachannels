using Echo;
using Grpc.testing;
using Grpcdc;

// Interop harness: the generated C# TestService server over
// stdio. Direction-B oracle tests spawn this and drive it with
// the official grpc-java / grpc-go interop clients through the
// bridge (oracle/bridge.mjs http2-to-dc).
var transport = new StdioTransport(Console.OpenStandardOutput(), Console.OpenStandardInput());
// Exit when the driver closes our stdin.
transport.OnEof = () => Environment.Exit(0);
var server = new Server();
var impl = new InteropServiceImpl();
TestGrpcDc.RegisterTestServiceServer(server, impl);
Xds.service.orca.v3.OrcaGrpcDc.RegisterOpenRcaServiceServer(server, impl);
server.ServeTransport(transport);
Thread.Sleep(Timeout.Infinite);
