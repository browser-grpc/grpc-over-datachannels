// Struct corpus driver (js): generated struct codec vs Go golden.
import { readFileSync } from "node:fs";
import { Outer, Inner, Hue } from "./msgs_pb.js";

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
console.log("DECODE_OK");
