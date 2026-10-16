"""Oracle tests: the official grpc-java implementation, bridged over
TCP<->DataChannel by ../../oracle/bridge.mjs, must agree with the
Python runtime on every case of the generated scenario table
(oracle_scenarios_generated.py, stamped from racket/oracle-spec.rkt).
Skips when the Java oracle or Node bridge are unavailable
(Dockerfile.ci provides both). Mirrors go/oracle_test.go.
"""

import os
import socket
import subprocess
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "examples"))

import grpcdc
import echo_grpc_dc
from echo_pb import EchoRequest
from stdio import StdioTransport
from oracle_scenarios_generated import SCENARIOS


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


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def java_classpath(test):
    target = os.path.join(ROOT, "oracle", "java", "target")
    cp_file = os.path.join(target, "cp.txt")
    if not os.path.exists(cp_file) or not os.path.isdir(
        os.path.join(target, "classes")
    ):
        test.skipTest("java oracle not built (cd oracle/java && mvn package)")
    with open(cp_file) as f:
        return os.path.join(target, "classes") + ":" + f.read().strip()


def unmsg(token):
    return "" if token == "-" else token


def run_scenarios(test, client):
    for case in SCENARIOS:
        kind = case["kind"]
        messages = [unmsg(m) for m in case["messages"]]
        line = kind + " " + " ".join(case["messages"])
        if kind == "UNARY":
            message = messages[0]
            try:
                resp = client.Unary(EchoRequest(message=message))
            except grpcdc.StatusError as e:
                if case["expect_status"] is not None:
                    test.assertEqual(
                        e.code, case["expect_status"], f"{line}: {e}"
                    )
                    continue
                raise
            test.assertEqual(resp.message, "echo: " + message, line)
            test.assertEqual(resp.index, 0, line)
        elif kind == "SERVER_STREAM":
            message = messages[0]
            responses = list(
                client.ServerStream(
                    EchoRequest(message=message, count=case["count"])
                )
            )
            test.assertEqual(len(responses), case["count"], line)
            for i, resp in enumerate(responses):
                test.assertEqual(resp.message, message, line)
                test.assertEqual(resp.index, i, line)
        elif kind == "CLIENT_STREAM":
            resp = client.ClientStream(
                [EchoRequest(message=m) for m in messages]
            )
            test.assertEqual(resp.message, "+".join(messages), line)
            test.assertEqual(resp.index, len(messages), line)
        elif kind == "BIDI":
            responses = list(
                client.Bidi([EchoRequest(message=m) for m in messages])
            )
            test.assertEqual(len(responses), len(messages), line)
            for i, resp in enumerate(responses):
                test.assertEqual(resp.message, messages[i], line)
                test.assertEqual(resp.index, i, line)
        else:
            test.fail(f"unknown scenario kind: {kind}")


class TestOracle(unittest.TestCase):
    def test_python_client_calls_official_server(self):
        cp = java_classpath(self)
        port = free_port()
        server = subprocess.Popen(
            ["java", "-cp", cp, "dc.oracle.OracleServer", str(port)],
            stderr=subprocess.PIPE,
        )
        self.addCleanup(kill_and_wait, server)
        # Wait for READY on stderr.
        ready = False
        while True:
            line = server.stderr.readline()
            if not line:
                break
            if b"READY" in line:
                ready = True
                break
        if not ready:
            self.skipTest("java oracle server did not start")

        bridge = subprocess.Popen(
            [
                "node",
                os.path.join(ROOT, "oracle", "bridge.mjs"),
                "dc-to-http2",
                "--grpc",
                f"127.0.0.1:{port}",
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
        )
        self.addCleanup(kill_and_wait, bridge)
        transport = StdioTransport(bridge.stdin, bridge.stdout)
        client = echo_grpc_dc.EchoClient(grpcdc.Channel(transport))
        run_scenarios(self, client)

    def test_official_client_calls_python_server(self):
        cp = java_classpath(self)
        port = free_port()
        server_cmd = (
            f"{sys.executable} "
            + os.path.join(ROOT, "python", "examples", "echo_server_stdio.py")
        )
        bridge = subprocess.Popen(
            [
                "node",
                os.path.join(ROOT, "oracle", "bridge.mjs"),
                "http2-to-dc",
                "--port",
                str(port),
                "--target-cmd",
                server_cmd,
            ],
            stderr=subprocess.PIPE,
        )
        self.addCleanup(kill_and_wait, bridge)
        # The bridge prints its listening line to stderr.
        line = bridge.stderr.readline()
        if b"listening" not in line:
            self.skipTest(f"bridge did not start: {line!r}")

        client = subprocess.run(
            [
                "java",
                "-cp",
                cp,
                "dc.oracle.OracleClient",
                str(port),
                os.path.join(ROOT, "fixtures", "oracle_scenarios.txt"),
            ],
            capture_output=True,
            text=True,
            timeout=120,
        )
        self.assertEqual(client.returncode, 0, client.stdout + client.stderr)
        self.assertIn("ORACLE CLIENT: ALL OK", client.stdout)


if __name__ == "__main__":
    unittest.main()
