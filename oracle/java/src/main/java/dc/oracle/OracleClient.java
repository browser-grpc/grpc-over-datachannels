package dc.oracle;

import echo.EchoGrpc;
import echo.EchoOuterClass.EchoRequest;
import echo.EchoOuterClass.EchoResponse;
import io.grpc.ManagedChannel;
import io.grpc.ManagedChannelBuilder;
import io.grpc.Metadata;
import io.grpc.Status;
import io.grpc.StatusRuntimeException;
import io.grpc.stub.MetadataUtils;
import io.grpc.stub.StreamObserver;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.Iterator;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/**
 * Official grpc-java client as test oracle: executes the generated
 * scenario file (fixtures/oracle_scenarios.txt) against whatever server
 * is on the other end — directly, or through oracle/bridge.mjs into a
 * grpc-dc server. Prints OK/FAIL per case; exits non-zero on any FAIL.
 * Usage: OracleClient <port> <scenarios-file>
 */
public final class OracleClient {
  private final EchoGrpc.EchoBlockingStub blocking;
  private final EchoGrpc.EchoStub async;
  private int failures = 0;

  private OracleClient(ManagedChannel channel) {
    EchoGrpc.EchoBlockingStub blockingStub = EchoGrpc.newBlockingStub(channel);
    EchoGrpc.EchoStub asyncStub = EchoGrpc.newStub(channel);
    // -Doracle.compress=gzip: compress every request message. The
    // grpc-dc wire has no compression; the proxy must decompress.
    if ("gzip".equals(System.getProperty("oracle.compress"))) {
      blockingStub = blockingStub.withCompression("gzip");
      asyncStub = asyncStub.withCompression("gzip");
    }
    // -Doracle.metadata=<v>: attach x-echo metadata to every
    // call; canonical servers reflect it in the unary reply.
    String meta = System.getProperty("oracle.metadata");
    if (meta != null) {
      Metadata md = new Metadata();
      md.put(Metadata.Key.of("x-echo", Metadata.ASCII_STRING_MARSHALLER), meta);
      blockingStub = blockingStub.withInterceptors(MetadataUtils.newAttachHeadersInterceptor(md));
      asyncStub = asyncStub.withInterceptors(MetadataUtils.newAttachHeadersInterceptor(md));
    }
    this.blocking = blockingStub;
    this.async = asyncStub;
  }

  private static EchoRequest req(String message, int count) {
    return EchoRequest.newBuilder().setMessage(message).setCount(count).build();
  }

  private static String unmsg(String token) {
    return "-".equals(token) ? "" : token;
  }

  private void check(String line, boolean ok, String detail) {
    if (ok) {
      System.out.println("OK " + line);
    } else {
      failures++;
      System.out.println("FAIL " + line + " :: " + detail);
    }
  }

  private void runCase(String line) throws Exception {
    String[] tok = line.split(" ");
    switch (tok[0]) {
      case "UNARY": {
        String message = unmsg(tok[1]);
        Integer expectStatus = null;
        for (int i = 2; i + 1 < tok.length; i++) {
          if ("EXPECT_STATUS".equals(tok[i])) expectStatus = Integer.valueOf(tok[i + 1]);
        }
        try {
          EchoResponse resp = blocking.unary(req(message, 0));
          String meta = System.getProperty("oracle.metadata");
          String expected = "echo: " + message + (meta == null ? "" : " [" + meta + "]");
          check(line, expectStatus == null && resp.getMessage().equals(expected)
              && resp.getIndex() == 0, "resp=" + resp);
        } catch (StatusRuntimeException e) {
          check(line, expectStatus != null && e.getStatus().getCode().value() == expectStatus,
              "status=" + e.getStatus());
        }
        break;
      }
      case "DEADLINE": {
        // DEADLINE <delayMs> <timeoutMs>: unary with a delayed
        // server must surface DEADLINE_EXCEEDED (code 4).
        int delayMs = Integer.parseInt(tok[1]);
        int timeoutMs = Integer.parseInt(tok[2]);
        EchoRequest slow = EchoRequest.newBuilder()
            .setMessage("").setCount(0).setDelayMs(delayMs).build();
        try {
          blocking.withDeadlineAfter(timeoutMs, TimeUnit.MILLISECONDS).unary(slow);
          check(line, false, "call completed, expected DEADLINE_EXCEEDED");
        } catch (StatusRuntimeException e) {
          check(line, e.getStatus().getCode() == Status.Code.DEADLINE_EXCEEDED,
              "status=" + e.getStatus());
        }
        break;
      }
      case "SERVER_STREAM": {
        String message = unmsg(tok[1]);
        int count = Integer.parseInt(tok[2]);
        Iterator<EchoResponse> it = blocking.serverStream(req(message, count));
        List<EchoResponse> got = new ArrayList<>();
        it.forEachRemaining(got::add);
        boolean ok = got.size() == count;
        for (int i = 0; ok && i < count; i++) {
          ok = got.get(i).getMessage().equals(message) && got.get(i).getIndex() == i;
        }
        check(line, ok, "got=" + got);
        break;
      }
      case "CLIENT_STREAM": {
        List<String> messages = new ArrayList<>();
        for (int i = 1; i < tok.length; i++) messages.add(unmsg(tok[i]));
        Collect<EchoResponse> collect = new Collect<>();
        StreamObserver<EchoRequest> out = async.clientStream(collect);
        for (String m : messages) out.onNext(req(m, 0));
        out.onCompleted();
        EchoResponse resp = collect.await();
        check(line, collect.error == null && resp != null
            && resp.getMessage().equals(String.join("+", messages))
            && resp.getIndex() == messages.size(),
            "resp=" + resp + " err=" + collect.error);
        break;
      }
      case "BIDI": {
        List<String> messages = new ArrayList<>();
        for (int i = 1; i < tok.length; i++) messages.add(unmsg(tok[i]));
        Collect<EchoResponse> collect = new Collect<>();
        StreamObserver<EchoRequest> out = async.bidi(collect);
        for (String m : messages) out.onNext(req(m, 0));
        out.onCompleted();
        collect.awaitDone();
        boolean ok = collect.error == null && collect.values.size() == messages.size();
        for (int i = 0; ok && i < messages.size(); i++) {
          EchoResponse r = collect.values.get(i);
          ok = r.getMessage().equals(messages.get(i)) && r.getIndex() == i;
        }
        check(line, ok, "got=" + collect.values + " err=" + collect.error);
        break;
      }
      default:
        check(line, false, "unknown case kind " + tok[0]);
    }
  }

  private static final class Collect<T> implements StreamObserver<T> {
    final List<T> values = new ArrayList<>();
    final CountDownLatch done = new CountDownLatch(1);
    Throwable error;

    @Override public void onNext(T value) { values.add(value); }
    @Override public void onError(Throwable t) { error = t; done.countDown(); }
    @Override public void onCompleted() { done.countDown(); }

    T await() throws InterruptedException {
      awaitDone();
      return values.isEmpty() ? null : values.get(0);
    }

    void awaitDone() throws InterruptedException {
      if (!done.await(30, TimeUnit.SECONDS)) throw new IllegalStateException("timeout");
    }
  }

  public static void main(String[] args) throws Exception {
    int port = Integer.parseInt(args[0]);
    List<String> lines = Files.readAllLines(Paths.get(args[1]), StandardCharsets.UTF_8);
    ManagedChannel channel;
    String tlsCert = System.getProperty("oracle.tlsCert");
    if (tlsCert != null) {
      // -Doracle.tlsCert=<pem>: TLS (ALPN h2) trusting that cert.
      io.grpc.netty.shaded.io.grpc.netty.NettyChannelBuilder tlsBuilder =
          io.grpc.netty.shaded.io.grpc.netty.NettyChannelBuilder.forAddress("127.0.0.1", port);
      tlsBuilder.sslContext(io.grpc.netty.shaded.io.grpc.netty.GrpcSslContexts.forClient()
          .trustManager(new java.io.File(tlsCert)).build());
      channel = tlsBuilder.build();
    } else {
      channel = ManagedChannelBuilder.forAddress("127.0.0.1", port)
          .usePlaintext().build();
    }
    OracleClient client = new OracleClient(channel);
    for (String line : lines) {
      line = line.trim();
      if (line.isEmpty() || line.startsWith("#")) continue;
      client.runCase(line);
    }
    channel.shutdownNow();
    if (client.failures > 0) {
      System.out.println("ORACLE CLIENT: " + client.failures + " FAILURES");
      System.exit(1);
    }
    System.out.println("ORACLE CLIENT: ALL OK");
  }
}
