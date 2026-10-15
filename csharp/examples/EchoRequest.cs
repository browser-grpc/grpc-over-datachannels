using Grpcdc;

namespace Echo;

/// <summary>
/// Hand-written protobuf messages for proto/echo.proto (package echo).
///
/// Deliberately minimal (two messages) so the example needs no
/// protobuf codegen dependency — the wire bytes are genuine protobuf:
/// EchoRequest{message:"hi", count:2} encodes to 0a0268691002.
/// Mirrors go/examples/echo_pb.go.
/// </summary>
public sealed class EchoRequest : IMarshaler, IUnmarshaler
{
    public string Message = "";
    public int Count;
    public int DelayMs;

    public EchoRequest()
    {
    }

    public EchoRequest(string message, int count)
    {
        Message = message;
        Count = count;
    }

    public byte[] MarshalDc()
    {
        var w = new Pb.Writer();
        w.StringField(1, Message);
        w.Int32Field(2, Count);
        w.Int32Field(3, DelayMs);
        return w.ToBytes();
    }

    public void UnmarshalDc(byte[] data)
    {
        Message = "";
        Count = 0;
        DelayMs = 0;
        var r = new Pb.Reader(data);
        Pb.Field field;
        while ((field = r.Next()) != null)
        {
            switch (field.Number)
            {
                case 1: Message = field.AsString(); break;
                case 2: Count = field.AsInt32(); break;
                case 3: DelayMs = field.AsInt32(); break;
                default: break; // skip unknown fields
            }
        }
    }

    public override string ToString() => $"EchoRequest{{message={Message}, count={Count}, delayMs={DelayMs}}}";
}
