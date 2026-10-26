package tests;

import echo.EchoGrpcDc;
import echo.EchoRequest;
import echo.EchoResponse;
import grpcdc.Channel;
import grpcdc.Http2Transport;
import java.io.BufferedReader;
import java.io.File;
import java.io.FileInputStream;
import java.io.InputStreamReader;
import java.net.ServerSocket;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.KeyStore;
import java.security.cert.CertificateFactory;
import java.security.cert.X509Certificate;
import java.util.List;
import java.util.concurrent.TimeUnit;
import javax.net.ssl.SSLContext;
import javax.net.ssl.TrustManagerFactory;

/**
 * HTTP/2 oracle: the generated grpcdc.Http2Transport dials the
 * official grpc-java OracleServer directly over TCP (no bridge) —
 * the Java end of the generated HTTP/2 client support. Plus a TLS
 * leg against the Node fixture (js/test/http2_tls_fixture.mjs,
 * ALPN h2). Skips when the oracle or fixtures are unavailable.
 * Mirrors go/http2_oracle_test.go.
 */
public final class TestHttp2Oracle {
    private TestHttp2Oracle() {}

    private static final Path ROOT = Path.of("..").toAbsolutePath().normalize();

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

    public static void main(String[] args) throws Exception {
        String cp = javaClasspath();
        if (cp == null) {
            System.out.println("TestHttp2Oracle SKIP (oracle not built)");
            return;
        }
        int port = freePort();
        Process server = new ProcessBuilder("java", "-cp", cp, "dc.oracle.OracleServer",
                Integer.toString(port))
                .redirectErrorStream(true)
                .start();
        try {
            try (BufferedReader reader = new BufferedReader(new InputStreamReader(server.getInputStream()))) {
                String line = reader.readLine();
                check(line != null && line.startsWith("READY"), "java oracle did not start: " + line);
            }
            Http2Transport transport = Http2Transport.dial("127.0.0.1:" + port);
            try {
                EchoGrpcDc.EchoClient client = new EchoGrpcDc.EchoClient(new Channel(transport));
                TestOracle.runScenarios(client);
                // Echoed initial metadata proves HEADERS metadata
                // made the round trip.
                EchoResponse md = client.Unary(new EchoRequest("hello", 0, 0),
                        java.util.Map.of("x-echo", "mval"));
                check(md.message.equals("echo: hello [mval]"), "metadata echo: " + md.message);
                // 200 responses x 1500-byte payloads: comfortably
                // past several 64KiB flow-control windows, so the
                // call only completes if stream/connection
                // WINDOW_UPDATE accounting replenishes.
                String big = "y".repeat(1500);
                var stream = client.ServerStream(new EchoRequest(big, 200, 0));
                int got = 0;
                while (true) {
                    EchoResponse resp;
                    try {
                        resp = stream.recv();
                    } catch (java.io.EOFException eof) {
                        break;
                    }
                    check(resp.message.equals(big) && resp.index == got, "flow: " + got);
                    got++;
                }
                check(got == 200, "flow: got " + got + ", want 200");
            } finally {
                transport.close();
            }
        } finally {
            server.destroyForcibly();
            server.waitFor(5, TimeUnit.SECONDS);
        }
        tlsLeg();
        System.out.println("TestHttp2Oracle OK");
    }

    private static void tlsLeg() throws Exception {
        Path fixture = ROOT.resolve("js/test/http2_tls_fixture.mjs");
        if (!Files.exists(fixture)) {
            System.out.println("TestHttp2Oracle TLS SKIP (fixture missing)");
            return;
        }
        Process proc = new ProcessBuilder("node", fixture.toString())
                .redirectErrorStream(false)
                .start();
        try {
            String line;
            try (BufferedReader reader = new BufferedReader(new InputStreamReader(proc.getInputStream()))) {
                line = reader.readLine();
            }
            if (line == null || !line.startsWith("READY")) {
                System.out.println("TestHttp2Oracle TLS SKIP (fixture did not start)");
                return;
            }
            String[] fields = line.split("\\s+");
            int port = Integer.parseInt(fields[1]);
            Path certPath = Path.of(fields[2]);
            CertificateFactory cf = CertificateFactory.getInstance("X.509");
            X509Certificate cert;
            try (FileInputStream fis = new FileInputStream(certPath.toFile())) {
                cert = (X509Certificate) cf.generateCertificate(fis);
            }
            KeyStore ks = KeyStore.getInstance(KeyStore.getDefaultType());
            ks.load(null, null);
            ks.setCertificateEntry("fixture", cert);
            TrustManagerFactory tmf = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm());
            tmf.init(ks);
            SSLContext context = SSLContext.getInstance("TLS");
            context.init(null, tmf.getTrustManagers(), null);
            Http2Transport transport = Http2Transport.dialTls("localhost:" + port, context, "localhost");
            try {
                EchoGrpcDc.EchoClient client = new EchoGrpcDc.EchoClient(new Channel(transport));
                EchoResponse resp = client.Unary(new EchoRequest("hello", 0, 0));
                check(resp.message.equals("echo: hello"), "tls unary: " + resp.message);
            } finally {
                transport.close();
            }
        } finally {
            proc.destroyForcibly();
            proc.waitFor(5, TimeUnit.SECONDS);
        }
    }
}
