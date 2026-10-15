package echo;

import grpcdc.Marshaler;
import grpcdc.Unmarshaler;

/**
 * Hand-written protobuf messages for proto/echo.proto (package echo).
 *
 * <p>Deliberately minimal (two messages) so the example needs no
 * protobuf codegen dependency — the wire bytes are genuine protobuf:
 * EchoRequest{message:"hi", count:2} encodes to 0a0268691002.
 * Mirrors go/examples/echo_pb.go.
 */
public final class EchoRequest implements Marshaler, Unmarshaler {
    public String message = "";
    public int count;
    public int delayMs;

    public EchoRequest() {}

    public EchoRequest(String message, int count) {
        this.message = message;
        this.count = count;
    }

    @Override
    public byte[] marshalDc() {
        Pb.Writer w = new Pb.Writer();
        w.stringField(1, message);
        w.int32Field(2, count);
        w.int32Field(3, delayMs);
        return w.toBytes();
    }

    @Override
    public void unmarshalDc(byte[] data) {
        message = "";
        count = 0;
        delayMs = 0;
        Pb.Reader r = new Pb.Reader(data);
        Pb.Field field;
        while ((field = r.next()) != null) {
            switch (field.number) {
                case 1 -> message = field.asString();
                case 2 -> count = field.asInt32();
                case 3 -> delayMs = field.asInt32();
                default -> {
                    // skip unknown fields
                }
            }
        }
    }

    @Override
    public String toString() {
        return "EchoRequest{message=" + message + ", count=" + count + ", delayMs=" + delayMs + "}";
    }
}
