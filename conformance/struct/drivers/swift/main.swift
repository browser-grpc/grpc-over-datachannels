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

func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

let goldenHex = CommandLine.arguments[1]
var golden: [UInt8] = []
var idx = goldenHex.startIndex
while idx < goldenHex.endIndex {
    let nxt = goldenHex.index(idx, offsetBy: 2)
    golden.append(UInt8(goldenHex[idx..<nxt], radix: 16)!)
    idx = nxt
}
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
print("DECODE_OK")
