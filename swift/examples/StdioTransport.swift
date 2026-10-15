import Foundation

#if canImport(Glibc)
import Glibc
#endif

/// Stdio transport: frames DataChannel messages over a byte stream
/// with a 4-byte big-endian length prefix (the prefix exists only to
/// frame messages on stdio; each framed unit is exactly one
/// DataChannel message). Used by the cross-language interop harnesses.
/// Raw POSIX fds (not FileHandle stdio) so reads return as soon as a
/// frame arrives instead of waiting to fill a buffer.
final class StdioTransport: Transport {
    private let writerFd: Int32
    private let readerFd: Int32
    private let lock = NSLock()

    init(writerFd: Int32, readerFd: Int32) {
        self.writerFd = writerFd
        self.readerFd = readerFd
    }

    func Send(_ data: [UInt8]) throws {
        lock.lock()
        defer { lock.unlock() }
        var header = [UInt8](repeating: 0, count: 4)
        let len = UInt32(data.count)
        header[0] = UInt8((len >> 24) & 0xff)
        header[1] = UInt8((len >> 16) & 0xff)
        header[2] = UInt8((len >> 8) & 0xff)
        header[3] = UInt8(len & 0xff)
        try WriteAll(header)
        try WriteAll(data)
    }

    func Recv() throws -> [UInt8] {
        var header = [UInt8](repeating: 0, count: 4)
        try ReadExact(&header, 4)
        let len = (Int(header[0]) << 24) | (Int(header[1]) << 16) | (Int(header[2]) << 8) | Int(header[3])
        var payload = [UInt8](repeating: 0, count: len)
        if len > 0 {
            try ReadExact(&payload, len)
        }
        return payload
    }

    private func WriteAll(_ bytes: [UInt8]) throws {
        var written = 0
        while written < bytes.count {
            let n = bytes.withUnsafeBytes { ptr -> Int in
                Glibc.write(writerFd, ptr.baseAddress! + written, bytes.count - written)
            }
            if n <= 0 { throw EndOfStreamError() }
            written += n
        }
    }

    private func ReadExact(_ out: inout [UInt8], _ count: Int) throws {
        var read = 0
        while read < count {
            let n = out.withUnsafeMutableBytes { ptr -> Int in
                Glibc.read(readerFd, ptr.baseAddress! + read, count - read)
            }
            if n <= 0 { throw EndOfStreamError() }
            read += n
        }
    }
}
