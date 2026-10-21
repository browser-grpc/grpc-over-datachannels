import Foundation

/// BDD schema scenarios: golden protoc bytes, generated classes.
/// The case table (BDD_SCHEMAS in BddSchemas.swift, stamped from
/// racket/bdd-schemas.rkt) carries protoc's own --encode output
/// over webapp/testdata/{kitchen,features}.proto. Each case
/// decodes with the generated classes and re-encodes
/// byte-identically. The generated-classes harness mirrors
/// TestPbMessages.
func TestBddSchemas() throws {
    func fail(_ msg: String) -> Never {
        FileHandle.standardError.write("FAIL: \(msg)\n".data(using: .utf8)!)
        exit(1)
    }

    let rows = BDD_SCHEMAS.map { c in
        "    BddSchemaCase(name: \(String(reflecting: c.name)), message: \(String(reflecting: c.message)), input: \(String(reflecting: c.input)), expect: \(String(reflecting: c.expect))),"
    }.joined(separator: "\n")

    let harness = """
        import Foundation

        struct BddSchemaCase {
            let name: String
            let message: String
            let input: String
            let expect: String
        }

        func fail(_ msg: String) -> Never {
            FileHandle.standardError.write("FAIL: \\(msg)\\n".data(using: .utf8)!)
            exit(1)
        }

        func unhex(_ s: String) -> [UInt8] {
            var out = [UInt8]()
            var i = s.startIndex
            while i < s.endIndex {
                let j = s.index(i, offsetBy: 2)
                guard let b = UInt8(s[i..<j], radix: 16) else { fail("bad hex") }
                out.append(b)
                i = j
            }
            return out
        }

        func hex(_ bytes: [UInt8]) -> String {
            bytes.map { String(format: "%02x", $0) }.joined()
        }

        let cases: [BddSchemaCase] = [
        \(rows)
        ]

        for c in cases {
            let input = unhex(c.input)
            var got: [UInt8]
            switch c.message {
            case "kitchen":
                let m = Kitchen()
                m.UnmarshalDc(input)
                got = m.MarshalDc()
            case "outer":
                let m = Outer()
                m.UnmarshalDc(input)
                got = m.MarshalDc()
            default:
                fail("unknown message " + c.message)
            }
            if hex(got) != c.expect { fail("re-encode mismatch: " + c.name) }
        }
        print("schemas OK")
        """

    func run(_ args: [String], cwd: String) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = args
        proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = outPipe
        try proc.run()
        proc.waitUntilExit()
        let out = String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        try Check(proc.terminationStatus == 0 && !out.contains("FAIL"),
                  "command failed \(args): \(out)")
        return out
    }

    var root = ".."
    if !FileManager.default.fileExists(atPath: root + "/webapp/testdata/kitchen.proto") {
        root = "."
    }
    root = URL(fileURLWithPath: root).standardizedFileURL.path
    let testdata = root + "/webapp/testdata"
    let tmp = NSTemporaryDirectory() + "grpcdc-swift-schemas-" + UUID().uuidString
    let gen = tmp + "/gen"
    try FileManager.default.createDirectory(atPath: gen, withIntermediateDirectories: true)
    _ = try run(["protoc",
                 "--plugin=protoc-gen-grpc-dc-swift=" + root + "/bin/protoc-gen-grpc-dc-swift",
                 "--grpc-dc-swift_out=" + gen,
                 "-I", testdata, "common.proto", "kitchen.proto", "features.proto"], cwd: testdata)
    try FileManager.default.removeItem(atPath: gen + "/CommonGrpcDc.swift")
    try FileManager.default.removeItem(atPath: gen + "/KitchenGrpcDc.swift")
    try FileManager.default.removeItem(atPath: gen + "/FeaturesGrpcDc.swift")
    try harness.write(toFile: gen + "/main.swift", atomically: true, encoding: .utf8)
    let grpcdc = try FileManager.default.contentsOfDirectory(atPath: root + "/swift/grpcdc")
        .filter { $0.hasSuffix(".swift") }.map { root + "/swift/grpcdc/" + $0 }
    _ = try run(["swiftc", "-swift-version", "5", "-o", tmp + "/harness"]
        + grpcdc + [gen + "/CommonMessages.swift", gen + "/KitchenMessages.swift", gen + "/FeaturesMessages.swift", gen + "/main.swift"],
                cwd: tmp)
    let out = try run([tmp + "/harness"], cwd: tmp)
    try Check(out.contains("schemas OK"), "schemas: " + out)
    print("TestBddSchemas OK")
}
