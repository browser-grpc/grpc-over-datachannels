import Foundation

#if canImport(Glibc)
import Glibc
#endif

struct TestFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

func Check(_ condition: Bool, _ what: String) throws {
    if !condition {
        throw TestFailure(message: "check failed: \(what)")
    }
}

func FromHex(_ hex: String) -> [UInt8] {
    var out: [UInt8] = []
    var idx = hex.startIndex
    func val(_ c: Character) -> UInt8 {
        switch c {
        case "0"..."9": return UInt8(c.unicodeScalars.first!.value - 48)
        case "a"..."f": return UInt8(c.unicodeScalars.first!.value - 87)
        case "A"..."F": return UInt8(c.unicodeScalars.first!.value - 55)
        default: return 0
        }
    }
    while idx < hex.endIndex {
        let hi = hex[idx]
        idx = hex.index(after: idx)
        if idx >= hex.endIndex { break }
        let lo = hex[idx]
        idx = hex.index(after: idx)
        out.append(val(hi) * 16 + val(lo))
    }
    return out
}

func ToHex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

/// Repository root, located by walking up from the cwd looking for
/// fixtures/echo_descriptor_set.bin.
func Root() -> String {
    if let env = ProcessInfo.processInfo.environment["GRPC_DC_ROOT"], !env.isEmpty {
        return env
    }
    var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    for _ in 0..<8 {
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent("fixtures/echo_descriptor_set.bin").path) {
            return dir.path
        }
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent("grpc-over-datachannels/fixtures/echo_descriptor_set.bin").path) {
            return dir.appendingPathComponent("grpc-over-datachannels").path
        }
        let parent = dir.deletingLastPathComponent()
        if parent.path == dir.path { break }
        dir = parent
    }
    return "."
}

func FileExists(_ path: String) -> Bool {
    FileManager.default.fileExists(atPath: path)
}

func JavaClasspath(_ root: String) -> String? {
    let target = "\(root)/oracle/java/target"
    let cpFile = "\(target)/cp.txt"
    guard FileExists(cpFile), FileExists("\(target)/classes") else { return nil }
    guard let cp = try? String(contentsOfFile: cpFile, encoding: .utf8) else { return nil }
    return "\(target)/classes:" + cp.trimmingCharacters(in: .whitespacesAndNewlines)
}

func FreePort() -> Int {
    let fd = Glibc.socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    if fd < 0 { return 0 }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = Glibc.htonl(0x7f000001)
    addr.sin_port = 0
    var port = 0
    let bindResult = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            Glibc.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    if bindResult == 0 {
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                _ = Glibc.getsockname(fd, sa, &len)
            }
        }
        port = Int(Glibc.ntohs(addr.sin_port))
    }
    Glibc.close(fd)
    return port
}

/// Read one line (without newline) from a raw fd; nil at EOF.
final class LineReader {
    private let fd: Int32
    private var buffer: [UInt8] = []
    private var pos = 0

    init(_ fd: Int32) { self.fd = fd }

    func ReadLine() -> String? {
        var line: [UInt8] = []
        while true {
            if pos >= buffer.count {
                var chunk = [UInt8](repeating: 0, count: 4096)
                let n = chunk.withUnsafeMutableBytes { Glibc.read(fd, $0.baseAddress!, 4096) }
                if n <= 0 {
                    return line.isEmpty ? nil : String(decoding: line, as: UTF8.self)
                }
                buffer = Array(chunk[0..<n])
                pos = 0
            }
            let b = buffer[pos]
            pos += 1
            if b == 0x0a {
                return String(decoding: line, as: UTF8.self)
            }
            line.append(b)
        }
    }

    func ReadAll() -> String {
        var out = String(decoding: buffer[pos...], as: UTF8.self)
        buffer = []
        pos = 0
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = chunk.withUnsafeMutableBytes { Glibc.read(fd, $0.baseAddress!, 4096) }
            if n <= 0 { break }
            out += String(decoding: chunk[0..<n], as: UTF8.self)
        }
        return out
    }
}

/// Spawn a child with piped stdin/stdout/stderr (Foundation Process).
final class Proc {
    let process = Process()
    var stdinPipe = Pipe()
    var stdoutPipe = Pipe()
    var stderrPipe = Pipe()

    init(_ argv: [String], pipeStderr: Bool = true) throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = argv
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        if pipeStderr {
            process.standardError = stderrPipe
        }
        try process.run()
        // Close the parent's unused pipe ends: if the parent keeps the
        // write end of the child's stdout/stderr open, readers never
        // see EOF when the child exits (and ReadAll blocks forever).
        try? stdinPipe.fileHandleForReading.close()
        try? stdoutPipe.fileHandleForWriting.close()
        if pipeStderr {
            try? stderrPipe.fileHandleForWriting.close()
        }
    }

    var stdinFd: Int32 { stdinPipe.fileHandleForWriting.fileDescriptor }
    var stdoutFd: Int32 { stdoutPipe.fileHandleForReading.fileDescriptor }
    var stderrFd: Int32 { stderrPipe.fileHandleForReading.fileDescriptor }

    func Kill() {
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        // Raw waitpid, not Process.waitUntilExit: Foundation's version
        // also waits for the child's output pipes to close, which
        // blocks forever when the child spawned a grandchild (the
        // oracle bridge's target server) holding those pipes. SIGTERM
        // first so the bridge can kill its target; SIGKILL as backup.
        Glibc.kill(pid, SIGTERM)
        var status: Int32 = 0
        var waited = 0
        while waited < 200 {
            let r = Glibc.waitpid(pid, &status, WNOHANG)
            if r == pid || r < 0 { return }
            Thread.sleep(forTimeInterval: 0.01)
            waited += 1
        }
        Glibc.kill(pid, SIGKILL)
        while Glibc.waitpid(pid, &status, 0) < 0, Glibc.errno == EINTR {}
    }

    /// Exit code if the process finishes within the timeout (killed otherwise).
    func WaitForExit(seconds: Double) -> Int {
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            Kill()
            return -1
        }
        return Int(process.terminationStatus)
    }
}
