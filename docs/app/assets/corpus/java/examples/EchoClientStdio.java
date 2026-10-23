package echo;

import grpcdc.Channel;
import grpcdc.StatusException;
import java.io.EOFException;
import java.util.ArrayList;
import java.util.List;

/**
 * Interop harness: the Java echo client over stdio. Prints one line
 * per call shape to stderr (stdout carries frames) and exits non-zero
 * on any failure. Mirrors go/examples/echo_client_stdio.
 */
public final class EchoClientStdio {
    private EchoClientStdio() {}

    private static EchoRequest req(String message, int count) {
        return new EchoRequest(message, count, 0);
    }

    public static void main(String[] args) throws Exception {
        StdioTransport transport = new StdioTransport(System.out, System.in);
        EchoGrpcDc.EchoClient client = new EchoGrpcDc.EchoClient(new Channel(transport));

        EchoResponse unary = client.Unary(req("hello", 0));
        System.err.println("unary=" + unary.message);

        EchoGrpcDc.EchoServerStreamStream stream = client.ServerStream(req("tick", 3));
        List<String> ticks = new ArrayList<>();
        while (true) {
            EchoResponse resp;
            try {
                resp = stream.recv();
            } catch (EOFException eof) {
                break;
            }
            ticks.add(resp.message + "#" + resp.index);
        }
        System.err.println("server_stream=" + String.join(",", ticks));

        EchoResponse joined = client.ClientStream(List.of(req("a", 0), req("b", 0), req("c", 0)));
        System.err.println("client_stream=" + joined.message);

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
        System.err.println("bidi=" + String.join(",", echoed));

        EchoResponse mdResp = client.Unary(req("hello", 0), java.util.Map.of("x-echo", "meta"));
        System.err.println("metadata=" + mdResp.message);

        try {
            EchoRequest slow = req("slow", 0);
            slow.delayMs = 400;
            client.Unary(slow, null, java.time.Duration.ofMillis(50));
            System.err.println("deadline=no error");
        } catch (StatusException se) {
            System.err.println("deadline=" + se.code);
        }

        try {
            client.Unary(req("fail", 0));
            System.err.println("error_case=no error");
            System.exit(1);
        } catch (StatusException e) {
            System.err.println("error_case=" + e);
        }
    }
}
