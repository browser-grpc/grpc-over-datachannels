"""trace=hooks plugin option, end to end.

Stubs generated with --grpc-dc-python_opt=trace=hooks (plus a
baked trace_methods filter) must re-export the runtime tracer
registrar, and registering an observer through the *stub* must
produce parented client/server spans for a real call.
"""

import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.abspath(os.path.join(HERE, "..")))

import grpcdc  # noqa: E402


class Recorder:
    def __init__(self):
        self.starts = []

    def on_start(self, kind, method, trace_id, span_id, parent_span_id):
        self.starts.append((kind, method, trace_id, span_id, parent_span_id))

    def on_end(self, kind, method, trace_id, span_id, status):
        pass


@unittest.skipUnless(shutil.which("protoc"), "protoc required")
class TestTraceOption(unittest.TestCase):
    def test_hooks_stub_registers_tracer(self):
        plugin = os.path.join(ROOT, "bin", "protoc-gen-grpc-dc-python")
        with tempfile.TemporaryDirectory() as out:
            subprocess.run(
                ["protoc",
                 f"--plugin=protoc-gen-grpc-dc-python={plugin}",
                 "--grpc-dc-python_opt=trace=hooks,trace_methods=/echo.Echo/*",
                 f"--grpc-dc-python_out={out}",
                 "-I", os.path.join(ROOT, "proto"),
                 os.path.join(ROOT, "proto", "echo.proto")],
                check=True, capture_output=True, text=True)
            sys.path.insert(0, out)
            try:
                # Load under a unique name: other suites have
                # already imported the examples' echo_grpc_dc
                # (generated without hooks) into sys.modules.
                import importlib.util
                spec = importlib.util.spec_from_file_location(
                    "echo_grpc_dc_hooks",
                    os.path.join(out, "echo_grpc_dc.py"))
                echo_grpc_dc = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(echo_grpc_dc)
                from echo_pb import EchoRequest, EchoResponse

                self.assertTrue(hasattr(echo_grpc_dc, "set_tracer"))
                self.assertTrue(hasattr(echo_grpc_dc, "set_trace_filter"))

                class Impl:
                    def Unary(self, ctx, req):
                        return EchoResponse(message=f"echo: {req.message}")

                recorder = Recorder()
                echo_grpc_dc.set_tracer(recorder)
                try:
                    a, b = grpcdc.memory_transport_pair()
                    server = grpcdc.Server()
                    echo_grpc_dc.register_echo_server(server, Impl())
                    server.serve_transport(b)
                    client = echo_grpc_dc.EchoClient(grpcdc.Channel(a))
                    reply = client.Unary(EchoRequest(message="hello"))
                    self.assertEqual(reply.message, "echo: hello")
                finally:
                    echo_grpc_dc.set_tracer(None)
                    grpcdc.set_trace_filter("")

                kinds = {s[0]: s for s in recorder.starts}
                self.assertIn("client", kinds)
                self.assertIn("server", kinds)
                self.assertEqual(kinds["client"][2], kinds["server"][2])
                self.assertEqual(kinds["server"][4], kinds["client"][3])
            finally:
                sys.path.remove(out)


if __name__ == "__main__":
    unittest.main()
