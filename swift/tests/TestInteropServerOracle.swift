import Foundation

#if canImport(Glibc)
import Glibc
#endif

private let interopBCases = [
    "empty_unary",
    "large_unary",
    "client_streaming",
    "server_streaming",
    "ping_pong",
    "empty_stream",
    "custom_metadata",
    "status_code_and_message",
    "special_status_message",
    "unimplemented_method",
    "unimplemented_service",
    "cancel_after_begin",
    "cancel_after_first_response",
    "timeout_on_sleeping_server",
]

private let interopBJavaOnly = [
    "cacheable_unary",
    "client_compressed_unary",
    "client_compressed_streaming",
    "server_compressed_unary",
    "server_compressed_streaming",
]

private let interopBGoOnly = ["orca_per_rpc", "orca_oob"]

private func WaitListening(_ reader: LineReader, _ needle: String) -> Bool {
    while let line = reader.ReadLine() {
        if line.contains(needle) { return true }
    }
    return false
}

private func RunClient(_ argv: [String]) throws -> String {
    let proc = try Proc(argv, pipeStderr: true)
    let out = DrainText()
    let t1 = Thread { out.Set(ReadAllFd(proc.stdoutFd)) }
    let t2 = Thread { out.Append(ReadAllFd(proc.stderrFd)) }
    t1.start()
    t2.start()
    let code = proc.WaitForExit(seconds: 120)
    if code == -1 {
        throw TestFailure(message: "client timed out: \(argv)")
    }
    out.Wait()
    let text = out.Get()
    try Check(code == 0, "client exit \(code): \(argv)\n\(text)")
    return text
}

private final class DrainText {
    private var text = ""
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    func Set(_ s: String) { lock.lock(); text = s; lock.unlock(); done.signal() }
    func Append(_ s: String) { lock.lock(); text += s; lock.unlock(); done.signal() }
    func Get() -> String { lock.lock(); defer { lock.unlock() }; return text }
    func Wait() { done.wait(); done.wait() }
}

private func ReadAllFd(_ fd: Int32) -> String {
    var out: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: 8192)
    while true {
        let n = chunk.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return Glibc.read(fd, base, 8192)
        }
        if n <= 0 { break }
        out.append(contentsOf: chunk[0..<n])
    }
    return String(decoding: out, as: UTF8.self)
}

/// Interop oracle, Direction B: the OFFICIAL interop clients
/// (grpc-java TestServiceClient, grpc-go interop-client) run the
/// canonical cases against the generated Swift TestService
/// server (examples/InteropServerStdio), reached over HTTP/2
/// through oracle/bridge.mjs http2-to-dc. Skips when an oracle
/// binary or Node is unavailable. Mirrors
/// java/tests/TestInteropServerOracle.java.
func TestInteropServerOracle() throws {
    let root = Root()
    guard let cp = JavaClasspath(root) else {
        print("TestInteropServerOracle SKIP (oracle not built)")
        return
    }
    let serverBin = "\(root)/swift/build/interop_server_stdio"
    guard FileExists(serverBin) else {
        print("TestInteropServerOracle SKIP (swift server not built)")
        return
    }
    let port = FreePort()
    let bridge = try Proc(["node", "\(root)/oracle/bridge.mjs", "http2-to-dc",
                           "--port", String(port), "--target-cmd", serverBin])
    defer { bridge.Kill() }
    guard WaitListening(LineReader(bridge.stderrFd), "listening") else {
        print("TestInteropServerOracle SKIP (bridge did not start)")
        return
    }
    for testCase in interopBCases + interopBJavaOnly {
        let out = try RunClient([
            "java", "-cp", cp, "io.grpc.testing.integration.TestServiceClient",
            "--server_host=127.0.0.1", "--server_port=\(port)",
            "--test_case=\(testCase)", "--use_tls=false",
        ])
        try Check(out.contains("Test completed."), "java case \(testCase): unexpected output: \(out)")
        print("interop B case ok: \(testCase) (java client)")
    }
    let goClient = "\(root)/oracle/go-interop/interop-client"
    if !FileExists(goClient) {
        print("TestInteropServerOracle GO SKIP (go client not built)")
    } else {
        for testCase in interopBCases + interopBGoOnly {
            var argv = [
                goClient,
                "-server_host", "127.0.0.1",
                "-server_port", String(port),
                "-test_case", testCase,
            ]
            if testCase.hasPrefix("orca") {
                argv.append("-service_config_json")
                argv.append("{ \"loadBalancingConfig\": [{ \"test_backend_metrics_load_balancer\": {} }]}")
            }
            _ = try RunClient(argv)
            print("interop B case ok: \(testCase) (go client)")
        }
    }
    bridge.Kill()
    print("TestInteropServerOracle OK")
}
