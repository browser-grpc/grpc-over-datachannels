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

    def test_oneof_encode_clearing(self):
        # With both oneof variants set, only the last in field
        # order is written (matching decode's last-one-wins).
        kp = self.kitchen_pb
        both = kp.Kitchen(text="a", code=7)
        back = kp.Kitchen()
        back.unmarshal_dc(both.marshal_dc())
        self.assertEqual(back.text, "")
        self.assertEqual(back.code, 7)

    def test_cross_file_map_entry_from_crafted_descriptor(self):
        # protoc will not produce this from .proto source (a map
        # entry always lives with its map field), but descriptor
        # sets from other toolchains can reference an entry from
        # another file. The generator must emit the entry helpers
        # in the using file.
        include = None
        for cand in (
            os.path.expanduser("~/.local/protoc/include"),
            "/usr/local/include",
            "/usr/include",
        ):
            if os.path.exists(os.path.join(cand, "google/protobuf/compiler/plugin.proto")):
                include = cand
                break
        if include is None:
            self.skipTest("plugin.proto include not available")
        request_text = """
file_to_generate: "uses.proto"
proto_file {
  name: "base.proto"
  package: "x"
  message_type {
    name: "Shared"
    field { name: "name" number: 1 label: LABEL_OPTIONAL type: TYPE_STRING json_name: "name" }
    nested_type {
      name: "CountsEntry"
      field { name: "key" number: 1 label: LABEL_OPTIONAL type: TYPE_STRING json_name: "key" }
      field { name: "value" number: 2 label: LABEL_OPTIONAL type: TYPE_INT32 json_name: "value" }
      options { map_entry: true }
    }
  }
  syntax: "proto3"
}
proto_file {
  name: "uses.proto"
  package: "x"
  dependency: "base.proto"
  message_type {
    name: "Uses"
    field { name: "counts" number: 1 label: LABEL_REPEATED type: TYPE_MESSAGE
            type_name: ".x.Shared.CountsEntry" json_name: "counts" }
  }
  syntax: "proto3"
}
"""
        req = _protoc(
            f"-I{include}",
            "--encode=google.protobuf.compiler.CodeGeneratorRequest",
            "google/protobuf/compiler/plugin.proto",
            input=request_text.encode(), capture_output=True,
        ).stdout
        plugin = os.path.join(ROOT, "bin", "protoc-gen-grpc-dc-python")
        resp = subprocess.run([plugin], input=req, capture_output=True, check=True).stdout
        def fields(buf):
            pos = 0

            def varint():
                nonlocal pos
                result = shift = 0
                while True:
                    b = buf[pos]
                    pos += 1
                    result |= (b & 0x7F) << shift
                    if not (b & 0x80):
                        return result
                    shift += 7

            while pos < len(buf):
                tag = varint()
                num, wire = tag >> 3, tag & 7
                if wire == 0:
                    yield num, varint()
                elif wire == 2:
                    n = varint()
                    yield num, buf[pos:pos + n]
                    pos += n
                elif wire == 1:
                    yield num, buf[pos:pos + 8]
                    pos += 8
                elif wire == 5:
                    yield num, buf[pos:pos + 4]
                    pos += 4
                else:
                    raise AssertionError(f"bad wire {wire}")

        out = tempfile.mkdtemp()
        for num, val in fields(resp):
            self.assertNotEqual(num, 1, "plugin reported an error")
            if num == 15:
                name = content = None
                for n2, v2 in fields(val):
                    if n2 == 1:
                        name = v2.decode()
                    if n2 == 15:
                        content = v2
                if name and name.endswith("_pb.py"):
                    with open(os.path.join(out, name), "wb") as fh:
                        fh.write(content)
        # base_pb from a legal schema (the crafted Uses only needs
        # the module to exist for its import).
        with tempfile.TemporaryDirectory() as td:
            with open(os.path.join(td, "base.proto"), "w") as fh:
                fh.write('syntax = "proto3";\npackage x;\nmessage Shared { string name = 1; }\n')
            _protoc(
                f"--plugin=protoc-gen-grpc-dc-python={plugin}",
                f"--grpc-dc-python_out={out}",
                "-I", td, "base.proto", cwd=td,
            )

        # Go dedupe: when base.proto is generated too AND its
        # Shared message uses the entry as a map field, the Go
        # helpers (package-level) must come from base_pb.go only;
        # uses_pb.go must not re-emit them.
        both_text = request_text.replace(
            'file_to_generate: "uses.proto"',
            'file_to_generate: "base.proto"\nfile_to_generate: "uses.proto"',
        ).replace(
            '    field { name: "name" number: 1 label: LABEL_OPTIONAL type: TYPE_STRING json_name: "name" }',
            '    field { name: "name" number: 1 label: LABEL_OPTIONAL type: TYPE_STRING json_name: "name" }\n'
            '    field { name: "counts" number: 2 label: LABEL_REPEATED type: TYPE_MESSAGE type_name: ".x.Shared.CountsEntry" json_name: "counts" }',
        )
        both_req = _protoc(
            f"-I{include}",
            "--encode=google.protobuf.compiler.CodeGeneratorRequest",
            "google/protobuf/compiler/plugin.proto",
            input=both_text.encode(), capture_output=True,
        ).stdout
        go_resp = subprocess.run(
            [os.path.join(ROOT, "bin", "protoc-gen-grpc-dc-go")],
            input=both_req, capture_output=True, check=True,
        ).stdout
        go_files = {}
        for num, val in fields(go_resp):
            self.assertNotEqual(num, 1, "go plugin reported an error")
            if num == 15:
                name = content = None
                for n2, v2 in fields(val):
                    if n2 == 1:
                        name = v2.decode()
                    if n2 == 15:
                        content = v2.decode()
                go_files[name] = content
        self.assertIn("func encodeShared_CountsEntry", go_files["base_pb.go"])
        self.assertNotIn("func encodeShared_CountsEntry", go_files["uses_pb.go"])


        sys.path.insert(0, out)
        try:
            import uses_pb

            u = uses_pb.Uses(counts={"a": 1, "b": -2})
            back = uses_pb.Uses()
            back.unmarshal_dc(u.marshal_dc())
            self.assertEqual(back.counts, {"a": 1, "b": -2})
        finally:
            sys.path.remove(out)

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
