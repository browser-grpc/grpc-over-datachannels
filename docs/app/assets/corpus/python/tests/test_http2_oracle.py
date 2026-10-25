"""HTTP/2 oracle tests: the generated Python client calls the
official grpc-java server DIRECTLY over HTTP/2 (no bridge).
grpcdc/http2.py is generated code (manual
HPACK + HTTP/2 session from RFC tables). The TLS case dials a
Node TLS HTTP/2 front-end fixture (stdlib TLS + ALPN h2 both
sides) backed by a JS Echo server. Skips when the Java oracle
or Node are unavailable (Dockerfile.ci provides both).
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
from grpcdc.http2 import Http2Transport
from oracle_scenarios_generated import SCENARIOS

ROOT = os.path.join(os.path.dirname(__file__), "..", "..")


def kill_and_wait(proc):
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


def java_classpath(test):
    target = os.path.join(ROOT, "oracle", "java", "target")
    cp_file = os.path.join(target, "cp.txt")
    if not os.path.exists(cp_file) or not os.path.isdir(
        os.path.join(target, "classes")
    ):
        test.skipTest("java oracle not built (cd oracle/java && mvn package)")
    with open(cp_file) as f:
        return os.path.join(target, "classes") + ":" + f.read().strip()


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def unmsg(token):
    return "" if token == "-" else token


class TestHttp2Oracle(unittest.TestCase):
    def start_java_server(self):
        cp = java_classpath(self)
        port = free_port()
        server = subprocess.Popen(
            ["java", "-cp", cp, "dc.oracle.OracleServer", str(port)],
            stderr=subprocess.PIPE,
        )
        self.addCleanup(kill_and_wait, server)
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
        return port

    def test_python_http2_client_calls_official_server(self):
        port = self.start_java_server()
        transport = Http2Transport(f"127.0.0.1:{port}")
        self.addCleanup(transport.close)
        client = echo_grpc_dc.EchoClient(grpcdc.Channel(transport))

        for case in SCENARIOS:
            kind = case["kind"]
            messages = [unmsg(m) for m in case["messages"]]
            line = kind + " " + " ".join(case["messages"])
            if kind == "UNARY":
                try:
                    resp = client.Unary(EchoRequest(message=messages[0]))
                except grpcdc.StatusError as e:
                    if case["expect_status"] is not None:
                        self.assertEqual(e.code, case["expect_status"], line)
                        continue
                    raise
                self.assertEqual(resp.message, "echo: " + messages[0], line)
                self.assertEqual(resp.index, 0, line)
            elif kind == "SERVER_STREAM":
                responses = list(
                    client.ServerStream(
                        EchoRequest(message=messages[0], count=case["count"])
                    )
                )
                self.assertEqual(len(responses), case["count"], line)
                for i, resp in enumerate(responses):
                    self.assertEqual(resp.message, messages[0], line)
                    self.assertEqual(resp.index, i, line)
            elif kind == "CLIENT_STREAM":
                resp = client.ClientStream(
                    [EchoRequest(message=m) for m in messages]
                )
                self.assertEqual(resp.message, "+".join(messages), line)
                self.assertEqual(resp.index, len(messages), line)
            elif kind == "BIDI":
                responses = list(
                    client.Bidi([EchoRequest(message=m) for m in messages])
                )
                self.assertEqual(len(responses), len(messages), line)
                for i, resp in enumerate(responses):
                    self.assertEqual(resp.message, messages[i], line)
                    self.assertEqual(resp.index, i, line)
            else:
                self.fail(f"unknown scenario kind: {kind}")

        # Metadata reflected by the oracle (x-echo suffix).
        resp = client.Unary(EchoRequest(message="meta"), {"x-echo": "py-http2"})
        self.assertEqual(resp.message, "echo: meta [py-http2]")

        # Flow control: 200-message stream and a 300 KiB message.
        responses = list(
            client.ServerStream(EchoRequest(message="big", count=200))
        )
        self.assertEqual(len(responses), 200)
        resp = client.Unary(EchoRequest(message="x" * 300000))
        self.assertEqual(resp.message, "echo: " + "x" * 300000)

    def test_python_http2_tls_client(self):
        fixture = os.path.join(ROOT, "js", "test", "http2_tls_fixture.mjs")
        proc = subprocess.Popen(
            ["node", fixture],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.addCleanup(kill_and_wait, proc)
        line = proc.stdout.readline()
        if "READY" not in line:
            self.skipTest("TLS fixture did not start")
        port = int(line.split()[1])
        cafile = line.split()[2]
        transport = Http2Transport(
            f"localhost:{port}", use_tls=True, cafile=cafile
        )
        self.addCleanup(transport.close)
        client = echo_grpc_dc.EchoClient(grpcdc.Channel(transport))
        resp = client.Unary(EchoRequest(message="hello"))
        self.assertEqual(resp.message, "echo: hello")


if __name__ == "__main__":
    unittest.main()
