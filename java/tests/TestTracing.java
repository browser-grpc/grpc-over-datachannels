package tests;

import echo.EchoGrpcDc;
import echo.EchoRequest;
import echo.EchoResponse;
import echo.EchoServiceImpl;
import grpcdc.Channel;
import grpcdc.Endpoint;
import grpcdc.MemoryTransport;
import grpcdc.Server;
import grpcdc.Tracing;
import grpcdc.Transport;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.atomic.AtomicReference;

/** Tracing: nested callee call joins the trace via the bound channel. */
public final class TestTracing {
    private TestTracing() {}

    record Start(String kind, String method, String traceId, String spanId, String parentSpanId) {}

    static final class Recorder implements Tracing.Tracer {
        final List<Start> starts = new ArrayList<>();
        final List<Double> endDurations = new ArrayList<>();

        @Override
        public void onStart(String kind, String method, String traceId, String spanId, String parentSpanId) {
            synchronized (starts) {
                starts.add(new Start(kind, method, traceId, spanId, parentSpanId));
            }
        }

        @Override
        public void onEnd(String kind, String method, String traceId, String spanId, String status, double durationMs) {
            synchronized (endDurations) {
                endDurations.add(durationMs);
            }
        }
    }

    static final class Front implements EchoGrpcDc.EchoServer {
        final EchoServiceImpl inner = new EchoServiceImpl();
        final EchoGrpcDc.EchoClient downstream;
        final AtomicReference<String> seenSpan = new AtomicReference<>();

        Front(EchoGrpcDc.EchoClient downstream) {
            this.downstream = downstream;
        }

        @Override
        public EchoResponse Unary(Endpoint.CallContext ctx, EchoRequest req) throws Exception {
            seenSpan.set(ctx.traceContext == null ? null : ctx.traceContext.spanId());
            EchoGrpcDc.EchoClient bound = new EchoGrpcDc.EchoClient(
                    downstreamChannel.withTraceContext(ctx.traceContext));
            return bound.Unary(new EchoRequest("nested", 0, 0));
        }

        Channel downstreamChannel;

        @Override
        public void ServerStream(EchoRequest req, EchoGrpcDc.EchoServerStreamServer stream) throws Exception {
            inner.ServerStream(req, stream);
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
        Recorder rec = new Recorder();
        Tracing.setTracer(rec);
        try {
            Transport[] backPair = MemoryTransport.pair();
            Server back = new Server();
            EchoGrpcDc.registerEchoServer(back, new EchoServiceImpl());
            back.serveTransport(backPair[1]);
            Channel downstreamChannel = new Channel(backPair[0]);

            Front front = new Front(new EchoGrpcDc.EchoClient(downstreamChannel));
            front.downstreamChannel = downstreamChannel;

            Transport[] pair = MemoryTransport.pair();
            Server frontServer = new Server();
            EchoGrpcDc.registerEchoServer(frontServer, front);
            frontServer.serveTransport(pair[1]);
            EchoGrpcDc.EchoClient client = new EchoGrpcDc.EchoClient(new Channel(pair[0]));

            EchoResponse resp = client.Unary(new EchoRequest("hello", 0, 0));
            check(resp.message.equals("echo: nested"), "resp " + resp.message);

            List<Start> starts;
            synchronized (rec.starts) {
                starts = new ArrayList<>(rec.starts);
            }
            check(starts.size() == 4, "starts " + starts);
            check(starts.get(0).kind().equals("client") && starts.get(1).kind().equals("server")
                    && starts.get(2).kind().equals("client") && starts.get(3).kind().equals("server"),
                    "kinds " + starts);
            for (Start s : starts) {
                check(s.traceId().equals(starts.get(0).traceId()), "trace id " + s);
            }
            check(starts.get(1).parentSpanId().equals(starts.get(0).spanId()), "server parent");
            check(starts.get(2).parentSpanId().equals(starts.get(1).spanId()), "inner client parent");
            check(starts.get(3).parentSpanId().equals(starts.get(2).spanId()), "inner server parent");
            check(starts.get(1).spanId().equals(front.seenSpan.get()), "ctx span");
            synchronized (rec.endDurations) {
                check(rec.endDurations.size() == 4, "ends " + rec.endDurations.size());
                check(rec.endDurations.stream().allMatch(d -> d >= 0), "durations");
            }
            System.out.println("TestTracing OK");
        } finally {
            Tracing.setTracer(null);
        }
    }
}
