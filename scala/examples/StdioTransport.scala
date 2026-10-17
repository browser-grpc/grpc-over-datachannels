package echo

import grpcdc.Transport
import java.io.{EOFException, InputStream, OutputStream}

/**
 * Stdio transport: frames DataChannel messages over a byte stream
 * with a 4-byte big-endian length prefix (the prefix exists only to
 * frame messages on stdio; each framed unit is exactly one
 * DataChannel message). Used by the cross-language interop harnesses.
 */
class StdioTransport(private val out: OutputStream, private val inp: InputStream) extends Transport {
  /** Invoked once when the input reaches EOF (stdio harnesses exit on it). */
  var onEof: () => Unit = null

  def send(data: Array[Byte]): Unit = synchronized {
    val len = data.length
    out.write(Array(
      (len >>> 24).toByte, (len >>> 16).toByte,
      (len >>> 8).toByte, len.toByte))
    out.write(data)
    out.flush()
  }

  def recv(): Array[Byte] = {
    val header = readExact(4)
    val len = ((header(0).toInt & 0xff) << 24) | ((header(1).toInt & 0xff) << 16) |
      ((header(2).toInt & 0xff) << 8) | (header(3).toInt & 0xff)
    readExact(len)
  }

  private def readExact(n: Int): Array[Byte] = {
    val buf = new Array[Byte](n)
    var off = 0
    while (off < n) {
      // Raw unbuffered reads: buffered fill reads can block trying
      // to fill the whole buffer on a pipe.
      val read = inp.read(buf, off, n - off)
      if (read < 0) {
        if (onEof != null) onEof()
        throw new EOFException("stdio closed")
      }
      off += read
    }
    buf
  }
}
