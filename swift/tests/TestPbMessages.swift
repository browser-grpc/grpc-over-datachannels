import Foundation

/// Generated Swift message types (<Base>Messages.swift) from the
/// native protoc-gen-grpc-dc-swift plugin: kitchen-sink round-trip
/// plus a protoc oracle — protoc's own --encode bytes must decode
/// to the same message and re-encode semantically identically.
func TestPbMessages() throws {
    let kitchenText = """
        d: 1.5 f: 2.5 i32: -3 i64: -4 u32: 5 u64: 6 s32: -7 s64: -8
        f32: 9 f64: 10 sf32: -11 sf64: -12 flag: true name: "sink"
        blob: "\\x01\\x02\\x03" color: GREEN
        nested { note: "n" level: 3 }
        item { sku: "abc" quantity: 2 }
        nums: [1, -2, 300] words: ["a", "", "bc"]
        manys { note: "m" level: 1 }
        vals: [0.5, -1.25]
        counts { key: "x" value: 1 } counts { key: "y" value: -2 }
        by_id { key: 7 value { note: "z" level: 9 } }
        text: "chosen" big_negative: -9007199254740993 neg32: -123456
        """

    let harness = """
        import Foundation

        func fail(_ msg: String) -> Never {
            FileHandle.standardError.write("FAIL: \\(msg)\\n".data(using: .utf8)!)
            exit(1)
        }

        func make() -> Kitchen {
            let k = Kitchen()
            k.d = 1.5; k.f = 2.5; k.i32 = -3; k.i64 = -4; k.u32 = 5; k.u64 = 6
            k.s32 = -7; k.s64 = -8; k.f32 = 9; k.f64 = 10; k.sf32 = -11; k.sf64 = -12
            k.flag = true; k.name = "sink"; k.blob = [1, 2, 3]; k.color = Color.GREEN
            let nested = Nested(); nested.note = "n"; nested.level = 3
            k.nested = nested
            let item = Item(); item.sku = "abc"; item.quantity = 2
            k.item = item
            k.nums = [1, -2, 300]
            k.words = ["a", "", "bc"]
            let m = Nested(); m.note = "m"; m.level = 1
            k.manys = [m]
            k.vals = [0.5, -1.25]
            k.counts = ["x": 1, "y": -2]
            let z = Nested(); z.note = "z"; z.level = 9
            k.byId = [7: z]
            k.text = "chosen"; k.bigNegative = -9007199254740993; k.neg32 = -123456
            return k
        }

        func checkSame(_ a: Kitchen, _ b: Kitchen) {
            let ok = a.d == b.d && a.f == b.f && a.i32 == b.i32 && a.i64 == b.i64
                && a.u32 == b.u32 && a.u64 == b.u64 && a.s32 == b.s32 && a.s64 == b.s64
                && a.f32 == b.f32 && a.f64 == b.f64 && a.sf32 == b.sf32 && a.sf64 == b.sf64
                && a.flag == b.flag && a.name == b.name && a.blob == b.blob && a.color == b.color
                && a.nested?.note == b.nested?.note && a.nested?.level == b.nested?.level
                && a.item?.sku == b.item?.sku && a.item?.quantity == b.item?.quantity
                && a.nums == b.nums && a.words == b.words
                && a.manys.count == b.manys.count && a.manys[0].note == b.manys[0].note
                && a.vals == b.vals && a.counts == b.counts
                && a.byId[7]?.note == b.byId[7]?.note
                && a.text == b.text && a.bigNegative == b.bigNegative && a.neg32 == b.neg32
            if !ok { fail("mismatch") }
        }

        let args = CommandLine.arguments
        let k = make()
        if args[1] == "roundtrip" {
            let back = Kitchen()
            back.UnmarshalDc(k.MarshalDc())
            checkSame(back, k)
            if !Kitchen().MarshalDc().isEmpty { fail("empty must encode empty") }
            let both = Kitchen()
            both.text = "a"; both.code = 7
            let bothBack = Kitchen()
            bothBack.UnmarshalDc(both.MarshalDc())
            if bothBack.text != "" || bothBack.code != 7 { fail("oneof encode clearing") }
            print("roundtrip OK")
        } else {
            let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: args[2])))
            let from = Kitchen()
            from.UnmarshalDc(bytes)
            checkSame(from, k)
            let again = Kitchen()
            again.UnmarshalDc(from.MarshalDc())
            checkSame(again, from)
            print("oracle OK")
        }
        """

    func run(_ args: [String], cwd: String, stdin: String? = nil) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = args
        proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = outPipe
        var inPipe: Pipe?
        if stdin != nil {
            inPipe = Pipe()
            proc.standardInput = inPipe
        }
        try proc.run()
        if let stdin, let inPipe {
            inPipe.fileHandleForWriting.write(stdin.data(using: .utf8)!)
            try inPipe.fileHandleForWriting.close()
        }
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
    let tmp = NSTemporaryDirectory() + "grpcdc-swift-pb-" + UUID().uuidString
    let gen = tmp + "/gen"
    try FileManager.default.createDirectory(atPath: gen, withIntermediateDirectories: true)
    _ = try run(["protoc",
                 "--plugin=protoc-gen-grpc-dc-swift=" + root + "/bin/protoc-gen-grpc-dc-swift",
                 "--grpc-dc-swift_out=" + gen,
                 "-I", testdata, "common.proto", "kitchen.proto"], cwd: testdata)
    try FileManager.default.removeItem(atPath: gen + "/CommonGrpcDc.swift")
    try FileManager.default.removeItem(atPath: gen + "/KitchenGrpcDc.swift")
    try harness.write(toFile: gen + "/main.swift", atomically: true, encoding: .utf8)
    let grpcdc = try FileManager.default.contentsOfDirectory(atPath: root + "/swift/grpcdc")
        .filter { $0.hasSuffix(".swift") }.map { root + "/swift/grpcdc/" + $0 }
    _ = try run(["swiftc", "-swift-version", "5", "-o", tmp + "/harness"]
        + grpcdc + [gen + "/CommonMessages.swift", gen + "/KitchenMessages.swift", gen + "/main.swift"],
                cwd: tmp)
    let out1 = try run([tmp + "/harness", "roundtrip"], cwd: tmp)
    try Check(out1.contains("roundtrip OK"), "roundtrip: " + out1)
    let bin = tmp + "/protoc.bin"
    // protoc oracle bytes via a shell pipe through a temp stdin file.
    try kitchenText.write(toFile: tmp + "/kitchen.txt", atomically: true, encoding: .utf8)
    _ = try run(["bash", "-c", "protoc --encode=kitchen.v1.Kitchen -I " + testdata
                 + " kitchen.proto < " + tmp + "/kitchen.txt > " + bin], cwd: testdata)
    let out2 = try run([tmp + "/harness", "oracle", bin], cwd: tmp)
    try Check(out2.contains("oracle OK"), "oracle: " + out2)
    print("TestPbMessages OK")
}
