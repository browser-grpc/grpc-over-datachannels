# Interop harness: the dynamic (descriptor-driven) Python echo
# server over stdio. Loads fixtures/echo_descriptor_set.bin at
# runtime — no generated stubs involved. Used by the oracle tests.
import os
import sys
import threading

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.dirname(__file__))

import grpcdc
from dynamic_echo import DynamicEchoService
from stdio import StdioTransport

ROOT = os.path.join(os.path.dirname(__file__), "..", "..")


def main():
    with open(os.path.join(ROOT, "fixtures", "echo_descriptor_set.bin"), "rb") as f:
        model = grpcdc.parse_descriptor_set(f.read())
    transport = StdioTransport(sys.stdout.buffer, sys.stdin.buffer)
    transport.on_eof = lambda: os._exit(0)
    server = grpcdc.Server()
    grpcdc.register_dynamic_service(server, model, "echo.Echo", DynamicEchoService())
    server.serve_transport(transport)
    threading.Event().wait()


if __name__ == "__main__":
    main()
