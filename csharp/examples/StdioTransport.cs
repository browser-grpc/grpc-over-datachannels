using Grpcdc;

namespace Echo;

/// <summary>
/// Stdio transport: frames DataChannel messages over a byte stream
/// with a 4-byte big-endian length prefix (the prefix exists only to
/// frame messages on stdio; each framed unit is exactly one
/// DataChannel message). Used by the cross-language interop harnesses.
/// Mirrors go/examples/stdio.go.
/// </summary>
public sealed class StdioTransport : ITransport
{
    private readonly Stream _writer;
    private readonly Stream _reader;
    private readonly object _lock = new();

    /// <summary>Set to exit the process when the driver goes away.</summary>
    public volatile Action OnEof;

    public StdioTransport(Stream writer, Stream reader)
    {
        _writer = writer;
        _reader = reader;
    }

    public void Send(byte[] data)
    {
        lock (_lock)
        {
            _writer.WriteByte((byte)(data.Length >> 24));
            _writer.WriteByte((byte)(data.Length >> 16));
            _writer.WriteByte((byte)(data.Length >> 8));
            _writer.WriteByte((byte)data.Length);
            _writer.Write(data, 0, data.Length);
            _writer.Flush();
        }
    }

    public byte[] Recv()
    {
        byte[] header = ReadExact(4);
        if (header.Length < 4)
        {
            Eof();
            throw new EndOfStreamException("stdio closed");
        }
        int length = (header[0] << 24) | (header[1] << 16) | (header[2] << 8) | header[3];
        byte[] payload = ReadExact(length);
        if (payload.Length < length)
        {
            Eof();
            throw new EndOfStreamException("stdio closed mid-frame");
        }
        return payload;
    }

    private byte[] ReadExact(int n)
    {
        byte[] output = new byte[n];
        int pos = 0;
        while (pos < n)
        {
            int read = _reader.Read(output, pos, n - pos);
            if (read <= 0)
            {
                break;
            }
            pos += read;
        }
        if (pos < n)
        {
            var partial = new byte[pos];
            Array.Copy(output, partial, pos);
            return partial;
        }
        return output;
    }

    private void Eof()
    {
        OnEof?.Invoke();
    }
}
