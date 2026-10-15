using Grpcdc;

namespace Echo;

/// <summary>Hand-written protobuf message; see EchoRequest for rationale.</summary>
public sealed class EchoResponse : IMarshaler, IUnmarshaler
{
    public string Message = "";
    public int Index;

    public EchoResponse()
    {
    }

    public EchoResponse(string message, int index)
    {
        Message = message;
        Index = index;
    }

    public byte[] MarshalDc()
    {
        var w = new Pb.Writer();
        w.StringField(1, Message);
        w.Int32Field(2, Index);
        return w.ToBytes();
    }

    public void UnmarshalDc(byte[] data)
    {
        Message = "";
        Index = 0;
        var r = new Pb.Reader(data);
        Pb.Field field;
        while ((field = r.Next()) != null)
        {
            switch (field.Number)
            {
                case 1: Message = field.AsString(); break;
                case 2: Index = field.AsInt32(); break;
                default: break; // skip unknown fields
            }
        }
    }

    public override string ToString() => $"EchoResponse{{message={Message}, index={Index}}}";
}
