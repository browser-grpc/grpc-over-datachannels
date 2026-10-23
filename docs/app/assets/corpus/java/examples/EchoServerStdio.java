package echo;

import grpcdc.Server;

/**
 * Interop harness: the Java echo server over stdio. Other languages'
 * tests spawn this and drive it with their client.
 */
public final class EchoServerStdio {
    private EchoServerStdio() {}

    public static void main(String[] args) throws Exception {
        StdioTransport transport = new StdioTransport(System.out, System.in);
        // Exit when the driver closes our stdin.
        transport.onEof = () -> System.exit(0);
        Server server = new Server();
        EchoGrpcDc.registerEchoServer(server, new EchoServiceImpl());
        server.serveTransport(transport);
        Object lock = new Object();
        synchronized (lock) {
            lock.wait();
        }
    }
}
