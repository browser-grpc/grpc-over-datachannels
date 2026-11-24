import Foundation

func buildOuter() -> Outer {
    let m = Outer()
    m.inner = Inner("x", -3)
    m.hue = Hue.RED
    m.nums = [1, -2, 300]
    m.byName = ["b": Inner("second"), "a": Inner("first", 9)]
    m.s = "picked"
    m.blob = [1, 2, 3]
    m.names = ["n1", "n2"]
    m.inners = [Inner("i1"), Inner("i2"), Inner("i3")]
    m.byId = [7: "seven", 2: "two"]
    m.score = 3.5
    m.ratio = 0.25
    m.flag = true
    m.stamp = 123456789
    m.delta = -77
    return m
}

func buildP2() -> P2 {
    let m = P2()
    m.name = "req"
    m.count = 42
    m.greeting = "hi"
    m.enabled = false
    m.ratio = 2.5
    m.nums = [5, -6]
    m.extNote = "note!"
    return m
}

func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

func unhex(_ s: String) -> [UInt8] {
    var out: [UInt8] = []
    var idx = s.startIndex
    while idx < s.endIndex {
        let nxt = s.index(idx, offsetBy: 2)
        out.append(UInt8(s[idx..<nxt], radix: 16)!)
        idx = nxt
    }
    return out
}

let goldenHex = CommandLine.arguments[1]
let golden = unhex(goldenHex)
let got = OuterStruct.Marshal(buildOuter())
if got != golden {
    print("MARSHAL_MISMATCH\n got \(hex(got))\nwant \(goldenHex)")
    exit(1)
}
let back = OuterStruct.Unmarshal(golden)
if OuterStruct.Marshal(back) != golden {
    print("ROUNDTRIP_MISMATCH")
    exit(1)
}
// Proto2 shape (msgs2.proto): explicit defaults, extension.
let golden2Hex = CommandLine.arguments[2]
let golden2 = unhex(golden2Hex)
let got2 = P2Struct.Marshal(buildP2())
if got2 != golden2 {
    print("P2_MARSHAL_MISMATCH\n got \(hex(got2))\nwant \(golden2Hex)")
    exit(1)
}
let back2 = P2Struct.Unmarshal(golden2)
if P2Struct.Marshal(back2) != golden2 {
    print("P2_ROUNDTRIP_MISMATCH")
    exit(1)
}
print("DECODE_OK")
