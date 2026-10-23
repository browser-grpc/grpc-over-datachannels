package tests;

import echo.DynamicEchoService;
import echo.StdioTransport;
import grpcdc.Channel;
import grpcdc.Dynamic;
import grpcdc.MemoryTransport;
import grpcdc.Server;
import grpcdc.StatusException;
import grpcdc.Transport;
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
 * Dynamic (descriptor-driven) runtime: schemas consumed as data at
 * runtime, no generated stubs. Loopback plus the official grpc-java
 * oracle in both directions (the oracle is the runtime test bed).
 * Note the server under test in direction B is the NEW runtime's
 * dynamic server; oracle/java remains the official implementation.
 */
public final class TestDynamic {
    private TestDynamic() {}

    private static final Path ROOT = Path.of("..").toAbsolutePath().normalize();
    private static final String SERVICE = "echo.Echo";

    static void check(boolean condition, String what) {
        if (!condition) {
            throw new AssertionError(what);
        }
    }

    private static Dynamic.FileModel loadModel() throws IOException {
        Path path = ROOT.resolve("fixtures/echo_descriptor_set.bin");
        if (!Files.exists(path)) {
            return null;
        }
        return Dynamic.parseDescriptorSet(Files.readAllBytes(path));
    }

    private static Dynamic.GenericMessage req(Dynamic.FileModel model, String message, long count) {
        return new Dynamic.GenericMessage(model.messages.get(".echo.EchoRequest"))
                .set(1, message).set(2, count);
    }

    private static List<Dynamic.GenericMessage> reqs(Dynamic.FileModel model, List<String> messages) {
        List<Dynamic.GenericMessage> out = new ArrayList<>();
        for (String m : messages) {
            out.add(req(model, m, 0));
        }
        return out;
    }

    private static String unmsg(String token) {
        return "-".equals(token) ? "" : token;
    }

    private static void runScenarios(Dynamic.DynamicClient client, Dynamic.FileModel model) throws Exception {
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
                    try {
                        Dynamic.GenericMessage resp = client.unary(SERVICE, "Unary", req(model, messages.get(0), 0), null);
                        check(expectStatus < 0, line + ": expected failure, got " + resp);
                        check(resp.getString(1).equals("echo: " + messages.get(0)) && resp.getInt(2) == 0,
                                line + ": " + resp);
                    } catch (StatusException e) {
                        check(expectStatus >= 0 && e.code == expectStatus,
                                line + ": status " + e + ", want " + expectStatus);
                    }
                }
                case "SERVER_STREAM" -> {
                    Dynamic.DynamicClient.DynamicStream stream =
                            client.serverStream(SERVICE, "ServerStream", req(model, messages.get(0), count), null);
                    int got = 0;
                    while (true) {
                        Dynamic.GenericMessage resp;
                        try {
                            resp = stream.recv();
                        } catch (java.io.EOFException eof) {
                            break;
                        }
                        check(resp.getString(1).equals(messages.get(0)) && resp.getInt(2) == got,
                                line + ": " + resp + " at " + got);
                        got++;
                    }
                    check(got == count, line + ": got " + got + ", want " + count);
                }
                case "CLIENT_STREAM" -> {
                    Dynamic.GenericMessage resp = client.clientStream(SERVICE, "ClientStream", reqs(model, messages), null);
                    check(resp.getString(1).equals(String.join("+", messages)) && resp.getInt(2) == messages.size(),
                            line + ": " + resp);
                }
                case "BIDI" -> {
                    Dynamic.DynamicClient.DynamicStream stream =
                            client.bidi(SERVICE, "Bidi", reqs(model, messages), null);
                    int got = 0;
                    while (true) {
                        Dynamic.GenericMessage resp;
                        try {
                            resp = stream.recv();
                        } catch (java.io.EOFException eof) {
                            break;
                        }
                        check(got < messages.size() && resp.getString(1).equals(messages.get(got))
                                && resp.getInt(2) == got, line + ": " + resp + " at " + got);
                        got++;
                    }
                    check(got == messages.size(), line + ": got " + got);
                }
                default -> throw new AssertionError("unknown scenario kind: " + kind);
            }
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

    public static void main(String[] args) throws Exception {
        Dynamic.FileModel model = loadModel();
        if (model == null) {
            System.out.println("TestDynamic SKIP (descriptor fixture missing)");
            return;
        }

        // Generic codec round-trip against the golden protobuf vector.
        Dynamic.MessageModel requestType = model.messages.get(".echo.EchoRequest");
        byte[] encoded = Dynamic.encodeGeneric(requestType, req(model, "hi", 2), model);
        check(TestCodec.hex(encoded).equals("0a0268691002"), "generic encode");

        // Unknown fields (99 varint, 100 string) are retained verbatim.
        byte[] payload = new byte[] {
            0x0a, 0x02, 'h', 'i', 0x10, 0x02,
            (byte) 0x98, 0x06, 0x2a, (byte) 0xa2, 0x06, 0x01, 'x'};
        Dynamic.GenericMessage decoded = Dynamic.decodeGeneric(requestType, payload, model);
        check(decoded.unknown.size() == 2, "unknown retained: " + decoded.unknown.size());
        check(java.util.Arrays.equals(Dynamic.encodeGeneric(requestType, decoded, model), payload),
                "unknown round trip");

        // Loopback: dynamic client against dynamic server.
        Transport[] pair = MemoryTransport.pair();
        Server loopbackServer = new Server();
        Dynamic.registerDynamicService(loopbackServer, model, SERVICE, new DynamicEchoService());
        loopbackServer.serveTransport(pair[1]);
        runScenarios(new Dynamic.DynamicClient(new Channel(pair[0]), model), model);

        String cp = javaClasspath();
        if (cp == null) {
            System.out.println("TestDynamic partial SKIP (java oracle not built)");
            System.out.println("TestDynamic OK (loopback)");
            return;
        }
        String javaBin = Path.of(System.getProperty("java.home"), "bin", "java").toString();

        // Direction A: dynamic client -> bridge -> official server.
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
                System.out.println("TestDynamic SKIP (oracle server did not start)");
                return;
            }
            Process bridge = new ProcessBuilder("node",
                    ROOT.resolve("oracle/bridge.mjs").toString(),
                    "dc-to-http2", "--grpc", "127.0.0.1:" + port)
                    .redirectErrorStream(false).start();
            try {
                StdioTransport transport = new StdioTransport(bridge.getOutputStream(), bridge.getInputStream());
                runScenarios(new Dynamic.DynamicClient(new Channel(transport), model), model);
            } finally {
                bridge.destroyForcibly();
            }
        } finally {
            server.destroyForcibly();
        }

        // Direction B: official client -> bridge -> dynamic server.
        int portB = freePort();
        String buildCp = System.getProperty("java.class.path");
        String serverCmd = javaBin + " -cp " + buildCp + " echo.DynamicEchoServerStdio";
        Process bridgeB = new ProcessBuilder("node",
                ROOT.resolve("oracle/bridge.mjs").toString(),
                "http2-to-dc", "--port", String.valueOf(portB), "--target-cmd", serverCmd)
                .redirectErrorStream(false).start();
        try {
            String firstLine;
            try (BufferedReader reader = new BufferedReader(new InputStreamReader(bridgeB.getErrorStream()))) {
                firstLine = reader.readLine();
            }
            if (firstLine == null || !firstLine.contains("listening")) {
                System.out.println("TestDynamic SKIP (bridge did not start): " + firstLine);
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
            bridgeB.destroyForcibly();
        }

        System.out.println("TestDynamic OK");
    }
}
