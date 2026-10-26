package tests;

import java.io.BufferedReader;
import java.io.File;
import java.io.InputStreamReader;
import java.net.ServerSocket;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.TimeUnit;

/**
 * Interop oracle, Direction B: the OFFICIAL interop clients
 * (grpc-java TestServiceClient, grpc-go interop-client) run the
 * canonical cases against the generated Java TestService server
 * (examples/InteropServerStdio.java +
 * examples/interop/InteropServiceImpl.java), reached over
 * HTTP/2 through oracle/bridge.mjs http2-to-dc. Skips when an
 * oracle binary or Node is unavailable (Dockerfile.ci builds
 * them). Mirrors js/test/interop_server_oracle.test.js.
 *
 * Excluded (oracle/interop/README.md): auth, soak.
 * cacheable_unary and the compression cases run only under the
 * Java client; ORCA cases only under the Go client.
 */
public final class TestInteropServerOracle {
    private TestInteropServerOracle() {}

    private static final Path ROOT = Path.of("..").toAbsolutePath().normalize();

    private static final List<String> CASES = List.of(
            "empty_unary",
            "large_unary",
            "client_streaming",
            "server_streaming",
            "ping_pong",
            "empty_stream",
            "custom_metadata",
            "status_code_and_message",
            "special_status_message",
            "unimplemented_method",
            "unimplemented_service",
            "cancel_after_begin",
            "cancel_after_first_response",
            "timeout_on_sleeping_server");

    private static final List<String> JAVA_ONLY_CASES = List.of(
            "cacheable_unary",
            "client_compressed_unary",
            "client_compressed_streaming",
            "server_compressed_unary",
            "server_compressed_streaming");

    private static final List<String> GO_ONLY_CASES = List.of(
            "orca_per_rpc",
            "orca_oob");

    private static void check(boolean condition, String what) {
        if (!condition) {
            throw new AssertionError(what);
        }
    }

    private static String javaClasspath() throws Exception {
        Path target = ROOT.resolve("oracle/java/target");
        Path cpFile = target.resolve("cp.txt");
        if (!Files.exists(cpFile) || !Files.isDirectory(target.resolve("classes"))) {
            return null;
        }
        return target.resolve("classes") + File.pathSeparator + Files.readString(cpFile).strip();
    }

    private static int freePort() throws Exception {
        try (ServerSocket socket = new ServerSocket(0)) {
            return socket.getLocalPort();
        }
    }

    private static boolean waitReady(Process proc, String needle) throws Exception {
        try (BufferedReader reader = new BufferedReader(
                new InputStreamReader(proc.getErrorStream(), StandardCharsets.UTF_8))) {
            String line;
            while ((line = reader.readLine()) != null) {
                if (line.contains(needle)) {
                    return true;
                }
            }
        }
        return false;
    }

    private static String runClient(List<String> argv, long timeoutSeconds) throws Exception {
        Process proc = new ProcessBuilder(argv).redirectErrorStream(true).start();
        StringBuilder out = new StringBuilder();
        Thread drain = new Thread(() -> {
            try (BufferedReader reader = new BufferedReader(
                    new InputStreamReader(proc.getInputStream(), StandardCharsets.UTF_8))) {
                String line;
                while ((line = reader.readLine()) != null) {
                    out.append(line).append('\n');
                }
            } catch (Exception ignored) {
                // process gone
            }
        });
        drain.setDaemon(true);
        drain.start();
        if (!proc.waitFor(timeoutSeconds, TimeUnit.SECONDS)) {
            proc.destroyForcibly();
            throw new AssertionError("client timed out: " + argv);
        }
        drain.join(5000);
        check(proc.exitValue() == 0,
                "client exit " + proc.exitValue() + ": " + argv + "\n" + out);
        return out.toString();
    }

    public static void main(String[] args) throws Exception {
        String cp = javaClasspath();
        if (cp == null) {
            System.out.println("TestInteropServerOracle SKIP (oracle not built)");
            return;
        }
        Path serverMain = ROOT.resolve("java/build/grpc/testing/InteropServerStdio.class");
        if (!Files.exists(serverMain)) {
            System.out.println("TestInteropServerOracle SKIP (java server not built)");
            return;
        }
        int port = freePort();
        String serverCmd = "java -cp " + ROOT.resolve("java/build")
                + " grpc.testing.InteropServerStdio";
        Process bridge = new ProcessBuilder("node",
                ROOT.resolve("oracle/bridge.mjs").toString(), "http2-to-dc",
                "--port", Integer.toString(port),
                "--target-cmd", serverCmd)
                .redirectErrorStream(false)
                .start();
        try {
            if (!waitReady(bridge, "listening")) {
                System.out.println("TestInteropServerOracle SKIP (bridge did not start)");
                return;
            }
            List<String> javaCases = new ArrayList<>(CASES);
            javaCases.addAll(JAVA_ONLY_CASES);
            for (String testCase : javaCases) {
                String out = runClient(List.of(
                        "java", "-cp", cp, "io.grpc.testing.integration.TestServiceClient",
                        "--server_host=127.0.0.1", "--server_port=" + port,
                        "--test_case=" + testCase, "--use_tls=false"), 120);
                check(out.contains("Test completed."),
                        "java case " + testCase + ": unexpected output: " + out);
                System.out.println("interop B case ok: " + testCase + " (java client)");
            }
            Path goClient = ROOT.resolve("oracle/go-interop/interop-client");
            if (!Files.exists(goClient)) {
                System.out.println("TestInteropServerOracle GO SKIP (go client not built)");
            } else {
                List<String> goCases = new ArrayList<>(CASES);
                goCases.addAll(GO_ONLY_CASES);
                for (String testCase : goCases) {
                    List<String> argv = new ArrayList<>(List.of(
                            goClient.toString(),
                            "-server_host", "127.0.0.1",
                            "-server_port", Integer.toString(port),
                            "-test_case", testCase));
                    if (testCase.startsWith("orca")) {
                        argv.add("-service_config_json");
                        argv.add("{ \"loadBalancingConfig\": [{ \"test_backend_metrics_load_balancer\": {} }]}");
                    }
                    runClient(argv, 120);
                    System.out.println("interop B case ok: " + testCase + " (go client)");
                }
            }
        } finally {
            bridge.destroyForcibly();
            bridge.waitFor(5, TimeUnit.SECONDS);
        }
        System.out.println("TestInteropServerOracle OK");
    }
}
