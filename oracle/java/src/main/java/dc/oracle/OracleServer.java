package dc.oracle;

import echo.EchoGrpc;
import echo.EchoOuterClass.EchoRequest;
import echo.EchoOuterClass.EchoResponse;
import io.grpc.Server;
import io.grpc.ServerBuilder;
import io.grpc.Status;
import io.grpc.stub.ServerCallStreamObserver;
import io.grpc.stub.StreamObserver;
import java.io.IOException;
import java.util.ArrayList;
import java.util.List;

/**
 * Reference Echo service on the official grpc-java stack. Semantics match
 * the project's Rust/JS/Go implementations so the same generated
 * scenarios (fixtures/oracle_scenarios.txt) pass against every runtime.
 */
public final class OracleServer extends EchoGrpc.EchoImplBase {

  // -Doracle.compress=gzip: compress every response message. The
  // grpc-dc wire has no compression; the proxy must decompress.
  private static void maybeCompress(StreamObserver<?> out) {
    if ("gzip".equals(System.getProperty("oracle.compress"))
        && out instanceof ServerCallStreamObserver) {
      ((ServerCallStreamObserver<?>) out).setCompression("gzip");
    }
  }

  @Override
  public void unary(EchoRequest req, StreamObserver<EchoResponse> out) {
    maybeCompress(out);
    if ("fail".equals(req.getMessage())) {
      out.onError(Status.INVALID_ARGUMENT.withDescription("asked to fail").asException());
      return;
    }
    out.onNext(EchoResponse.newBuilder().setMessage("echo: " + req.getMessage()).setIndex(0).build());
    out.onCompleted();
  }

  @Override
  public void serverStream(EchoRequest req, StreamObserver<EchoResponse> out) {
    maybeCompress(out);
    for (int i = 0; i < req.getCount(); i++) {
      out.onNext(EchoResponse.newBuilder().setMessage(req.getMessage()).setIndex(i).build());
    }
    out.onCompleted();
  }

  @Override
  public StreamObserver<EchoRequest> clientStream(StreamObserver<EchoResponse> out) {
    maybeCompress(out);
    return new StreamObserver<EchoRequest>() {
      private final List<String> parts = new ArrayList<>();

      @Override public void onNext(EchoRequest req) { parts.add(req.getMessage()); }

      @Override public void onError(Throwable t) { }

      @Override public void onCompleted() {
        out.onNext(EchoResponse.newBuilder()
            .setMessage(String.join("+", parts)).setIndex(parts.size()).build());
        out.onCompleted();
      }
    };
  }

  @Override
  public StreamObserver<EchoRequest> bidi(StreamObserver<EchoResponse> out) {
    maybeCompress(out);
    return new StreamObserver<EchoRequest>() {
      private int index = 0;

      @Override public void onNext(EchoRequest req) {
        out.onNext(EchoResponse.newBuilder().setMessage(req.getMessage()).setIndex(index++).build());
      }

      @Override public void onError(Throwable t) { }

      @Override public void onCompleted() { out.onCompleted(); }
    };
  }

  public static void main(String[] args) throws IOException, InterruptedException {
    int port = args.length > 0 ? Integer.parseInt(args[0]) : 50051;
    Server server = ServerBuilder.forPort(port).addService(new OracleServer()).build().start();
    System.err.println("READY " + port);
    server.awaitTermination();
  }
}
