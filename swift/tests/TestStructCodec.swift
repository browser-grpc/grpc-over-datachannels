import Foundation

private func SetupStruct(_ clientStruct: Bool, _ serverStruct: Bool) -> EchoGrpcDc.EchoClient {
    let (a, b) = MemoryTransport.Pair()
    let server = Server()
    server.SetStructCodec(serverStruct)
    EchoGrpcDc.RegisterEchoServer(server, EchoServiceImpl())
    server.ServeTransport(b)
    let channel = Channel(a)
    channel.SetStructCodec(clientStruct)
    return EchoGrpcDc.EchoClient(channel)
}

/// Struct-codec negotiation: struct<->struct roundtrip, mismatch rejected, plain still works.
func TestStructCodec() throws {
    let client = SetupStruct(true, true)

    let unary = try client.Unary(EchoRequest("hello", 0))
    try Check(unary.message == "echo: hello", "struct unary: \(unary)")

    let stream = try client.ServerStream(EchoRequest("tick", 3))
    var n = 0
    while true {
        do {
            _ = try stream.Recv()
            n += 1
        } catch is EndOfStreamError {
            break
        }
    }
    try Check(n == 3, "struct server-stream count: \(n)")

    let joined = try client.ClientStream([EchoRequest("a", 0), EchoRequest("b", 0)])
    try Check(joined.message == "a+b", "struct client-stream: \(joined)")

    let bidi = try client.Bidi([EchoRequest("x", 0), EchoRequest("y", 0)])
    var echoed: [String] = []
    while true {
        do {
            echoed.append(try bidi.Recv().message)
        } catch is EndOfStreamError {
            break
        }
    }
    try Check(echoed == ["x", "y"], "struct bidi: \(echoed)")

    let structBytes = try EchoRequest("hello", 0).MarshalStruct()
    try Check(structBytes.count > 4
        && structBytes[0] == 0x44 && structBytes[1] == 0x43
        && structBytes[2] == 0x53 && structBytes[3] == 0x31,
        "struct magic missing")
    let back = EchoRequest()
    try back.UnmarshalStruct(structBytes)
    try Check(back.message == "hello", "struct roundtrip: \(back.message)")

    let mismatch = SetupStruct(true, false)
    do {
        _ = try mismatch.Unary(EchoRequest("hello", 0))
        try Check(false, "struct client vs plain server should fail")
    } catch let e as StatusException {
        try Check(e.code == Wire.CodeUnimplemented, "mismatch status: \(e)")
    }

    let plain = SetupStruct(false, true)
    let plainResp = try plain.Unary(EchoRequest("hello", 0))
    try Check(plainResp.message == "echo: hello", "plain vs struct server: \(plainResp)")

    print("TestStructCodec OK")
}
