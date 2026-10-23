package tests;

import echo.EchoGrpcDc;
import echo.EchoRequest;
import echo.EchoResponse;
import echo.EchoServiceImpl;
import grpcdc.Channel;
import grpcdc.Server;
import grpcdc.SidecarTransport;
import java.io.BufferedReader;
import java.io.File;
import java.io.InputStreamReader;
import java.net.ServerSocket;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;

/**
 * gRPC over WebRTC-Direct via the Rust sidecar, Java to Java:
 * two direct_sidecar processes own the WebRTC stack; the Java
 * server and client only speak length-prefixed TCP to their
 * local sidecar (grpcdc.SidecarTransport).
 */
public final class TestSidecar {
    private TestSidecar() {}

    private static void check(boolean condition, String what) {
        if (!condition) {
            throw new AssertionError(what);
        }
    }

    private static int freePort() throws Exception {
        try (ServerSocket socket = new ServerSocket(0)) {
            return socket.getLocalPort();
        }
    }

    private static String sidecar() throws Exception {
        Path root = Path.of("..").toAbsolutePath().normalize();
        Path bin = root.resolve("webrtc/rust/target/debug/examples/direct_sidecar");
        if (!Files.isExecutable(bin)) {
            Process build = new ProcessBuilder("cargo", "build", "--example", "direct_sidecar")
                    .directory(root.resolve("webrtc/rust").toFile())
                    .inheritIO()
                    .start();
            check(build.waitFor() == 0, "cargo build direct_sidecar");
        }
        return bin.toString();
    }

    private static String readLine(Process process, String needle) throws Exception {
        BufferedReader reader =
                new BufferedReader(new InputStreamReader(process.getInputStream()));
        long deadline = System.currentTimeMillis() + 30_000;
        String line;
        while (System.currentTimeMillis() < deadline && (line = reader.readLine()) != null) {
            if (line.contains(needle)) {
                return line.trim();
            }
        }
        throw new AssertionError("sidecar did not print " + needle);
    }

    public static void main(String[] args) throws Exception {
        String bin = sidecar();

        int langPort = freePort();
        ServerSocket serverSock = new ServerSocket(langPort);
        Server server = new Server();
        EchoGrpcDc.registerEchoServer(server, new EchoServiceImpl());
        Thread serverThread = new Thread(() -> {
            try {
                server.serveTransport(new SidecarTransport(serverSock.accept()));
            } catch (Exception e) {
                throw new RuntimeException(e);
            }
        });
        serverThread.setDaemon(true);
        serverThread.start();

        Process listen = new ProcessBuilder(
                        bin, "listen", "--udp", "127.0.0.1:0", "--tcp", "127.0.0.1:" + langPort)
                .redirectErrorStream(false)
                .start();
        String multiaddr = readLine(listen, "MULTIADDR").split(" ", 2)[1];
        check(multiaddr.contains("/webrtc-direct/certhash/f"), "multiaddr: " + multiaddr);

        int clientPort = freePort();
        Process dial = new ProcessBuilder(
                        bin, "dial", "--multiaddr", multiaddr, "--tcp", "127.0.0.1:" + clientPort)
                .start();
        readLine(dial, "TCP");

        try {
            EchoGrpcDc.EchoClient client = new EchoGrpcDc.EchoClient(
                    new Channel(SidecarTransport.connect("127.0.0.1", clientPort)));
            EchoResponse unary = client.Unary(new EchoRequest("hello", 0, 0));
            check(unary.message.equals("echo: hello"), "unary: " + unary);

            EchoGrpcDc.EchoServerStreamStream stream =
                    client.ServerStream(new EchoRequest("tick", 3, 0));
            List<Integer> indexes = new ArrayList<>();
            while (true) {
                EchoResponse resp;
                try {
                    resp = stream.recv();
                } catch (java.io.EOFException e) {
                    break;
                }
                if (resp == null) {
                    break;
                }
                indexes.add(resp.index);
            }
            check(indexes.equals(List.of(0, 1, 2)), "stream indexes: " + indexes);
            System.out.println("TestSidecar OK");
        } finally {
            dial.destroy();
            listen.destroy();
            serverSock.close();
        }
        System.exit(0);
    }
}
