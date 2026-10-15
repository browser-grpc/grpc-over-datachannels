package echo;

import grpcdc.Marshaler;
import grpcdc.Unmarshaler;

/** Hand-written protobuf message; see EchoRequest for rationale. */
public final class EchoResponse implements Marshaler, Unmarshaler {
    public String message = "";
    public int index;

    public EchoResponse() {}

    public EchoResponse(String message, int index) {
        this.message = message;
        this.index = index;
    }

    @Override
    public byte[] marshalDc() {
        Pb.Writer w = new Pb.Writer();
        w.stringField(1, message);
        w.int32Field(2, index);
        return w.toBytes();
    }

    @Override
    public void unmarshalDc(byte[] data) {
        message = "";
        index = 0;
        Pb.Reader r = new Pb.Reader(data);
        Pb.Field field;
        while ((field = r.next()) != null) {
            switch (field.number) {
                case 1 -> message = field.asString();
                case 2 -> index = field.asInt32();
                default -> {
                    // skip unknown fields
                }
            }
        }
    }

    @Override
    public String toString() {
        return "EchoResponse{message=" + message + ", index=" + index + "}";
    }
}
