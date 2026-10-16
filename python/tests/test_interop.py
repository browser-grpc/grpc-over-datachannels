"""Interop: Python runtime against the Go stdio harnesses (cross-
language wire compatibility). Skips when Go is unavailable.
Mirrors go/interop_test.go.
"""

import os
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "examples"))

import grpcdc
import echo_grpc_dc
from echo_pb import EchoRequest
from stdio import StdioTransport


def kill_and_wait(proc):
    """addCleanup target: kill, reap, and close pipes so the
    interpreter does not report still-running subprocesses or
    unclosed pipe files at shutdown."""
    try:
        proc.kill()
    except Exception:
        pass
    try:
        proc.wait(timeout=10)
    except Exception:
        pass
    for stream in (proc.stdin, proc.stdout, proc.stderr):
        try:
            if stream is not None:
                stream.close()
        except Exception:
            pass



ROOT = os.path.join(os.path.dirname(__file__), "..", "..")
GO_DIR = os.path.join(ROOT, "go")
PY_DIR = os.path.join(ROOT, "python")


def build_go(test, out, pkg):
    if shutil.which("go") is None:
        test.skipTest("go not available")
    result = subprocess.run(
        ["go", "build", "-o", out, pkg],
        cwd=GO_DIR,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        test.skipTest(f"go build {pkg}: {result.stderr}")


class TestInterop(unittest.TestCase):
    def test_python_client_calls_go_server(self):
        with tempfile.TemporaryDirectory() as tmp:
            server_bin = os.path.join(tmp, "echo_server_stdio")
            build_go(self, server_bin, "./examples/echo_server_stdio")
            server = subprocess.Popen(
                [server_bin], stdin=subprocess.PIPE, stdout=subprocess.PIPE
            )
            self.addCleanup(kill_and_wait, server)
            transport = StdioTransport(server.stdin, server.stdout)
            client = echo_grpc_dc.EchoClient(grpcdc.Channel(transport))

            unary = client.Unary(EchoRequest(message="hello"))
            self.assertEqual(unary.message, "echo: hello")

            ticks = list(client.ServerStream(EchoRequest(message="tick", count=3)))
            self.assertEqual([r.index for r in ticks], [0, 1, 2])

            joined = client.ClientStream(
                [EchoRequest(message=m) for m in "abc"]
            )
            self.assertEqual(joined.message, "a+b+c")

            echoed = list(
                client.Bidi([EchoRequest(message=m) for m in ("x", "y")])
            )
            self.assertEqual([r.message for r in echoed], ["x", "y"])

            with self.assertRaises(grpcdc.StatusError) as cm:
                client.Unary(EchoRequest(message="fail"))
            self.assertEqual(cm.exception.code, 3)

    def test_go_client_calls_python_server(self):
        with tempfile.TemporaryDirectory() as tmp:
            client_bin = os.path.join(tmp, "echo_client_stdio")
            build_go(self, client_bin, "./examples/echo_client_stdio")
            # Wire both directions with two pipes through this process.
            server = subprocess.Popen(
                [sys.executable, os.path.join(PY_DIR, "examples", "echo_server_stdio.py")],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
            )
            self.addCleanup(kill_and_wait, server)
            client = subprocess.Popen(
                [client_bin], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            self.addCleanup(kill_and_wait, client)
            import threading

            def pump(src, dst):
                try:
                    while True:
                        # os.read, not buffered .read(n): the latter
                        # would hold whole frames until 64 KiB fill.
                        chunk = os.read(src.fileno(), 65536)
                        if not chunk:
                            break
                        dst.write(chunk)
                        dst.flush()
                except (BrokenPipeError, ValueError, OSError):
                    pass
                try:
                    dst.close()
                except Exception:
                    pass

            t1 = threading.Thread(
                target=pump, args=(client.stdout, server.stdin), daemon=True
            )
            t2 = threading.Thread(
                target=pump, args=(server.stdout, client.stdin), daemon=True
            )
            t1.start()
            t2.start()
            try:
                client.wait(timeout=60)
            except subprocess.TimeoutExpired:
                self.fail("go client harness timed out")
            # stdout is owned by the pump thread; stderr is ours alone.
            text = client.stderr.read().decode()
            self.assertIn("unary=echo: hello", text)
            self.assertIn("server_stream=tick#0,tick#1,tick#2", text)
            self.assertIn("client_stream=a+b+c", text)
            self.assertIn("bidi=x,y", text)


if __name__ == "__main__":
    unittest.main()
