"""Stdio transport: frames DataChannel messages over a byte stream
with a 4-byte big-endian length prefix (the prefix exists only to
frame messages on stdio; each framed unit is exactly one DataChannel
message). Used by the cross-language interop harnesses.
Mirrors go/examples/stdio.go.
"""

import struct
import threading

import grpcdc


class StdioTransport(grpcdc.Transport):
    def __init__(self, writer, reader):
        self._writer = writer  # binary writable (e.g. sys.stdout.buffer)
        self._reader = reader  # binary readable (e.g. sys.stdin.buffer)
        self._lock = threading.Lock()
        # Set to exit the process when the driver goes away.
        self.on_eof = None

    def send(self, data):
        with self._lock:
            self._writer.write(struct.pack(">I", len(data)))
            self._writer.write(data)
            self._writer.flush()

    def recv(self):
        header = self._read_exact(4)
        if len(header) < 4:
            self._eof()
            raise EOFError("stdio closed")
        (length,) = struct.unpack(">I", header)
        payload = self._read_exact(length)
        if len(payload) < length:
            self._eof()
            raise EOFError("stdio closed mid-frame")
        return payload

    def _read_exact(self, n):
        chunks = []
        remaining = n
        while remaining > 0:
            chunk = self._reader.read(remaining)
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        return b"".join(chunks)

    def _eof(self):
        if self.on_eof is not None:
            self.on_eof()
