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

/** BDD: interprets the generated behavior scenarios (BddScenarios,
 * stamped from racket/bdd-spec.rkt; prose in BDD.md) against a
 * loopback client+server — the executable examples. */
public final class TestBdd {
    private TestBdd() {}

    private static EchoRequest req(String message, int count) {
        return new EchoRequest(message, count, 0);
    }

    static void check(boolean condition, String what) {
        if (!condition) {
            throw new AssertionError(what);
        }
    }

    public static void main(String[] args) throws Exception {
        Transport[] pair = MemoryTransport.pair();
        Server server = new Server();
        EchoGrpcDc.registerEchoServer(server, new EchoServiceImpl());
        server.serveTransport(pair[1]);
        Channel channel = new Channel(pair[0]);
        EchoGrpcDc.EchoClient client = new EchoGrpcDc.EchoClient(channel);

        for (Object[] row : BddScenarios.CASES) {
            String name = (String) row[0];
            String kind = (String) row[1];
            String[] messages = (String[]) row[2];
            int count = (Integer) row[3];
            String path = (String) row[4];
            String metadata = (String) row[5];
            String expectMessage = (String) row[6];
            int expectNum = (Integer) row[7];
            int expectStatus = (Integer) row[8];

            switch (kind) {
                case "unary" -> {
                    Map<String, String> md = metadata.isEmpty() ? null : Map.of("x-echo", metadata);
                    try {
                        EchoResponse resp = client.Unary(req(messages[0], 0), md);
                        check(expectStatus < 0, name + ": expected failure, got " + resp);
                        check(resp.message.equals(expectMessage) && resp.index == expectNum,
                                name + ": " + resp);
                    } catch (StatusException e) {
                        check(expectStatus >= 0 && e.code == expectStatus,
                                name + ": status " + e + ", want " + expectStatus);
                    }
                }
                case "server-stream" -> {
                    EchoGrpcDc.EchoServerStreamStream stream =
                            client.ServerStream(req(messages[0], count));
                    int got = 0;
                    while (true) {
                        EchoResponse resp;
                        try {
                            resp = stream.recv();
                        } catch (EOFException eof) {
                            break;
                        }
                        check(resp.message.equals(expectMessage) && resp.index == got,
                                name + ": " + resp + " at " + got);
                        got++;
                    }
                    check(got == expectNum, name + ": got " + got + ", want " + expectNum);
                }
                case "client-stream" -> {
                    List<EchoRequest> reqs = new ArrayList<>();
                    for (String m : messages) reqs.add(req(m, 0));
                    EchoResponse resp = client.ClientStream(reqs);
                    check(resp.message.equals(expectMessage) && resp.index == expectNum,
                            name + ": " + resp);
                }
                case "bidi" -> {
                    List<EchoRequest> reqs = new ArrayList<>();
                    for (String m : messages) reqs.add(req(m, 0));
                    EchoGrpcDc.EchoBidiStream stream = client.Bidi(reqs);
                    int got = 0;
                    while (true) {
                        EchoResponse resp;
                        try {
                            resp = stream.recv();
                        } catch (EOFException eof) {
                            break;
                        }
                        check(got < messages.length && resp.message.equals(messages[got])
                                        && resp.index == got,
                                name + ": " + resp + " at " + got);
                        got++;
                    }
                    check(got == expectNum, name + ": got " + got + ", want " + expectNum);
                }
                case "server-stream-fail" -> {
                    EchoGrpcDc.EchoServerStreamStream stream =
                            client.ServerStream(req(messages[0], count));
                    try {
                        while (true) {
                            stream.recv();
                        }
                    } catch (StatusException e) {
                        check(e.code == expectStatus,
                                name + ": status " + e + ", want " + expectStatus);
                    } catch (EOFException eof) {
                        check(false, name + ": expected failure, stream ended OK");
                    }
                }
                case "bidi-fail" -> {
                    List<EchoRequest> reqs = new ArrayList<>();
                    for (String m : messages) reqs.add(req(m, 0));
                    EchoGrpcDc.EchoBidiStream stream = client.Bidi(reqs);
                    try {
                        while (true) {
                            stream.recv();
                        }
                    } catch (StatusException e) {
                        check(e.code == expectStatus,
                                name + ": status " + e + ", want " + expectStatus);
                    } catch (EOFException eof) {
                        check(false, name + ": expected failure, stream ended OK");
                    }
                }
                case "deadline" -> {
                    try {
                        client.Unary(new EchoRequest(messages[0], 0, count), null,
                                java.time.Duration.ofMillis(100));
                        check(false, name + ": expected deadline failure");
                    } catch (StatusException e) {
                        check(e.code == expectStatus,
                                name + ": status " + e + ", want " + expectStatus);
                    }
                }
                case "cancel" -> {
                    Channel.ClientStream stream = channel.serverStream(
                            "/echo.Echo/ServerStream", req(messages[0], count), null);
                    EchoResponse firstResp = new EchoResponse();
                    stream.recv(firstResp);
                    check(firstResp.message.equals(messages[0]),
                            name + ": first " + firstResp);
                    stream.cancel();
                    boolean terminated = false;
                    try {
                        for (int i = 0; i < count + 2 && !terminated; i++) {
                            stream.recv(new EchoResponse());
                        }
                    } catch (Exception e) {
                        terminated = true;
                    }
                    check(terminated, name + ": stream did not terminate after cancel");
                }
                case "raw-unary" -> {
                    try {
                        channel.unary(path, req(messages[0], 0), new EchoResponse(), null);
                        check(false, name + ": expected failure");
                    } catch (StatusException e) {
                        check(e.code == expectStatus,
                                name + ": status " + e + ", want " + expectStatus);
                    }
                }
                default -> throw new AssertionError("unknown bdd kind: " + kind);
            }
        }
        System.out.println("TestBdd OK");
    }
}
