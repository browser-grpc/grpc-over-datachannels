import Foundation

private func WaitReadyHttp2(_ reader: LineReader, _ needle: String) -> Bool {
    while let line = reader.ReadLine() {
        if line.contains(needle) { return true }
    }
    return false
}

/// HTTP/2 oracle: the generated grpcdc.Http2Transport dials the
/// official grpc-java OracleServer directly over TCP (no bridge).
/// Skips when the oracle is unavailable. Mirrors
/// java/tests/TestHttp2Oracle.java, except the TLS leg: the
/// generated Swift transport has no stdlib TLS on this platform,
/// so that leg reports a clear SKIP (DialTls throws
/// CodeUnimplemented; it never silently dials cleartext).
func TestHttp2Oracle() throws {
    let root = Root()
    guard let cp = JavaClasspath(root) else {
        print("TestHttp2Oracle SKIP (oracle not built)")
        return
    }
    let port = FreePort()
    let server = try Proc(["java", "-cp", cp, "dc.oracle.OracleServer", String(port)])
    defer { server.Kill() }
    guard WaitReadyHttp2(LineReader(server.stderrFd), "READY") else {
        print("TestHttp2Oracle SKIP (oracle server did not start)")
        return
    }
    let transport = try Http2Transport.Dial("127.0.0.1:\(port)")
    defer { transport.Close() }
    let client = EchoGrpcDc.EchoClient(Channel(transport))
    try RunScenarios(client)
    // Echoed initial metadata proves HEADERS metadata made the
    // round trip.
    let md = try client.Unary(EchoRequest("hello", 0), ["x-echo": "mval"])
    try Check(md.message == "echo: hello [mval]", "metadata echo: \(md.message)")
    // 200 responses x 1500-byte payloads: comfortably past
    // several 64KiB flow-control windows, so the call only
    // completes if stream/connection WINDOW_UPDATE accounting
    // replenishes.
    let big = String(repeating: "y", count: 1500)
    let stream = try client.ServerStream(EchoRequest(big, 200))
    var got = 0
    while true {
        do {
            let resp = try stream.Recv()
            try Check(resp.message == big && resp.index == Int32(got), "flow: \(got)")
            got += 1
        } catch is EndOfStreamError {
            break
        }
    }
    try Check(got == 200, "flow: got \(got), want 200")
    transport.Close()
    // gzip codec: the stored-block writer and the full inflate
    // reader (no zlib in the Swift stdlib) round-trip, and the
    // reader decodes a reference deflate stream (dynamic
    // Huffman) produced by zlib at level 9.
    let plain = [UInt8](String(repeating: "grpc-dc gzip roundtrip ", count: 300).utf8)
    let roundtripped = try Http2Transport.Gunzip(Http2Transport.Gzip(plain))
    try Check(roundtripped == plain, "gzip roundtrip")
    let vector = FromHex("1f8b08000000000002ff0bc94855282ccd4cce56482aca2fcf5348cbaf50c82acd2d2856c82f4b2d5228014ae72456552aa4e4a7eb29848c2a1e553caa7854f1a8e251c5c34b31032313330b2b1b3b072717370f2f1fbf80a090b088a898b884a494b48cac9cbc82a292b28aaa9aba86a696b68eae9ebe81a191b189a999b985a595b58dad9dbd83a393b38bab9bbb87a797b78faf9f7f4060507048685878446454744c6c5c7c426252724a6a5a7a466656764e6e5e7e4161517149695979456555754d6d5d7d436353734b6b5b7b476757774f6f5fff848993264f993a6dfa8c99b366cf993b6ffe82858b162f59ba6cf98a95ab56af59bb6efd868d9b366fd9ba6dfb8e9dbb76efd9bb6fff8183870e1f397aecf88993a74e9f397beefc858b972e5fb97aedfa8d9bb76edfb97beffe83878f1e3f79faecf98b97af5ebf79fbeefd878f9f3e7ff9faedfb8f9fbf7efff9fbefffa8ff47b6ffd38b0a927541f9423725b124313923312f2f35a75821bd2ab340a12c35b924bf486154c9a8925125942b0100c40700f9730d0000")
    let inflated = try Http2Transport.Gunzip(vector)
    var expected = [UInt8](String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 40).utf8)
    expected.append(contentsOf: (0..<256).map { UInt8($0) })
    expected.append(contentsOf: (0..<256).map { UInt8($0) })
    expected.append(contentsOf: (0..<256).map { UInt8($0) })
    expected.append(contentsOf: [UInt8](String(repeating: "grpc-over-datachannels gzip vector ", count: 25).utf8))
    try Check(inflated == expected, "gunzip zlib vector: got \(inflated.count) bytes, want \(expected.count)")
    // TLS leg: unavailable in the generated Swift transport.
    print("TestHttp2Oracle TLS SKIP (no stdlib TLS for generated Swift transport)")
    print("TestHttp2Oracle OK")
}
