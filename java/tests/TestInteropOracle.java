package tests;

import grpc.testing.Empty;
import grpc.testing.Payload;
import grpc.testing.ResponseParameters;
import grpc.testing.SimpleRequest;
import grpc.testing.SimpleResponse;
import grpc.testing.StreamingInputCallRequest;
import grpc.testing.StreamingInputCallResponse;
import grpc.testing.StreamingOutputCallRequest;
import grpc.testing.StreamingOutputCallResponse;
import grpc.testing.TestGrpcDc;
import grpc.testing.TestOrcaReport;
import grpcdc.Channel;
import grpcdc.StatusException;
import java.io.BufferedReader;
import java.io.EOFException;
import java.io.InputStreamReader;
import java.net.ServerSocket;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;

/**
 * Interop client grading: the generated Java TestService client
 * runs the canonical grpc interop cases (generated table:
 * InteropCases) against the official grpc-go TestServiceServer,
 * through the bridge (dc-to-http2, stdio = DataChannel). Mirrors
 * the JS/Python/Go/Rust interop oracle suites. Skips when the
 * oracle server binary is not built (Dockerfile.ci builds it).
 */
public final class TestInteropOracle {
    private TestInteropOracle() {}

    private static final Path ROOT = Path.of("..").toAbsolutePath().normalize();

    static void check(boolean condition, String what) {
        if (!condition) {
            throw new AssertionError(what);
        }
    }

    private static int freePort() throws Exception {
        try (ServerSocket socket = new ServerSocket(0)) {
            return socket.getLocalPort();
        }
    }

    private static Payload payload(int size) {
        return new Payload(null, new byte[size]);
    }

    private static StreamingOutputCallRequest streamRequest(int[] respSizes, int payloadSize) {
        StreamingOutputCallRequest req = new StreamingOutputCallRequest();
        for (int size : respSizes) {
            ResponseParameters p = new ResponseParameters();
            p.size = size;
            req.responseParameters.add(p);
        }
        req.payload = payload(payloadSize);
        return req;
    }

    private static void expectStatus(int code, String message, String what, ThrowingCall call) throws Exception {
        try {
            call.run();
        } catch (StatusException e) {
            check(e.code == code, what + ": code " + e.code + " != " + code);
            if (!message.isEmpty()) {
                check(message.equals(e.getMessage()),
                        what + ": message '" + e.getMessage() + "' != '" + message + "'");
            }
            return;
        }
        throw new AssertionError(what + ": expected status " + code + ", call succeeded");
    }

    private interface ThrowingCall {
        void run() throws Exception;
    }

    private static void runCases(TestGrpcDc.TestServiceClient client,
                                 TestGrpcDc.UnimplementedServiceClient unimpl) throws Exception {
        for (Object[] row : InteropCases.CASES) {
            String name = (String) row[0];
            String kind = (String) row[1];
            int[] reqSizes = (int[]) row[2];
            int[] respSizes = (int[]) row[3];
            int statusCode = (Integer) row[4];
            String statusMessage = (String) row[5];
            switch (kind) {
                case "EMPTY" -> client.EmptyCall(new Empty());
                case "LARGE_UNARY" -> {
                    SimpleRequest req = new SimpleRequest();
                    req.responseSize = respSizes[0];
                    req.payload = payload(reqSizes[0]);
                    SimpleResponse resp = client.UnaryCall(req);
                    check(resp.payload.body.length == respSizes[0],
                            name + ": body " + resp.payload.body.length);
                }
                case "CLIENT_STREAMING" -> {
                    List<StreamingInputCallRequest> reqs = new ArrayList<>();
                    int total = 0;
                    for (int size : reqSizes) {
                        StreamingInputCallRequest r = new StreamingInputCallRequest();
                        r.payload = payload(size);
                        reqs.add(r);
                        total += size;
                    }
                    StreamingInputCallResponse resp = client.StreamingInputCall(reqs);
                    check(resp.aggregatedPayloadSize == total,
                            name + ": aggregated " + resp.aggregatedPayloadSize + " != " + total);
                }
                case "SERVER_STREAMING" -> {
                    try (var stream = client.StreamingOutputCall(streamRequest(respSizes, 0))) {
                        for (int size : respSizes) {
                            StreamingOutputCallResponse resp = stream.recv();
                            check(resp.payload.body.length == size,
                                    name + ": body " + resp.payload.body.length + " != " + size);
                        }
                        try {
                            stream.recv();
                            throw new AssertionError(name + ": expected EOF");
                        } catch (EOFException expected) {
                            // end of stream
                        }
                    }
                }
                case "PING_PONG" -> {
                    List<StreamingOutputCallRequest> reqs = new ArrayList<>();
                    for (int i = 0; i < respSizes.length; i++) {
                        reqs.add(streamRequest(new int[]{respSizes[i]}, reqSizes[i]));
                    }
                    try (var stream = client.FullDuplexCall(reqs)) {
                        for (int size : respSizes) {
                            StreamingOutputCallResponse resp = stream.recv();
                            check(resp.payload.body.length == size,
                                    name + ": body " + resp.payload.body.length + " != " + size);
                        }
                    }
                }
                case "EMPTY_STREAM" -> {
                    try (var stream = client.FullDuplexCall(List.of())) {
                        try {
                            stream.recv();
                            throw new AssertionError(name + ": expected EOF");
                        } catch (EOFException expected) {
                            // end of stream
                        }
                    }
                }
                case "CUSTOM_METADATA" -> {
                    // Upstream custom_metadata, duplex leg (the
                    // generated unary path does not surface
                    // trailers): echo-initial must return as
                    // initial metadata, echo-trailing-bin (base64
                    // on our wire) as trailers.
                    String trailingBin = java.util.Base64.getEncoder().encodeToString(
                            new byte[]{0x0a, 0x0b, 0x0a, 0x0b, 0x0a, 0x0b});
                    java.util.Map<String, String> md = java.util.Map.of(
                            "x-grpc-test-echo-initial", "test_initial_metadata_value",
                            "x-grpc-test-echo-trailing-bin", trailingBin);
                    try (var stream = client.FullDuplexCall(
                            List.of(streamRequest(new int[]{1}, 1)), md)) {
                        StreamingOutputCallResponse resp = stream.recv();
                        check(resp.payload.body.length == 1, name + ": body");
                        try {
                            stream.recv();
                            throw new AssertionError(name + ": expected EOF");
                        } catch (EOFException expected) {
                            // end of stream: trailers now readable
                        }
                        check("test_initial_metadata_value".equals(
                                stream.headers().get("x-grpc-test-echo-initial")),
                                name + ": initial " + stream.headers());
                        check(trailingBin.equals(
                                stream.trailers().get("x-grpc-test-echo-trailing-bin")),
                                name + ": trailing " + stream.trailers());
                    }
                }
                case "STATUS_UNARY" -> {
                    SimpleRequest req = new SimpleRequest();
                    req.responseStatus = new grpc.testing.EchoStatus();
                    req.responseStatus.code = statusCode;
                    req.responseStatus.message = statusMessage;
                    expectStatus(statusCode, statusMessage, name, () -> client.UnaryCall(req));
                }
                case "STATUS_DUPLEX" -> {
                    StreamingOutputCallRequest req = streamRequest(new int[]{0}, 0);
                    req.responseStatus = new grpc.testing.EchoStatus();
                    req.responseStatus.code = statusCode;
                    req.responseStatus.message = statusMessage;
                    expectStatus(statusCode, statusMessage, name, () -> {
                        try (var stream = client.FullDuplexCall(List.of(req))) {
                            stream.recv();
                        }
                    });
                }
                case "UNIMPLEMENTED_METHOD" -> expectStatus(statusCode, "", name,
                        () -> client.UnimplementedCall(new Empty()));
                case "UNIMPLEMENTED_SERVICE" -> expectStatus(statusCode, "", name,
                        () -> unimpl.UnimplementedCall(new Empty()));
                default -> throw new AssertionError("unknown interop kind " + kind);
            }
            System.out.println("interop case ok: " + name);
        }
    }

    // ORCA rows (upstream orca_per_rpc / orca_oob): per-RPC the
    // report returns as the serialized OrcaLoadReport in the
    // endpoint-load-metrics-bin trailer (base64 -bin value); OOB
    // the value fed through FullDuplexCall comes back on the
    // OpenRcaService StreamCoreMetrics stream.
    private static void runOrcaCases(Channel channel,
                                     TestGrpcDc.TestServiceClient client) throws Exception {
        SimpleRequest req = new SimpleRequest();
        TestOrcaReport report = new TestOrcaReport();
        report.cpuUtilization = 0.8210;
        report.memoryUtilization = 0.5847;
        report.requestCost.put("cost", 3456.32);
        report.utilization.put("util", 0.30499);
        req.orcaPerQueryReport = report;
        try (Channel.ClientStream stream = channel.serverStream(
                "/grpc.testing.TestService/UnaryCall", req, null)) {
            SimpleResponse resp = new SimpleResponse();
            stream.recv(resp);
            try {
                stream.recv(new SimpleResponse());
                throw new AssertionError("orca_per_rpc: expected EOF");
            } catch (EOFException expected) {
                // end of stream: trailers now readable
            }
            String encoded = stream.trailers().get("endpoint-load-metrics-bin");
            check(encoded != null, "orca_per_rpc: no endpoint-load-metrics-bin trailer");
            byte[] raw;
            try {
                raw = java.util.Base64.getDecoder().decode(encoded);
            } catch (IllegalArgumentException e) {
                raw = java.util.Base64.getDecoder().decode(encoded + "=".repeat(
                        (4 - encoded.length() % 4) % 4));
            }
            xds.data.orca.v3.OrcaLoadReport loadReport = new xds.data.orca.v3.OrcaLoadReport();
            loadReport.unmarshalDc(raw);
            check(loadReport.cpuUtilization == 0.8210
                    && loadReport.memUtilization == 0.5847
                    && loadReport.requestCost.getOrDefault("cost", 0.0) == 3456.32
                    && loadReport.utilization.getOrDefault("util", 0.0) == 0.30499,
                    "orca_per_rpc: report " + loadReport.cpuUtilization + "/"
                            + loadReport.memUtilization);
        }
        System.out.println("interop case ok: orca_per_rpc");

        StreamingOutputCallRequest feed = new StreamingOutputCallRequest();
        TestOrcaReport oob = new TestOrcaReport();
        oob.cpuUtilization = 0.9;
        oob.memoryUtilization = 0.85;
        oob.utilization.put("util", 0.5);
        feed.orcaOobReport = oob;
        try (var duplex = client.FullDuplexCall(List.of(feed))) {
            try {
                while (true) {
                    duplex.recv();
                }
            } catch (EOFException expected) {
                // feed call completed
            }
        }
        xds.service.orca.v3.OrcaGrpcDc.OpenRcaServiceClient orca =
                new xds.service.orca.v3.OrcaGrpcDc.OpenRcaServiceClient(channel);
        long deadline = System.currentTimeMillis() + 30000;
        boolean matched = false;
        try (var stream = orca.StreamCoreMetrics(new xds.service.orca.v3.OrcaLoadReportRequest())) {
            while (!matched && System.currentTimeMillis() < deadline) {
                xds.data.orca.v3.OrcaLoadReport got = stream.recv();
                matched = got.cpuUtilization == 0.9 && got.memUtilization == 0.85
                        && got.utilization.getOrDefault("util", 0.0) == 0.5;
            }
        }
        check(matched, "orca_oob: no matching OOB report within 30s");
        System.out.println("interop case ok: orca_oob");
    }

    public static void main(String[] args) throws Exception {
        Path serverBin = ROOT.resolve("oracle/go-interop/interop-server");
        if (!Files.isExecutable(serverBin)) {
            System.out.println("TestInteropOracle SKIP (go interop server not built)");
            return;
        }
        int port = freePort();
        Process server = new ProcessBuilder(serverBin.toString(), "-port", String.valueOf(port))
                .redirectErrorStream(true).start();
        try {
            // The Go server prints no readiness line; poll the port.
            long deadline = System.currentTimeMillis() + 30000;
            boolean ready = false;
            while (System.currentTimeMillis() < deadline) {
                try (java.net.Socket s = new java.net.Socket("127.0.0.1", port)) {
                    ready = true;
                    break;
                } catch (Exception e) {
                    Thread.sleep(100);
                }
            }
            check(ready, "go interop server did not start");

            Process bridge = new ProcessBuilder("node",
                    ROOT.resolve("oracle/bridge.mjs").toString(),
                    "dc-to-http2", "--grpc", "127.0.0.1:" + port)
                    .redirectErrorStream(false).start();
            try {
                // Drain bridge stderr so its pipe never blocks.
                Thread drain = new Thread(() -> {
                    try (BufferedReader r = new BufferedReader(new InputStreamReader(bridge.getErrorStream()))) {
                        while (r.readLine() != null) {
                            // discard
                        }
                    } catch (Exception ignored) {
                        // bridge gone
                    }
                });
                drain.setDaemon(true);
                drain.start();
                echo.StdioTransport transport =
                        new echo.StdioTransport(bridge.getOutputStream(), bridge.getInputStream());
                Channel channel = new Channel(transport);
                TestGrpcDc.TestServiceClient client = new TestGrpcDc.TestServiceClient(channel);
                runCases(client, new TestGrpcDc.UnimplementedServiceClient(channel));
                runOrcaCases(channel, client);
            } finally {
                bridge.destroyForcibly();
            }
        } finally {
            server.destroyForcibly();
        }
        System.out.println("TestInteropOracle OK");
    }
}
