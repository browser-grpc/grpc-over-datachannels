package tests;

import echo.EchoRequest;
import grpcdc.Codec;
import grpcdc.Wire;

/** Golden-vector codec tests (Fixtures stamped by the metaprogram). */
public final class TestCodec {
    private TestCodec() {}

    static void check(boolean condition, String what) {
        if (!condition) {
            throw new AssertionError(what);
        }
    }

    static byte[] hexBytes(String hex) {
        byte[] out = new byte[hex.length() / 2];
        for (int i = 0; i < out.length; i++) {
            out[i] = (byte) Integer.parseInt(hex.substring(2 * i, 2 * i + 2), 16);
        }
        return out;
    }

    static String hex(byte[] data) {
        StringBuilder sb = new StringBuilder();
        for (byte b : data) {
            sb.append(Character.forDigit((b >> 4) & 0xf, 16));
            sb.append(Character.forDigit(b & 0xf, 16));
        }
        return sb.toString();
    }

    public static void main(String[] args) {
        for (Object[] vector : Fixtures.FRAMES) {
            String name = (String) vector[0];
            int type = (Integer) vector[1];
            long stream = (Long) vector[2];
            byte[] raw = hexBytes((String) vector[3]);
            Codec.Frame frame = Codec.decodeFrame(raw);
            check(frame.type == type, name + ": type");
            check(frame.streamId == stream, name + ": stream");
            check(hex(Codec.encodeFrame(frame.type, frame.streamId, frame.payload))
                    .equals(vector[3]), name + ": re-encode");
            check(hex(frame.payload).equals(vector[4]), name + ": payload");
        }

        EchoRequest req = new EchoRequest("hi", 2, 0);
        check(hex(req.marshalDc()).equals(Fixtures.PROTO_HEX), "protobuf encode");
        EchoRequest decoded = new EchoRequest();
        decoded.unmarshalDc(hexBytes(Fixtures.PROTO_HEX));
        check(decoded.message.equals("hi") && decoded.count == 2, "protobuf decode");

        check(Wire.statusName(0).equals("OK"), "status 0");
        check(Wire.statusName(3).equals("INVALID-ARGUMENT"), "status 3");
        check(Wire.statusName(999).equals("CODE_999"), "status 999");
        System.out.println("TestCodec OK");
    }
}
