using System.Text;

namespace Echo;

/// <summary>Minimal protobuf wire writer/reader for the hand-written messages.</summary>
internal static class Pb
{
    internal sealed class Writer
    {
        private readonly MemoryStream _out = new();

        public void Varint(long value)
        {
            ulong v = unchecked((ulong)value);
            while ((v & ~0x7fUL) != 0)
            {
                _out.WriteByte((byte)((v & 0x7f) | 0x80));
                v >>= 7;
            }
            _out.WriteByte((byte)v);
        }

        public void StringField(int field, string value)
        {
            if (string.IsNullOrEmpty(value))
            {
                return;
            }
            byte[] bytes = Encoding.UTF8.GetBytes(value);
            Varint((field << 3) | 2);
            Varint(bytes.Length);
            _out.Write(bytes, 0, bytes.Length);
        }

        public void Int32Field(int field, int value)
        {
            if (value == 0)
            {
                return;
            }
            Varint((field << 3) | 0);
            Varint(value);
        }

        public byte[] ToBytes() => _out.ToArray();
    }

    internal sealed class Field
    {
        public int Number { get; }
        public long VarintValue { get; }
        public byte[] BytesValue { get; }

        internal Field(int number, long varintValue, byte[] bytesValue)
        {
            Number = number;
            VarintValue = varintValue;
            BytesValue = bytesValue;
        }

        public int AsInt32() => (int)VarintValue;

        public string AsString() => BytesValue == null ? "" : Encoding.UTF8.GetString(BytesValue);
    }

    internal sealed class Reader
    {
        private readonly byte[] _buf;
        private int _pos;

        internal Reader(byte[] buf)
        {
            _buf = buf;
        }

        public long Varint()
        {
            long result = 0;
            int shift = 0;
            while (true)
            {
                if (_pos >= _buf.Length)
                {
                    throw new ArgumentException("truncated varint");
                }
                int b = _buf[_pos++];
                result |= (long)(b & 0x7f) << shift;
                if ((b & 0x80) == 0)
                {
                    return result;
                }
                shift += 7;
                if (shift >= 64)
                {
                    throw new ArgumentException("varint too long");
                }
            }
        }

        /// <summary>Next field, or null at end.</summary>
        public Field Next()
        {
            if (_pos >= _buf.Length)
            {
                return null;
            }
            long tag = Varint();
            int number = (int)(tag >> 3);
            switch ((int)(tag & 7))
            {
                case 0:
                    return new Field(number, Varint(), null);
                case 2:
                {
                    int n = (int)Varint();
                    if (_pos + n > _buf.Length)
                    {
                        throw new ArgumentException("truncated bytes field");
                    }
                    var value = new byte[n];
                    Array.Copy(_buf, _pos, value, 0, n);
                    _pos += n;
                    return new Field(number, 0, value);
                }
                case 1:
                {
                    if (_pos + 8 > _buf.Length)
                    {
                        throw new ArgumentException("truncated fixed64");
                    }
                    var value = new byte[8];
                    Array.Copy(_buf, _pos, value, 0, 8);
                    _pos += 8;
                    return new Field(number, 0, value);
                }
                case 5:
                {
                    if (_pos + 4 > _buf.Length)
                    {
                        throw new ArgumentException("truncated fixed32");
                    }
                    var value = new byte[4];
                    Array.Copy(_buf, _pos, value, 0, 4);
                    _pos += 4;
                    return new Field(number, 0, value);
                }
                default:
                    throw new ArgumentException("bad wire type");
            }
        }
    }
}
