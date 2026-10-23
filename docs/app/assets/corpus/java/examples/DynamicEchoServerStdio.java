package echo;

import grpcdc.Dynamic;
import grpcdc.Server;
import java.nio.file.Files;
import java.nio.file.Path;

/**
 * Interop harness: the dynamic (descriptor-driven) Java echo server
 * over stdio. Loads fixtures/echo_descriptor_set.bin at runtime —
 * no generated stubs involved. Used by the oracle tests.
 */
public final class DynamicEchoServerStdio {
    private DynamicEchoServerStdio() {}

    public static void main(String[] args) throws Exception {
        Path fixtures = locateFixtures();
        Dynamic.FileModel model = Dynamic.parseDescriptorSet(Files.readAllBytes(fixtures));
        StdioTransport transport = new StdioTransport(System.out, System.in);
        transport.onEof = () -> System.exit(0);
        Server server = new Server();
        Dynamic.registerDynamicService(server, model, "echo.Echo", new DynamicEchoService());
        server.serveTransport(transport);
        Object lock = new Object();
        synchronized (lock) {
            lock.wait();
        }
    }

    private static Path locateFixtures() {
        Path dir = Path.of("").toAbsolutePath();
        for (int i = 0; i < 8 && dir != null; i++) {
            Path candidate = dir.resolve("fixtures/echo_descriptor_set.bin");
            if (Files.exists(candidate)) {
                return candidate;
            }
            candidate = dir.resolve("grpc-over-datachannels/fixtures/echo_descriptor_set.bin");
            if (Files.exists(candidate)) {
                return candidate;
            }
            dir = dir.getParent();
        }
        throw new IllegalStateException("fixtures/echo_descriptor_set.bin not found");
    }
}
