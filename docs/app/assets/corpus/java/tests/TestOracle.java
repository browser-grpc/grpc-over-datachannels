package tests;

import echo.EchoGrpcDc;
import echo.EchoRequest;
import echo.EchoResponse;
import echo.StdioTransport;
import grpcdc.Channel;
import grpcdc.StatusException;
import java.io.BufferedReader;
import java.io.File;
import java.io.IOException;
import java.io.InputStreamReader;
import java.net.ServerSocket;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.TimeUnit;

/**
 * Oracle tests: the official grpc-java implementation, bridged over
 * TCP&lt;-&gt;DataChannel by ../../oracle/bridge.mjs, must agree with
 * this (generated) Java runtime on every case of the generated
 * scenario table (OracleScenarios, generated from
 * the oracle scenarios). Skips when the oracle or bridge are
 * unavailable (Dockerfile.ci provides both). Mirrors go/oracle_test.go.
 *
 * <p>Note the subject under test here is the NEW runtime in
 * java/grpcdc; the oracle in oracle/java is official grpc-java.
 */
public final class TestOracle {
    private TestOracle() {}

    private static final Path ROOT = Path.of("..").toAbsolutePath().normalize();

    static void check(boolean condition, String what) {
        if (!condition) {
            throw new AssertionError(what);
        }
    }

    private static String javaClasspath() throws IOException {
        Path target = ROOT.resolve("oracle/java/target");
        Path cpFile = target.resolve("cp.txt");
        if (!Files.exists(cpFile) || !Files.isDirectory(target.resolve("classes"))) {
            return null;
        }
        return target.resolve("classes") + File.pathSeparator + Files.readString(cpFile).strip();
    }

    private static int freePort() throws IOException {
        try (ServerSocket socket = new ServerSocket(0)) {
            return socket.getLocalPort();
        }
    }

    private static String unmsg(String token) {
        return "-".equals(token) ? "" : token;
    }

    private static void runScenarios(EchoGrpcDc.EchoClient client) throws Exception {
        for (Object[] row : OracleScenarios.CASES) {
            String kind = (String) row[0];
            String[] rawMessages = (String[]) row[1];
            int count = (Integer) row[2];
            int expectStatus = (Integer) row[3];
            List<String> messages = new ArrayList<>();
            for (String m : rawMessages) {
                messages.add(unmsg(m));
            }
            String line = kind + " " + String.join(" ", rawMessages);
            switch (kind) {
                case "UNARY" -> {
                    String message = messages.get(0);
                    try {
                        EchoResponse resp = client.Unary(new EchoRequest(message, 0, 0));
                        check(expectStatus < 0, line + ": expected failure, got " + resp);
                        check(resp.message.equals("echo: " + message) && resp.index == 0,
                                line + ": " + resp);
                    } catch (StatusException e) {
                        check(expectStatus >= 0 && e.code == expectStatus,
                                line + ": status " + e + ", want " + expectStatus);
                    }
                }
                case "SERVER_STREAM" -> {
                    String message = messages.get(0);
                    EchoGrpcDc.EchoServerStreamStream stream =
                            client.ServerStream(new EchoRequest(message, count, 0));
                    int got = 0;
                    while (true) {
                        EchoResponse resp;
                        try {
                            resp = stream.recv();
                        } catch (java.io.EOFException eof) {
                            break;
                        }
                        check(resp.message.equals(message) && resp.index == got,
                                line + ": " + resp + " at " + got);
                        got++;
                    }
                    check(got == count, line + ": got " + got + ", want " + count);
                }
                case "CLIENT_STREAM" -> {
                    List<EchoRequest> reqs = new ArrayList<>();
                    for (String m : messages) {
                        reqs.add(new EchoRequest(m, 0, 0));
                    }
                    EchoResponse resp = client.ClientStream(reqs);
                    check(resp.message.equals(String.join("+", messages)) && resp.index == messages.size(),
                            line + ": " + resp);
                }
                case "BIDI" -> {
                    List<EchoRequest> reqs = new ArrayList<>();
                    for (String m : messages) {
                        reqs.add(new EchoRequest(m, 0, 0));
                    }
                    EchoGrpcDc.EchoBidiStream stream = client.Bidi(reqs);
                    int got = 0;
                    while (true) {
                        EchoResponse resp;
                        try {
                            resp = stream.recv();
                        } catch (java.io.EOFException eof) {
                            break;
                        }
                        check(got < messages.size() && resp.message.equals(messages.get(got))
                                && resp.index == got, line + ": " + resp + " at " + got);
                        got++;
                    }
                    check(got == messages.size(), line + ": got " + got);
                }
                default -> throw new AssertionError("unknown scenario kind: " + kind);
            }
        }
    }

    public static void main(String[] args) throws Exception {
        String cp = javaClasspath();
        if (cp == null) {
            System.out.println("TestOracle SKIP (java oracle not built)");
            return;
        }
        String javaBin = Path.of(System.getProperty("java.home"), "bin", "java").toString();

        // Direction A: this runtime's client -> bridge -> official server.
        int port = freePort();
        Process server = new ProcessBuilder(javaBin, "-cp", cp, "dc.oracle.OracleServer",
                String.valueOf(port)).redirectErrorStream(false).start();
        try {
            boolean ready = false;
            try (BufferedReader reader = new BufferedReader(new InputStreamReader(server.getErrorStream()))) {
                String line;
                while ((line = reader.readLine()) != null) {
                    if (line.contains("READY")) {
                        ready = true;
                        break;
                    }
                }
            }
            if (!ready) {
                System.out.println("TestOracle SKIP (oracle server did not start)");
                return;
            }
            Process bridge = new ProcessBuilder("node",
                    ROOT.resolve("oracle/bridge.mjs").toString(),
                    "dc-to-http2", "--grpc", "127.0.0.1:" + port)
                    .redirectErrorStream(false).start();
            try {
                StdioTransport transport = new StdioTransport(bridge.getOutputStream(), bridge.getInputStream());
                EchoGrpcDc.EchoClient client = new EchoGrpcDc.EchoClient(new Channel(transport));
                runScenarios(client);
            } finally {
                bridge.destroyForcibly();
            }
        } finally {
            server.destroyForcibly();
        }

        // Direction B: official client -> bridge -> this runtime's server.
        int portB = freePort();
        String buildCp = System.getProperty("java.class.path");
        String serverCmd = javaBin + " -cp " + buildCp + " echo.EchoServerStdio";
        Process bridge = new ProcessBuilder("node",
                ROOT.resolve("oracle/bridge.mjs").toString(),
                "http2-to-dc", "--port", String.valueOf(portB), "--target-cmd", serverCmd)
                .redirectErrorStream(false).start();
        try {
            String firstLine;
            try (BufferedReader reader = new BufferedReader(new InputStreamReader(bridge.getErrorStream()))) {
                firstLine = reader.readLine();
            }
            if (firstLine == null || !firstLine.contains("listening")) {
                System.out.println("TestOracle SKIP (bridge did not start): " + firstLine);
                return;
            }
            Process client = new ProcessBuilder(javaBin, "-cp", cp, "dc.oracle.OracleClient",
                    String.valueOf(portB), ROOT.resolve("fixtures/oracle_scenarios.txt").toString())
                    .redirectErrorStream(true).start();
            String out = new String(client.getInputStream().readAllBytes());
            if (!client.waitFor(120, TimeUnit.SECONDS)) {
                throw new AssertionError("oracle client timed out");
            }
            check(client.exitValue() == 0, "oracle client failed:\n" + out);
            check(out.contains("ORACLE CLIENT: ALL OK"), "oracle client output:\n" + out);
        } finally {
            bridge.destroyForcibly();
        }

        System.out.println("TestOracle OK");
    }
}
