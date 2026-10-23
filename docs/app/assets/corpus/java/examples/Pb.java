package echo;

import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;

/** Minimal protobuf wire writer/reader for the hand-written messages. */
final class Pb {
    private Pb() {}

    static final class Writer {
        private final ByteArrayOutputStream out = new ByteArrayOutputStream();

        void varint(long value) {
            long v = value;
            while ((v & ~0x7fL) != 0) {
                out.write(((int) (v & 0x7f)) | 0x80);
                v >>>= 7;
            }
            out.write((int) v);
        }

        void stringField(int field, String value) {
            if (value == null || value.isEmpty()) {
                return;
            }
            byte[] bytes = value.getBytes(StandardCharsets.UTF_8);
            varint((field << 3) | 2);
            varint(bytes.length);
            out.write(bytes, 0, bytes.length);
        }

        void int32Field(int field, int value) {
            if (value == 0) {
                return;
            }
            varint((field << 3) | 0);
            varint(value);
        }

        byte[] toBytes() {
            return out.toByteArray();
        }
    }

    static final class Field {
        final int number;
        final long varintValue;
        final byte[] bytesValue;

        Field(int number, long varintValue, byte[] bytesValue) {
            this.number = number;
            this.varintValue = varintValue;
            this.bytesValue = bytesValue;
        }

        int asInt32() {
            return (int) varintValue;
        }

        String asString() {
            return bytesValue == null ? "" : new String(bytesValue, StandardCharsets.UTF_8);
        }
    }

    static final class Reader {
        private final byte[] buf;
        private int pos;

        Reader(byte[] buf) {
            this.buf = buf;
        }

        long varint() {
            long result = 0;
            int shift = 0;
            while (true) {
                if (pos >= buf.length) {
                    throw new IllegalArgumentException("truncated varint");
                }
                int b = buf[pos++] & 0xff;
                result |= (long) (b & 0x7f) << shift;
                if ((b & 0x80) == 0) {
                    return result;
                }
                shift += 7;
                if (shift >= 64) {
                    throw new IllegalArgumentException("varint too long");
                }
            }
        }

        /** Next field, or null at end. */
        Field next() {
            if (pos >= buf.length) {
                return null;
            }
            long tag = varint();
            int number = (int) (tag >> 3);
            switch ((int) (tag & 7)) {
                case 0 -> {
                    return new Field(number, varint(), null);
                }
                case 2 -> {
                    int n = (int) varint();
                    if (pos + n > buf.length) {
                        throw new IllegalArgumentException("truncated bytes field");
                    }
                    byte[] value = new byte[n];
                    System.arraycopy(buf, pos, value, 0, n);
                    pos += n;
                    return new Field(number, 0, value);
                }
                case 1 -> {
                    if (pos + 8 > buf.length) {
                        throw new IllegalArgumentException("truncated fixed64");
                    }
                    byte[] value = new byte[8];
                    System.arraycopy(buf, pos, value, 0, 8);
                    pos += 8;
                    return new Field(number, 0, value);
                }
                case 5 -> {
                    if (pos + 4 > buf.length) {
                        throw new IllegalArgumentException("truncated fixed32");
                    }
                    byte[] value = new byte[4];
                    System.arraycopy(buf, pos, value, 0, 4);
                    pos += 4;
                    return new Field(number, 0, value);
                }
                default -> throw new IllegalArgumentException("bad wire type");
            }
        }
    }
}
