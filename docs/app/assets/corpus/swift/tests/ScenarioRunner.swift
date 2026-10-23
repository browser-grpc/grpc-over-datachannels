/// Shared oracle-scenario runner for the typed stub client
/// (TestOracle) and the dynamic client (TestDynamic).
func Unmsg(_ token: String) -> String {
    token == "-" ? "" : token
}

func RunScenarios(_ client: EchoGrpcDc.EchoClient) throws {
    for c in OracleScenarios.Cases {
        let messages = c.messages.map(Unmsg)
        let line = "\(c.kind) \(c.messages.joined(separator: " "))"
        switch c.kind {
        case "UNARY":
            do {
                let resp = try client.Unary(EchoRequest(messages[0], 0))
                try Check(c.expectStatus < 0, "\(line): expected failure, got \(resp)")
                try Check(resp.message == "echo: \(messages[0])" && resp.index == 0, "\(line): \(resp)")
            } catch let e as StatusException {
                try Check(c.expectStatus >= 0 && e.code == c.expectStatus,
                          "\(line): status \(e), want \(c.expectStatus)")
            }
        case "SERVER_STREAM":
            let stream = try client.ServerStream(EchoRequest(messages[0], Int32(c.count)))
            var got = 0
            while true {
                do {
                    let resp = try stream.Recv()
                    try Check(resp.message == messages[0] && resp.index == Int32(got),
                              "\(line): \(resp) at \(got)")
                    got += 1
                } catch is EndOfStreamError {
                    break
                }
            }
            try Check(got == c.count, "\(line): got \(got), want \(c.count)")
        case "CLIENT_STREAM":
            let resp = try client.ClientStream(messages.map { EchoRequest($0, 0) })
            try Check(resp.message == messages.joined(separator: "+") && resp.index == Int32(messages.count),
                      "\(line): \(resp)")
        case "BIDI":
            let stream = try client.Bidi(messages.map { EchoRequest($0, 0) })
            var got = 0
            while true {
                do {
                    let resp = try stream.Recv()
                    try Check(got < messages.count && resp.message == messages[got] && resp.index == Int32(got),
                              "\(line): \(resp) at \(got)")
                    got += 1
                } catch is EndOfStreamError {
                    break
                }
            }
            try Check(got == messages.count, "\(line): got \(got)")
        default:
            throw TestFailure(message: "unknown scenario kind: \(c.kind)")
        }
    }
}

func RunDynamicScenarios(_ client: Dynamic.DynamicClient, _ model: Dynamic.FileModel) throws {
    func Req(_ message: String, _ count: Int64) -> Dynamic.GenericMessage {
        Dynamic.GenericMessage(try! model.Message(".echo.EchoRequest"))
            .Set(1, .string(message)).Set(2, .int64(count))
    }
    func Reqs(_ messages: [String]) -> [Dynamic.GenericMessage] {
        messages.map { Req($0, 0) }
    }
    let service = "echo.Echo"
    for c in OracleScenarios.Cases {
        let messages = c.messages.map(Unmsg)
        let line = "\(c.kind) \(c.messages.joined(separator: " "))"
        switch c.kind {
        case "UNARY":
            do {
                let resp = try client.Unary(service, "Unary", Req(messages[0], 0))
                try Check(c.expectStatus < 0, "\(line): expected failure, got \(resp.values)")
                try Check(resp.GetString(1) == "echo: \(messages[0])" && resp.GetInt(2) == 0,
                          "\(line): \(resp.values)")
            } catch let e as StatusException {
                try Check(c.expectStatus >= 0 && e.code == c.expectStatus,
                          "\(line): status \(e), want \(c.expectStatus)")
            }
        case "SERVER_STREAM":
            let stream = try client.ServerStream(service, "ServerStream", Req(messages[0], Int64(c.count)))
            var got: Int64 = 0
            while true {
                do {
                    let resp = try stream.Recv()
                    try Check(resp.GetString(1) == messages[0] && resp.GetInt(2) == got,
                              "\(line): at \(got)")
                    got += 1
                } catch is EndOfStreamError {
                    break
                }
            }
            try Check(got == Int64(c.count), "\(line): got \(got), want \(c.count)")
        case "CLIENT_STREAM":
            let resp = try client.ClientStream(service, "ClientStream", Reqs(messages))
            try Check(resp.GetString(1) == messages.joined(separator: "+") && resp.GetInt(2) == Int64(messages.count),
                      "\(line): \(resp.values)")
        case "BIDI":
            let stream = try client.Bidi(service, "Bidi", Reqs(messages))
            var got: Int64 = 0
            while true {
                do {
                    let resp = try stream.Recv()
                    try Check(got < Int64(messages.count) && resp.GetString(1) == messages[Int(got)] && resp.GetInt(2) == got,
                              "\(line): at \(got)")
                    got += 1
                } catch is EndOfStreamError {
                    break
                }
            }
            try Check(got == Int64(messages.count), "\(line): got \(got)")
        default:
            throw TestFailure(message: "unknown scenario kind: \(c.kind)")
        }
    }
}
