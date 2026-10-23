"""BDD schema scenarios: golden protoc bytes, generated classes.

The scenario table (tests/bdd_schemas_generated.py) is stamped
from the schema scenarios: protoc's own --encode output over
webapp/testdata/{kitchen,features}.proto. Each case decodes the
bytes with the generated classes and re-encodes; the result
must be byte-identical to the expected bytes.
"""

import os
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(__file__))

from bdd_schemas_generated import SCHEMAS

ROOT = os.path.join(os.path.dirname(__file__), "..", "..")
TESTDATA = os.path.join(ROOT, "webapp", "testdata")


class TestBddSchemas(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if subprocess.run(["which", "protoc"], capture_output=True).returncode != 0:
            raise unittest.SkipTest("protoc not available")
        cls.tmp = tempfile.mkdtemp()
        plugin = os.path.join(ROOT, "bin", "protoc-gen-grpc-dc-python")
        subprocess.run(
            [
                "protoc",
                f"--plugin=protoc-gen-grpc-dc-python={plugin}",
                f"--grpc-dc-python_out={cls.tmp}",
                "-I", TESTDATA, "common.proto", "kitchen.proto", "features.proto",
            ],
            check=True,
            cwd=TESTDATA,
        )
        sys.path.insert(0, cls.tmp)
        import features_pb
        import kitchen_pb

        cls.classes = {"kitchen": kitchen_pb.Kitchen, "outer": features_pb.Outer}

    def test_schemas(self):
        for name, message, input_hex, expect_hex in SCHEMAS:
            with self.subTest(name=name):
                cls = self.classes[message]
                decoded = cls()
                decoded.unmarshal_dc(bytes.fromhex(input_hex))
                self.assertEqual(decoded.marshal_dc().hex(), expect_hex)


if __name__ == "__main__":
    unittest.main()
