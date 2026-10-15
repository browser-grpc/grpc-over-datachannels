package echo;

import grpcdc.Transport;
import java.io.EOFException;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;

/**
 * Stdio transport: frames DataChannel messages over a byte stream with
 * a 4-byte big-endian length prefix (the prefix exists only to frame
 * messages on stdio; each framed unit is exactly one DataChannel
 * message). Used by the cross-language interop harnesses.
 * Mirrors go/examples/stdio.go.
 */
public final class StdioTransport implements Transport {
    private final OutputStream writer;
    private final InputStream reader;
    private final Object lock = new Object();
    /** Set to exit the process when the driver goes away. */
    public volatile Runnable onEof;

    public StdioTransport(OutputStream writer, InputStream reader) {
        this.writer = writer;
        this.reader = reader;
    }

    @Override
    public void send(byte[] data) throws Exception {
        synchronized (lock) {
            writer.write((data.length >>> 24) & 0xff);
            writer.write((data.length >>> 16) & 0xff);
            writer.write((data.length >>> 8) & 0xff);
            writer.write(data.length & 0xff);
            writer.write(data);
            writer.flush();
        }
    }

    @Override
    public byte[] recv() throws Exception {
        byte[] header = readExact(4);
        if (header.length < 4) {
            eof();
            throw new EOFException("stdio closed");
        }
        int length = ((header[0] & 0xff) << 24) | ((header[1] & 0xff) << 16)
                | ((header[2] & 0xff) << 8) | (header[3] & 0xff);
        byte[] payload = readExact(length);
        if (payload.length < length) {
            eof();
            throw new EOFException("stdio closed mid-frame");
        }
        return payload;
    }

    private byte[] readExact(int n) throws IOException {
        byte[] out = new byte[n];
        int pos = 0;
        while (pos < n) {
            int read = reader.read(out, pos, n - pos);
            if (read < 0) {
                break;
            }
            pos += read;
        }
        if (pos < n) {
            byte[] partial = new byte[pos];
            System.arraycopy(out, 0, partial, 0, pos);
            return partial;
        }
        return out;
    }

    private void eof() {
        Runnable hook = onEof;
        if (hook != null) {
            hook.run();
        }
    }
}
