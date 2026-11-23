// Struct corpus driver (js): generated struct codec vs Go golden.
import { readFileSync } from "node:fs";
import { Outer, Inner, Hue } from "./msgs_pb.js";
import { P2 } from "./msgs2_pb.js";

const goldenHex = process.argv[2];
const golden = Uint8Array.from(Buffer.from(goldenHex, "hex"));
const hexOf = (b) => Buffer.from(b).toString("hex");

const inner = (v, n = 0) => new Inner({ v, n });
const m = new Outer({
  inner: inner("x", -3),
  hue: Hue.RED,
  nums: [1, -2, 300],
  byName: new Map([["b", inner("second")], ["a", inner("first", 9)]]),
  s: "picked",
  blob: new Uint8Array([1, 2, 3]),
  names: ["n1", "n2"],
  inners: [inner("i1"), inner("i2"), inner("i3")],
  byId: new Map([[7, "seven"], [2, "two"]]),
  score: 3.5,
  ratio: 0.25,
  flag: true,
  stamp: 123456789n,
  delta: -77,
});

const got = Outer.encodeStruct(m);
if (hexOf(got) !== goldenHex) {
  console.log(`MARSHAL_MISMATCH\n got ${hexOf(got)}\nwant ${goldenHex}`);
  process.exit(1);
}
const back = Outer.decodeStruct(golden);
if (hexOf(Outer.encodeStruct(back)) !== goldenHex) {
  console.log("ROUNDTRIP_MISMATCH");
  process.exit(1);
}

// Proto2 shape (msgs2.proto): explicit defaults, unpacked
// repeated, extension field merged as extNote. Decode is into
// the zero value: decodeStruct must not apply proto2 defaults,
// or absent fields (enabled=false) would be manufactured.
const golden2Hex = process.argv[3];
const golden2 = Uint8Array.from(Buffer.from(golden2Hex, "hex"));
const p2 = new P2({
  name: "req",
  count: 42,
  greeting: "hi",
  enabled: false,
  ratio: 2.5,
  nums: [5, -6],
  extNote: "note!",
});
const got2 = P2.encodeStruct(p2);
if (hexOf(got2) !== golden2Hex) {
  console.log(`P2_MARSHAL_MISMATCH\n got ${hexOf(got2)}\nwant ${golden2Hex}`);
  process.exit(1);
}
const back2 = P2.decodeStruct(golden2);
if (hexOf(P2.encodeStruct(back2)) !== golden2Hex) {
  console.log("P2_ROUNDTRIP_MISMATCH");
  process.exit(1);
}
console.log("DECODE_OK");
