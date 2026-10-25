"""Interop oracle: the generated Python client runs the
canonical grpc interop cases (grpc.testing.TestService,
vendored in oracle/interop) against the OFFICIAL
TestServiceServers — grpc-java and grpc-go — no bridge,
direct HTTP/2 (grpcdc.http2.Http2Transport). Case semantics
mirror grpc's AbstractInteropTest. Skips when an oracle is
not built (Dockerfile.ci builds both).

custom_metadata asserts the initial response metadata echo;
trailing metadata is not surfaced by the grpc-dc frame layer
(see oracle/interop/README.md).
"""

import os
import socket
import subprocess
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "examples"))

import grpcdc
import test_grpc_dc
from grpcdc.http2 import Http2Transport
from messages_pb import (
    EchoStatus,
    Payload,
    ResponseParameters,
    SimpleRequest,
    SimpleResponse,
    StreamingInputCallRequest,
    StreamingOutputCallRequest,
    StreamingOutputCallResponse,
)
from test_pb import Empty

ROOT = os.path.join(os.path.dirname(__file__), "..", "..")

INITIAL_METADATA_VALUE = "test_initial_metadata_value"


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


def zeros(n):
    return b"\x00" * n


def wait_for_port(port, proc, timeout=30.0):
    import time

    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            return False
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=1):
                return True
        except OSError:
            time.sleep(0.1)
    return False


class InteropOracleBase:
    SERVER_KIND = "java"

    @classmethod
    def setUpClass(cls):
        cls.port = free_port()
        if cls.SERVER_KIND == "java":
            target = os.path.join(ROOT, "oracle", "java", "target")
            cp_file = os.path.join(target, "cp.txt")
            if not os.path.exists(cp_file):
                raise unittest.SkipTest(
                    "java oracle not built (cd oracle/java && mvn package)"
                )
            with open(cp_file) as f:
                cp = os.path.join(target, "classes") + ":" + f.read().strip()
            cls.server = subprocess.Popen(
                [
                    "java", "-cp", cp,
                    "io.grpc.testing.integration.TestServiceServer",
                    f"--port={cls.port}", "--use_tls=false",
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
            )
            ready = False
            for line in cls.server.stdout:
                if "Server started" in line:
                    ready = True
                    break
            if not ready:
                raise unittest.SkipTest("TestServiceServer did not start")
        else:
            binary = os.path.join(ROOT, "oracle", "go-interop", "interop-server")
            if not os.path.exists(binary):
                raise unittest.SkipTest(
                    "go interop server not built (cd oracle/go-interop && "
                    "go build -o interop-server google.golang.org/grpc/interop/server)"
                )
            cls.server = subprocess.Popen(
                [binary, "-port", str(cls.port)],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
            )
            # The Go server prints no readiness line; poll the port.
            if not wait_for_port(cls.port, cls.server):
                raise unittest.SkipTest("go TestServiceServer did not start")
        cls.transport = Http2Transport(f"127.0.0.1:{cls.port}")
        cls.channel = grpcdc.Channel(cls.transport)
        cls.client = test_grpc_dc.TestServiceClient(cls.channel)

    @classmethod
    def tearDownClass(cls):
        cls.transport.close()
        kill_and_wait(cls.server)

    def test_empty_unary(self):
        resp = self.client.EmptyCall(Empty())
        self.assertIsInstance(resp, Empty)

    def test_large_unary(self):
        resp = self.client.UnaryCall(SimpleRequest(
            response_size=314159,
            payload=Payload(body=zeros(271828)),
        ))
        self.assertEqual(len(resp.payload.body), 314159)
        self.assertEqual(resp.payload.body, zeros(314159))

    def test_client_streaming(self):
        sizes = [27182, 8, 1828, 45904]
        resp = self.client.StreamingInputCall(
            [StreamingInputCallRequest(payload=Payload(body=zeros(s))) for s in sizes]
        )
        self.assertEqual(resp.aggregated_payload_size, sum(sizes))

    def test_server_streaming(self):
        sizes = [31415, 9, 2653, 58979]
        req = StreamingOutputCallRequest(
            response_parameters=[ResponseParameters(size=s) for s in sizes]
        )
        responses = list(self.client.StreamingOutputCall(req))
        self.assertEqual([len(r.payload.body) for r in responses], sizes)

    def test_ping_pong(self):
        resp_sizes = [31415, 9, 2653, 58979]
        req_sizes = [27182, 8, 1828, 45904]
        reqs = [
            StreamingOutputCallRequest(
                response_parameters=[ResponseParameters(size=resp_sizes[i])],
                payload=Payload(body=zeros(req_sizes[i])),
            )
            for i in range(len(resp_sizes))
        ]
        responses = list(self.client.FullDuplexCall(reqs))
        self.assertEqual([len(r.payload.body) for r in responses], resp_sizes)

    def test_empty_stream(self):
        responses = list(self.client.FullDuplexCall([]))
        self.assertEqual(responses, [])

    def test_custom_metadata(self):
        # Upstream custom_metadata: echo-initial returns as
        # response initial metadata, echo-trailing-bin (binary
        # 0x0a 0x0b ...; base64 on our wire) as trailers.
        # Asserted on UnaryCall and FullDuplexCall, mirroring
        # AbstractInteropTest (both reference servers echo on
        # FullDuplexCall; grpc-go does not echo on
        # StreamingOutputCall).
        import base64

        trailing_bin = base64.b64encode(b"\x0a\x0b\x0a\x0b\x0a\x0b").decode()
        md = {
            "x-grpc-test-echo-initial": INITIAL_METADATA_VALUE,
            "x-grpc-test-echo-trailing-bin": trailing_bin,
        }

        stream = self.channel.unary_stream(
            "/grpc.testing.TestService/UnaryCall",
            SimpleRequest(
                response_size=1, payload=Payload(body=zeros(1))
            ),
            md,
        )
        resp = stream.recv(SimpleResponse())
        self.assertEqual(len(resp.payload.body), 1)
        with self.assertRaises(EOFError):
            stream.recv(SimpleResponse())
        self.assertEqual(
            stream.headers.metadata.get("x-grpc-test-echo-initial"),
            INITIAL_METADATA_VALUE,
        )
        self.assertEqual(
            stream.trailers.get("x-grpc-test-echo-trailing-bin"),
            trailing_bin,
        )

        req = StreamingOutputCallRequest(
            response_parameters=[ResponseParameters(size=1)],
            payload=Payload(body=zeros(1)),
        )
        stream = self.client.FullDuplexCall([req], md)
        responses = list(stream)
        self.assertEqual(len(responses), 1)
        headers = stream._stream.headers
        self.assertIsNotNone(headers)
        self.assertEqual(
            headers.metadata.get("x-grpc-test-echo-initial"),
            INITIAL_METADATA_VALUE,
        )
        self.assertEqual(
            stream._stream.trailers.get("x-grpc-test-echo-trailing-bin"),
            trailing_bin,
        )

    def test_status_code_and_message(self):
        req = SimpleRequest(
            response_status=EchoStatus(code=2, message="test status message")
        )
        with self.assertRaises(grpcdc.StatusError) as ctx:
            self.client.UnaryCall(req)
        self.assertEqual(ctx.exception.code, 2)
        self.assertEqual(ctx.exception.message, "test status message")

    def test_special_status_message(self):
        msg = "\t\ntest with whitespace\r\nand Unicode BMP ☺ and non-BMP 😈\t\n"
        req = SimpleRequest(response_status=EchoStatus(code=2, message=msg))
        with self.assertRaises(grpcdc.StatusError) as ctx:
            self.client.UnaryCall(req)
        self.assertEqual(ctx.exception.code, 2)
        self.assertEqual(ctx.exception.message, msg)

    def test_unimplemented_method(self):
        unimpl = test_grpc_dc.UnimplementedServiceClient(self.channel)
        with self.assertRaises(grpcdc.StatusError) as ctx:
            unimpl.UnimplementedCall(Empty())
        self.assertEqual(ctx.exception.code, 12)

    def test_unimplemented_service(self):
        with self.assertRaises(grpcdc.StatusError) as ctx:
            self.channel.unary(
                "/grpc.testing.UnimplementedService2/UnimplementedCall",
                Empty(), Empty(), None,
            )
        self.assertEqual(ctx.exception.code, 12)

    def test_cancel_after_begin(self):
        stream = self.channel._open(
            "/grpc.testing.TestService/StreamingOutputCall", None
        )
        self.channel.cancel(stream)
        with self.assertRaises(grpcdc.StatusError) as ctx:
            while True:
                stream.recv(StreamingOutputCallResponse())
        self.assertEqual(ctx.exception.code, 1)

    def test_cancel_after_first_response(self):
        stream = self.channel._open(
            "/grpc.testing.TestService/FullDuplexCall", None
        )
        req = StreamingOutputCallRequest(
            response_parameters=[ResponseParameters(size=31415)],
            payload=Payload(body=zeros(27182)),
        )
        self.channel._send_message(stream, req)
        resp = StreamingOutputCallResponse()
        stream.recv(resp)
        self.assertEqual(len(resp.payload.body), 31415)
        self.channel.cancel(stream)
        with self.assertRaises(grpcdc.StatusError) as ctx:
            while True:
                stream.recv(StreamingOutputCallResponse())
        self.assertEqual(ctx.exception.code, 1)

    def test_timeout_on_sleeping_server(self):
        stream = self.channel._open(
            "/grpc.testing.TestService/FullDuplexCall", None, timeout=1.0
        )
        req = StreamingOutputCallRequest(
            response_parameters=[ResponseParameters(size=31415)],
            payload=Payload(body=zeros(27182)),
        )
        self.channel._send_message(stream, req)
        resp = StreamingOutputCallResponse()
        stream.recv(resp)
        self.assertEqual(len(resp.payload.body), 31415)
        with self.assertRaises(grpcdc.StatusError) as ctx:
            stream.recv(StreamingOutputCallResponse())
        self.assertEqual(ctx.exception.code, 4)


class TestInteropOracleJava(InteropOracleBase, unittest.TestCase):
    SERVER_KIND = "java"


class TestInteropOracleGo(InteropOracleBase, unittest.TestCase):
    SERVER_KIND = "go"


if __name__ == "__main__":
    unittest.main()
