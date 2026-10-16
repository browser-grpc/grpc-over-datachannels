"""Dynamic (descriptor-driven) runtime: schemas consumed as data at
runtime, no generated stubs. Loopback plus the official grpc-java
oracle in both directions (oracle == runtime test bed).
"""

import os
import subprocess
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "examples"))

import grpcdc
from grpcdc import GenericMessage
from dynamic_echo import DynamicEchoService
from stdio import StdioTransport
from oracle_scenarios_generated import SCENARIOS
from test_oracle import free_port, java_classpath, unmsg


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
SERVICE = "echo.Echo"


def load_model(test):
    path = os.path.join(ROOT, "fixtures", "echo_descriptor_set.bin")
    if not os.path.exists(path):
        test.skipTest("descriptor fixture missing (make generate)")
    with open(path, "rb") as f:
        return grpcdc.parse_descriptor_set(f.read())


def request(model, message, count=0):
    return (
        GenericMessage(model.messages[".echo.EchoRequest"])
        .set(1, message)
        .set(2, count)
    )


def run_scenarios(test, client, model):
    for case in SCENARIOS:
        kind = case["kind"]
        messages = [unmsg(m) for m in case["messages"]]
        line = kind + " " + " ".join(case["messages"])
        if kind == "UNARY":
            try:
                resp = client.unary(SERVICE, "Unary", request(model, messages[0]))
            except grpcdc.StatusError as e:
                if case["expect_status"] is not None:
                    test.assertEqual(e.code, case["expect_status"], line)
                    continue
                raise
            test.assertEqual(resp.get_string(1), "echo: " + messages[0], line)
            test.assertEqual(resp.get_int(2), 0, line)
        elif kind == "SERVER_STREAM":
            responses = list(
                client.server_stream(
                    SERVICE, "ServerStream", request(model, messages[0], case["count"])
                )
            )
            test.assertEqual(len(responses), case["count"], line)
            for i, resp in enumerate(responses):
                test.assertEqual(resp.get_string(1), messages[0], line)
                test.assertEqual(resp.get_int(2), i, line)
        elif kind == "CLIENT_STREAM":
            resp = client.client_stream(
                SERVICE, "ClientStream", [request(model, m) for m in messages]
            )
            test.assertEqual(resp.get_string(1), "+".join(messages), line)
            test.assertEqual(resp.get_int(2), len(messages), line)
        elif kind == "BIDI":
            responses = list(
                client.bidi(SERVICE, "Bidi", [request(model, m) for m in messages])
            )
            test.assertEqual(len(responses), len(messages), line)
            for i, resp in enumerate(responses):
                test.assertEqual(resp.get_string(1), messages[i], line)
                test.assertEqual(resp.get_int(2), i, line)


class TestDynamicLoopback(unittest.TestCase):
    def setUp(self):
        self.model = load_model(self)
        a, b = grpcdc.memory_transport_pair()
        server = grpcdc.Server()
        grpcdc.register_dynamic_service(server, self.model, SERVICE, DynamicEchoService())
        server.serve_transport(b)
        self.client = grpcdc.DynamicClient(grpcdc.Channel(a), self.model)

    def test_all_shapes(self):
        run_scenarios(self, self.client, self.model)

    def test_generic_round_trip(self):
        req = request(self.model, "hi", 2)
        model_type = self.model.messages[".echo.EchoRequest"]
        from grpcdc.dynamic import encode_generic, decode_generic

        decoded = decode_generic(model_type, encode_generic(model_type, req, self.model), self.model)
        self.assertEqual(decoded.get_string(1), "hi")
        self.assertEqual(decoded.get_int(2), 2)

    def test_unknown_fields_retained(self):
        # Fields 99 (varint 42) and 100 (string "x") are not in the
        # schema: decode must retain them and encode must re-emit them.
        model_type = self.model.messages[".echo.EchoRequest"]
        from grpcdc.dynamic import encode_generic, decode_generic

        payload = (
            bytes.fromhex("0a0268691002")
            + bytes([0x98, 0x06, 0x2A])
            + bytes([0xA2, 0x06, 0x01])
            + b"x"
        )
        decoded = decode_generic(model_type, payload, self.model)
        self.assertEqual(len(decoded.unknown), 2)
        self.assertEqual(encode_generic(model_type, decoded, self.model), payload)


class TestDynamicOracle(unittest.TestCase):
    def setUp(self):
        self.model = load_model(self)

    def test_dynamic_client_calls_official_server(self):
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
        bridge = subprocess.Popen(
            ["node", os.path.join(ROOT, "oracle", "bridge.mjs"),
             "dc-to-http2", "--grpc", f"127.0.0.1:{port}"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        )
        self.addCleanup(kill_and_wait, bridge)
        transport = StdioTransport(bridge.stdin, bridge.stdout)
        client = grpcdc.DynamicClient(grpcdc.Channel(transport), self.model)
        run_scenarios(self, client, self.model)

    def test_official_client_calls_dynamic_server(self):
        cp = java_classpath(self)
        port = free_port()
        server_cmd = (
            f"{sys.executable} "
            + os.path.join(ROOT, "python", "examples", "dynamic_echo_server_stdio.py")
        )
        bridge = subprocess.Popen(
            ["node", os.path.join(ROOT, "oracle", "bridge.mjs"),
             "http2-to-dc", "--port", str(port), "--target-cmd", server_cmd],
            stderr=subprocess.PIPE,
        )
        self.addCleanup(kill_and_wait, bridge)
        line = bridge.stderr.readline()
        if b"listening" not in line:
            self.skipTest(f"bridge did not start: {line!r}")
        client = subprocess.run(
            ["java", "-cp", cp, "dc.oracle.OracleClient", str(port),
             os.path.join(ROOT, "fixtures", "oracle_scenarios.txt")],
            capture_output=True, text=True, timeout=120,
        )
        self.assertEqual(client.returncode, 0, client.stdout + client.stderr)
        self.assertIn("ORACLE CLIENT: ALL OK", client.stdout)


if __name__ == "__main__":
    unittest.main()
