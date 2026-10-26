package tests;

import echo.EchoGrpcDc;
import echo.EchoRequest;
import echo.EchoResponse;
import echo.EchoServiceImpl;
import grpcdc.Channel;
import grpcdc.MemoryTransport;
import grpcdc.Server;
import grpcdc.StatusException;
import grpcdc.Transport;
import java.io.EOFException;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicInteger;

/** Loopback end-to-end: all four shapes, error status, metadata. */
public final class TestEcho {
    private TestEcho() {}

    private static EchoGrpcDc.EchoClient setup() {
        Transport[] pair = MemoryTransport.pair();
        Server server = new Server();
        EchoGrpcDc.registerEchoServer(server, new EchoServiceImpl());
        server.serveTransport(pair[1]);
        return new EchoGrpcDc.EchoClient(new Channel(pair[0]));
    }

    private static EchoRequest req(String message, int count) {
        return new EchoRequest(message, count, 0);
    }

    static void check(boolean condition, String what) {
        if (!condition) {
            throw new AssertionError(what);
        }
    }

    public static void main(String[] args) throws Exception {
        EchoGrpcDc.EchoClient client = setup();

        EchoResponse unary = client.Unary(req("hello", 0));
        check(unary.message.equals("echo: hello") && unary.index == 0, "unary: " + unary);

        EchoGrpcDc.EchoServerStreamStream stream = client.ServerStream(req("tick", 3));
        List<Integer> indexes = new ArrayList<>();
        while (true) {
            EchoResponse resp;
            try {
                resp = stream.recv();
            } catch (EOFException eof) {
                break;
            }
            check(resp.message.equals("tick"), "stream message: " + resp);
            indexes.add(resp.index);
        }
        check(indexes.equals(List.of(0, 1, 2)), "stream indexes: " + indexes);

        EchoResponse joined = client.ClientStream(List.of(req("a", 0), req("b", 0), req("c", 0)));
        check(joined.message.equals("a+b+c") && joined.index == 3, "client stream: " + joined);

        EchoGrpcDc.EchoBidiStream bidi = client.Bidi(List.of(req("x", 0), req("y", 0)));
        List<String> echoed = new ArrayList<>();
        while (true) {
            EchoResponse resp;
            try {
                resp = bidi.recv();
            } catch (EOFException eof) {
                break;
            }
            echoed.add(resp.message);
        }
        check(echoed.equals(List.of("x", "y")), "bidi: " + echoed);

        try {
            client.Unary(req("fail", 0));
            check(false, "fail call should throw");
        } catch (StatusException e) {
            check(e.code == 3, "fail status: " + e);
        }

        EchoResponse withMd = client.Unary(req("hello", 0), Map.of("x-echo", "meta"));
        check(withMd.message.equals("echo: hello [meta]"), "metadata: " + withMd);

        runAsync(client);

        testBreakingServerStreamCancels();

        System.out.println("TestEcho OK");
    }

    /** Counting service for the stream-break regression test. */
    static final class CountingEchoService implements EchoGrpcDc.EchoServer {
        private final AtomicInteger produced;

        CountingEchoService(AtomicInteger produced) {
            this.produced = produced;
        }

        @Override
        public EchoResponse Unary(grpcdc.Endpoint.CallContext ctx, EchoRequest req) {
            return new EchoResponse("echo: " + req.message, 0);
        }

        @Override
        public void ServerStream(EchoRequest req, EchoGrpcDc.EchoServerStreamServer stream) throws Exception {
            for (int i = 0; i < Math.max(0, req.count); i++) {
                produced.incrementAndGet();
                stream.send(new EchoResponse(req.message, i));
                Thread.sleep(10);
            }
        }

        @Override
        public void ClientStream(EchoGrpcDc.EchoClientStreamServer stream) throws Exception {
            List<String> parts = new ArrayList<>();
            while (true) {
                try {
                    parts.add(stream.recv().message);
                } catch (EOFException eof) {
                    break;
                }
            }
            stream.sendAndClose(new EchoResponse(String.join("+", parts), parts.size()));
        }

        @Override
        public void Bidi(EchoGrpcDc.EchoBidiServer stream) throws Exception {
            int index = 0;
            while (true) {
                EchoRequest req;
                try {
                    req = stream.recv();
                } catch (EOFException eof) {
                    return;
                }
                stream.send(new EchoResponse(req.message, index++));
            }
        }
    }

    // Closing the response stream (try-with-resources) after one
    // response must RST the call: the producing handler's next
    // send fails with CANCELLED and production settles.
    private static void testBreakingServerStreamCancels() throws Exception {
        AtomicInteger produced = new AtomicInteger();
        Transport[] pair = MemoryTransport.pair();
        Server server = new Server();
        EchoGrpcDc.registerEchoServer(server, new CountingEchoService(produced));
        server.serveTransport(pair[1]);
        EchoGrpcDc.EchoClient client = new EchoGrpcDc.EchoClient(new Channel(pair[0]));

        int seen = 0;
        try (EchoGrpcDc.EchoServerStreamStream stream = client.ServerStream(req("tick", 1000))) {
            EchoResponse first = stream.recv();
            check(first.index == 0, "break stream first response: " + first);
            seen = 1;
        }
        check(seen == 1, "break stream seen: " + seen);

        Thread.sleep(100);
        int settled = produced.get();
        Thread.sleep(100);
        check(produced.get() == settled,
                "server kept producing after close: " + settled + " -> " + produced.get());
        check(settled < 100, "server produced too many responses: " + settled);
    }

    /** Async implementation used to test registerEchoServerAsync. */
    static final class AsyncEchoService implements EchoGrpcDc.EchoServerAsync {
        private final EchoServiceImpl inner = new EchoServiceImpl();

        @Override
        public java.util.concurrent.CompletableFuture<EchoResponse> UnaryAsync(
                grpcdc.Endpoint.CallContext ctx, EchoRequest req) {
            return java.util.concurrent.CompletableFuture.supplyAsync(() -> {
                try {
                    return inner.Unary(ctx, req);
                } catch (Exception e) {
                    throw new java.util.concurrent.CompletionException(e);
                }
            });
        }

        @Override
        public java.util.concurrent.CompletableFuture<Void> ServerStreamAsync(
                EchoRequest req, EchoGrpcDc.EchoServerStreamServer stream) {
            return java.util.concurrent.CompletableFuture.runAsync(() -> {
                try {
                    inner.ServerStream(req, stream);
                } catch (Exception e) {
                    throw new java.util.concurrent.CompletionException(e);
                }
            });
        }

        @Override
        public java.util.concurrent.CompletableFuture<Void> ClientStreamAsync(
                EchoGrpcDc.EchoClientStreamServer stream) {
            return java.util.concurrent.CompletableFuture.runAsync(() -> {
                try {
                    inner.ClientStream(stream);
                } catch (Exception e) {
                    throw new java.util.concurrent.CompletionException(e);
                }
            });
        }

        @Override
        public java.util.concurrent.CompletableFuture<Void> BidiAsync(
                EchoGrpcDc.EchoBidiServer stream) {
            return java.util.concurrent.CompletableFuture.runAsync(() -> {
                try {
                    inner.Bidi(stream);
                } catch (Exception e) {
                    throw new java.util.concurrent.CompletionException(e);
                }
            });
        }
    }

    private static void runAsync(EchoGrpcDc.EchoClient client) throws Exception {
        // Async client surface (CompletableFuture) over the sync server.
        EchoResponse unary = client.UnaryAsync(req("hello", 0)).join();
        check(unary.message.equals("echo: hello"), "async unary: " + unary);

        java.util.List<EchoResponse> ticks = client.ServerStreamAllAsync(req("tick", 3)).join();
        check(ticks.size() == 3 && ticks.get(2).index == 2, "async stream: " + ticks);

        EchoResponse joined = client.ClientStreamAsync(List.of(req("a", 0), req("b", 0))).join();
        check(joined.message.equals("a+b"), "async client stream: " + joined);

        java.util.List<EchoResponse> echoed = client.BidiAllAsync(List.of(req("x", 0), req("y", 0))).join();
        check(echoed.size() == 2 && echoed.get(1).message.equals("y"), "async bidi: " + echoed);

        // Status errors surface as CompletionException causes.
        try {
            client.UnaryAsync(req("fail", 0)).join();
            check(false, "async fail should throw");
        } catch (java.util.concurrent.CompletionException e) {
            check(e.getCause() instanceof StatusException
                    && ((StatusException) e.getCause()).code == 3, "async fail: " + e);
        }

        // Async server surface against the sync client.
        Transport[] pair = MemoryTransport.pair();
        Server server = new Server();
        EchoGrpcDc.registerEchoServerAsync(server, new AsyncEchoService());
        server.serveTransport(pair[1]);
        EchoGrpcDc.EchoClient syncClient = new EchoGrpcDc.EchoClient(new Channel(pair[0]));
        EchoResponse viaAsync = syncClient.Unary(req("hello", 0));
        check(viaAsync.message.equals("echo: hello"), "async server unary: " + viaAsync);

        // Async-registered server preserves status codes.
        try {
            syncClient.Unary(req("fail", 0));
            check(false, "async server fail should throw");
        } catch (StatusException e) {
            check(e.code == 3, "async server fail status: " + e);
        }
    }
}
