package echo

import grpcdc.Transport
import java.io.EOFException
import java.io.InputStream
import java.io.OutputStream

/**
 * Stdio transport: frames DataChannel messages over a byte stream
 * with a 4-byte big-endian length prefix (the prefix exists only to
 * frame messages on stdio; each framed unit is exactly one
 * DataChannel message). Used by the cross-language interop harnesses.
 */
class StdioTransport(private val out: OutputStream, private val inp: InputStream) : Transport {
    /** Invoked once when the input reaches EOF (stdio harnesses exit on it). */
    var onEof: (() -> Unit)? = null

    @Synchronized
    override fun send(data: ByteArray) {
        val len = data.size
        out.write(
            byteArrayOf(
                (len ushr 24).toByte(), (len ushr 16).toByte(),
                (len ushr 8).toByte(), len.toByte()
            )
        )
        out.write(data)
        out.flush()
    }

    override fun recv(): ByteArray {
        val header = readExact(4)
        val len = ((header[0].toInt() and 0xff) shl 24) or ((header[1].toInt() and 0xff) shl 16) or
            ((header[2].toInt() and 0xff) shl 8) or (header[3].toInt() and 0xff)
        return readExact(len)
    }

    private fun readExact(n: Int): ByteArray {
        val buf = ByteArray(n)
        var off = 0
        while (off < n) {
            // Raw unbuffered reads: readNBytes-style buffered reads can
            // block trying to fill the whole buffer on a pipe.
            val read = inp.read(buf, off, n - off)
            if (read < 0) {
                onEof?.invoke()
                throw EOFException("stdio closed")
            }
            off += read
        }
        return buf
    }
}
