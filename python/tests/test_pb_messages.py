"""Generated Python message classes (<base>_pb.py): kitchen-sink
round-trip plus a protoc oracle — protoc's own --encode bytes must
decode to the same message and re-encode byte-identically."""

import os
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.join(os.path.dirname(__file__), "..", "..")
TESTDATA = os.path.join(ROOT, "webapp", "testdata")

KITCHEN_TEXT = """
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


def _protoc(*args, **kwargs):
    return subprocess.run(["protoc", *args], check=True, **kwargs)


class TestGeneratedMessages(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        protoc = subprocess.run(["which", "protoc"], capture_output=True)
        if protoc.returncode != 0:
            raise unittest.SkipTest("protoc not available")
        cls.tmp = tempfile.mkdtemp()
        plugin = os.path.join(ROOT, "bin", "protoc-gen-grpc-dc-python")
        _protoc(
            f"--plugin=protoc-gen-grpc-dc-python={plugin}",
            f"--grpc-dc-python_out={cls.tmp}",
            "-I", TESTDATA, "common.proto", "kitchen.proto",
            cwd=TESTDATA,
        )
        sys.path.insert(0, cls.tmp)
        import common_pb
        import kitchen_pb
        cls.common_pb = common_pb
        cls.kitchen_pb = kitchen_pb

    def _kitchen(self):
        kp, cp = self.kitchen_pb, self.common_pb
        return kp.Kitchen(
            d=1.5, f=2.5, i32=-3, i64=-4, u32=5, u64=6, s32=-7, s64=-8,
            f32=9, f64=10, sf32=-11, sf64=-12, flag=True, name="sink",
            blob=b"\x01\x02\x03", color=kp.Color.GREEN,
            nested=kp.Nested(note="n", level=3),
            item=cp.Item(sku="abc", quantity=2),
            nums=[1, -2, 300], words=["a", "", "bc"],
            manys=[kp.Nested(note="m", level=1)], vals=[0.5, -1.25],
            counts={"x": 1, "y": -2}, by_id={7: kp.Nested(note="z", level=9)},
            text="chosen", big_negative=-9007199254740993, neg32=-123456,
        )

    def test_round_trip(self):
        k = self._kitchen()
        back = self.kitchen_pb.Kitchen()
        back.unmarshal_dc(k.marshal_dc())
        self.assertEqual(back, k)
        self.assertEqual(self.kitchen_pb.Kitchen().marshal_dc(), b"")

    def test_protoc_oracle(self):
        out = _protoc(
            "--encode=kitchen.v1.Kitchen", "-I", TESTDATA, "kitchen.proto",
            input=KITCHEN_TEXT.encode(), capture_output=True, cwd=TESTDATA,
        ).stdout
        from_protoc = self.kitchen_pb.Kitchen()
        from_protoc.unmarshal_dc(out)
        self.assertEqual(from_protoc, self._kitchen())
        self.assertEqual(from_protoc.marshal_dc(), out)


if __name__ == "__main__":
    unittest.main()
