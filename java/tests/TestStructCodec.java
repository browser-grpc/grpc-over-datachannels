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
import grpcdc.Wire;
import java.io.EOFException;
import java.util.ArrayList;
import java.util.List;

/** Struct-codec negotiation: struct<->struct roundtrip, mismatch rejected, plain still works. */
public final class TestStructCodec {
    private TestStructCodec() {}

    private static EchoGrpcDc.EchoClient setup(boolean clientStruct, boolean serverStruct) {
        Transport[] pair = MemoryTransport.pair();
        Server server = new Server();
        server.setStructCodec(serverStruct);
        EchoGrpcDc.registerEchoServer(server, new EchoServiceImpl());
        server.serveTransport(pair[1]);
        Channel channel = new Channel(pair[0]);
        channel.setStructCodec(clientStruct);
        return new EchoGrpcDc.EchoClient(channel);
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
        // Struct client against struct server: all four shapes.
        EchoGrpcDc.EchoClient client = setup(true, true);

        EchoResponse unary = client.Unary(req("hello", 0));
        check(unary.message.equals("echo: hello"), "struct unary: " + unary);

        EchoGrpcDc.EchoServerStreamStream stream = client.ServerStream(req("tick", 3));
        int n = 0;
        while (true) {
            try {
                stream.recv();
            } catch (EOFException eof) {
                break;
            }
            n++;
        }
        check(n == 3, "struct server-stream count: " + n);

        EchoResponse joined = client.ClientStream(List.of(req("a", 0), req("b", 0)));
        check(joined.message.equals("a+b"), "struct client-stream: " + joined);

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
        check(echoed.equals(List.of("x", "y")), "struct bidi: " + echoed);

        // Struct wire bytes actually differ from protobuf and carry the magic.
        byte[] structBytes = req("hello", 0).marshalStruct();
        check(structBytes.length > 4
                && structBytes[0] == 'D' && structBytes[1] == 'C'
                && structBytes[2] == 'S' && structBytes[3] == '1',
                "struct magic missing");
        EchoRequest back = new EchoRequest();
        back.unmarshalStruct(structBytes);
        check(back.message.equals("hello"), "struct roundtrip: " + back.message);

        // Struct client against a protobuf-only server: UNIMPLEMENTED.
        EchoGrpcDc.EchoClient mismatch = setup(true, false);
        try {
            mismatch.Unary(req("hello", 0));
            check(false, "struct client vs plain server should fail");
        } catch (StatusException e) {
            check(e.code == Wire.CODE_UNIMPLEMENTED, "mismatch status: " + e);
        }

        // Plain client against a struct-enabled server: protobuf default still works.
        EchoGrpcDc.EchoClient plain = setup(false, true);
        EchoResponse plainResp = plain.Unary(req("hello", 0));
        check(plainResp.message.equals("echo: hello"), "plain vs struct server: " + plainResp);

        System.out.println("TestStructCodec OK");
    }
}
