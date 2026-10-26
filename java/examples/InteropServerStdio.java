package grpc.testing;

import grpcdc.Server;

/**
 * Interop harness: the generated Java TestService server over
 * stdio. Direction-B oracle tests spawn this and drive it with
 * the official grpc-java / grpc-go interop clients through the
 * bridge (oracle/bridge.mjs http2-to-dc).
 */
public final class InteropServerStdio {
    private InteropServerStdio() {}

    public static void main(String[] args) throws Exception {
        echo.StdioTransport transport = new echo.StdioTransport(System.out, System.in);
        // Exit when the driver closes our stdin.
        transport.onEof = () -> System.exit(0);
        Server server = new Server();
        InteropServiceImpl impl = new InteropServiceImpl();
        TestGrpcDc.registerTestServiceServer(server, impl);
        xds.service.orca.v3.OrcaGrpcDc.registerOpenRcaServiceServer(server, impl);
        server.serveTransport(transport);
        Object lock = new Object();
        synchronized (lock) {
            lock.wait();
        }
    }
}
