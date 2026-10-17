package tests;

import echo.EchoGrpcDc;
import echo.EchoRequest;
import echo.EchoResponse;
import echo.EchoServiceImpl;
import grpcdc.Channel;
import grpcdc.Codec;
import grpcdc.Endpoint;
import grpcdc.MemoryTransport;
import grpcdc.Server;
import grpcdc.StatusException;
import grpcdc.Transport;
import grpcdc.Wire;
import java.time.Duration;
import java.util.Map;
import java.util.concurrent.atomic.AtomicReference;

/** Deadlines: grpc-timeout propagation + DEADLINE_EXCEEDED enforcement. */
public final class TestDeadline {
    private TestDeadline() {}

    static final class SlowEcho implements EchoGrpcDc.EchoServer {
        final EchoServiceImpl inner = new EchoServiceImpl();
        final AtomicReference<Endpoint.CallContext> seenCtx = new AtomicReference<>();

        @Override
        public EchoResponse Unary(Endpoint.CallContext ctx, EchoRequest req) throws Exception {
            seenCtx.set(ctx);
            Thread.sleep(400);
            return inner.Unary(ctx, req);
        }

        @Override
        public void ServerStream(EchoRequest req, EchoGrpcDc.EchoServerStreamServer stream) throws Exception {
            for (int i = 0; i < Math.max(0, req.count); i++) {
                if (i > 0) {
                    Thread.sleep(300);
                }
                stream.send(new EchoResponse(req.message, i));
            }
        }

        @Override
        public void ClientStream(EchoGrpcDc.EchoClientStreamServer stream) throws Exception {
            inner.ClientStream(stream);
        }

        @Override
        public void Bidi(EchoGrpcDc.EchoBidiServer stream) throws Exception {
            inner.Bidi(stream);
        }
    }

    static void check(boolean condition, String what) {
        if (!condition) {
            throw new AssertionError(what);
        }
    }

    public static void main(String[] args) throws Exception {
        check(Codec.parseTimeout(Codec.encodeTimeout(Duration.ofMillis(250))).equals(Duration.ofMillis(250)),
                "timeout round trip");
        check(Codec.parseTimeout("10x") == null, "junk timeout");

        Transport[] pair = MemoryTransport.pair();
        Server server = new Server();
        SlowEcho slow = new SlowEcho();
        EchoGrpcDc.registerEchoServer(server, slow);
        server.serveTransport(pair[1]);
        EchoGrpcDc.EchoClient client = new EchoGrpcDc.EchoClient(new Channel(pair[0]));

        long start = System.nanoTime();
        try {
            client.Unary(new EchoRequest("hello", 0, 0), null, Duration.ofMillis(50));
            throw new AssertionError("expected deadline");
        } catch (StatusException e) {
            check(e.code == Wire.CODE_DEADLINE_EXCEEDED, "code " + e.code);
        }
        check(System.nanoTime() - start < Duration.ofMillis(350).toNanos(), "deadline fast");

        Endpoint.CallContext ctx = slow.seenCtx.get();
        check(ctx != null, "handler ran");
        check(ctx.metadata.containsKey("grpc-timeout"), "grpc-timeout metadata");
        check(ctx.deadlineNanos >= 0, "ctx deadline");
        check(ctx.timeRemaining() != null, "ctx remaining");

        EchoGrpcDc.EchoServerStreamStream stream =
                client.ServerStream(new EchoRequest("tick", 5, 0), null, Duration.ofMillis(150));
        check(stream.recv().index == 0, "stream first");
        try {
            stream.recv();
            throw new AssertionError("expected stream deadline");
        } catch (StatusException e) {
            check(e.code == Wire.CODE_DEADLINE_EXCEEDED, "stream code " + e.code);
        }

        EchoResponse joined = client.ClientStream(
                java.util.List.of(new EchoRequest("a", 0, 0), new EchoRequest("b", 0, 0)),
                Map.of(), Duration.ofSeconds(5));
        check(joined.message.equals("a+b"), "generous timeout: " + joined.message);
    }
}
