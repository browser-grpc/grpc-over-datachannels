package tests;

import echo.EchoGrpcDc;
import echo.EchoRequest;
import echo.EchoResponse;
import echo.StdioTransport;
import grpcdc.Channel;
import grpcdc.StatusException;
import java.io.File;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.TimeUnit;

/**
 * Interop: the Java runtime against the Go stdio harnesses (cross-
 * language wire compatibility). Skips when Go is unavailable.
 * Mirrors python/tests/test_interop.py.
 */
public final class TestInterop {
    private TestInterop() {}

    private static final Path ROOT = Path.of("..").toAbsolutePath().normalize();

    static void check(boolean condition, String what) {
        if (!condition) {
            throw new AssertionError(what);
        }
    }

    private static boolean buildGo(Path out, String pkg) throws Exception {
        ProcessBuilder pb = new ProcessBuilder("go", "build", "-o", out.toString(), pkg);
        pb.directory(ROOT.resolve("go").toFile());
        pb.redirectErrorStream(true);
        Process proc = pb.start();
        String output = new String(proc.getInputStream().readAllBytes());
        if (!proc.waitFor(120, TimeUnit.SECONDS) || proc.exitValue() != 0) {
            System.out.println("SKIP go build " + pkg + ": " + output);
            return false;
        }
        return true;
    }

    public static void main(String[] args) throws Exception {
        Path tmp = Files.createTempDirectory("grpcdc-java-interop");
        Path serverBin = tmp.resolve("echo_server_stdio");
        if (!buildGo(serverBin, "./examples/echo_server_stdio")) {
            System.out.println("TestInterop SKIP (no go)");
            return;
        }

        Process server = new ProcessBuilder(serverBin.toString()).start();
        try {
            StdioTransport transport = new StdioTransport(server.getOutputStream(), server.getInputStream());
            EchoGrpcDc.EchoClient client = new EchoGrpcDc.EchoClient(new Channel(transport));

            EchoResponse unary = client.Unary(new EchoRequest("hello", 0, 0));
            check(unary.message.equals("echo: hello"), "unary: " + unary);

            EchoGrpcDc.EchoServerStreamStream stream = client.ServerStream(new EchoRequest("tick", 3, 0));
            List<Integer> indexes = new ArrayList<>();
            while (true) {
                EchoResponse resp;
                try {
                    resp = stream.recv();
                } catch (java.io.EOFException eof) {
                    break;
                }
                indexes.add(resp.index);
            }
            check(indexes.equals(List.of(0, 1, 2)), "server stream: " + indexes);

            EchoResponse joined = client.ClientStream(List.of(
                    new EchoRequest("a", 0, 0), new EchoRequest("b", 0, 0), new EchoRequest("c", 0, 0)));
            check(joined.message.equals("a+b+c"), "client stream: " + joined);

            EchoGrpcDc.EchoBidiStream bidi = client.Bidi(List.of(
                    new EchoRequest("x", 0, 0), new EchoRequest("y", 0, 0)));
            List<String> echoed = new ArrayList<>();
            while (true) {
                EchoResponse resp;
                try {
                    resp = bidi.recv();
                } catch (java.io.EOFException eof) {
                    break;
                }
                echoed.add(resp.message);
            }
            check(echoed.equals(List.of("x", "y")), "bidi: " + echoed);

            try {
                client.Unary(new EchoRequest("fail", 0, 0));
                check(false, "fail should throw");
            } catch (StatusException e) {
                check(e.code == 3, "fail status: " + e);
            }
        } finally {
            server.destroyForcibly();
        }

        // Reverse: Go client harness against the Java stdio server.
        Path clientBin = tmp.resolve("echo_client_stdio");
        if (!buildGo(clientBin, "./examples/echo_client_stdio")) {
            System.out.println("TestInterop partial SKIP (client build)");
            return;
        }
        String javaBin = Path.of(System.getProperty("java.home"), "bin", "java").toString();
        String classpath = System.getProperty("java.class.path");
        Process javaServer = new ProcessBuilder(javaBin, "-cp", classpath, "echo.EchoServerStdio").start();
        Process goClient = new ProcessBuilder(clientBin.toString()).redirectErrorStream(false).start();
        Thread pumpA = pump(goClient, javaServer);
        Thread pumpB = pump(javaServer, goClient);
        pumpA.start();
        pumpB.start();
        String stderr;
        try {
            if (!goClient.waitFor(60, TimeUnit.SECONDS)) {
                throw new AssertionError("go client harness timed out");
            }
            stderr = new String(goClient.getErrorStream().readAllBytes());
        } finally {
            goClient.destroyForcibly();
            javaServer.destroyForcibly();
        }
        check(stderr.contains("unary=echo: hello"), "go client unary: " + stderr);
        check(stderr.contains("server_stream=tick#0,tick#1,tick#2"), "go client stream: " + stderr);
        check(stderr.contains("client_stream=a+b+c"), "go client client-stream: " + stderr);
        check(stderr.contains("bidi=x,y"), "go client bidi: " + stderr);

        System.out.println("TestInterop OK");
    }

    private static Thread pump(Process from, Process to) {
        Thread thread = new Thread(() -> {
            try {
                byte[] buffer = new byte[65536];
                int read;
                while ((read = from.getInputStream().read(buffer)) >= 0) {
                    // Explicit flush after every chunk: Process stdin
                    // streams are buffered, and whole grpc-dc frames
                    // must not sit in the buffer.
                    to.getOutputStream().write(buffer, 0, read);
                    to.getOutputStream().flush();
                }
                to.getOutputStream().close();
            } catch (IOException ignored) {
                // peer died; teardown handles it
            }
        });
        thread.setDaemon(true);
        return thread;
    }
}
